//===----------------------------------------------------------------------===//
//
// This source file is part of MpVFX.
//
// Copyright (c) 2026 Arshiya Rahgozar.
//
// Licensed under either of the Apache License, Version 2.0 (LICENSE-APACHE or
// http://www.apache.org/licenses/LICENSE-2.0) or the MIT license (LICENSE-MIT
// or http://opensource.org/licenses/MIT), at your option.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
//
//===----------------------------------------------------------------------===//
// Cut transitions on the timeline editor: each transition edit is one undo step, refused on a locked track, and a
// clip edit that removes or shortens a transition says so through `onNotice`.
import Foundation
import MpvfxShared

public extension TimelineEditor {
    /// Applies a transition edit as one undo step ("Add transition", "Remove transition", …). A refusal (locked
    /// track, too little media for a dissolve, a value the document rejects) sets `lastFailure` and changes nothing.
    @discardableResult
    func applyTransition(_ command: NativeCutTransitionCommand) -> Bool {
        if let trackId = transitionTrackId(command), isTrackLocked(trackId) {
            lastFailure = NativeProjectClipFailure(code: .documentMismatch, message: "Track is locked"); return false
        }
        do {
            let r = try applyNativeCutTransitionCommand(document, command, engine: engine)
            guard case .success(let doc, let inverse) = r else { lastFailure = r.failure; return false }
            lastFailure = nil
            withHistory(Self.transitionLabel(command)) { replaceDocument(doc, inverse: inverse) }
            return true
        } catch {
            // Only a non-validation engine error reaches here (refusals return .failure above).
            lastFailure = NativeProjectClipFailure(code: .documentMismatch, message: "The transition could not be applied"); return false
        }
    }

    /// The track a transition command edits (nil when the transition does not exist).
    internal func transitionTrackId(_ command: NativeCutTransitionCommand) -> String? {
        let id: String
        switch command {
        case .add(let trackId, _), .replace(let trackId, _): return trackId
        case .setLength(let i, _), .setKind(let i, _), .setAlignment(let i, _), .setColor(let i, _), .setDirection(let i, _), .setSoftness(let i, _), .remove(let i): id = i
        case .setAngle(let i, _), .setIris(let i, _, _, _), .setStrength(let i, _), .setEase(let i, _): id = i
        }
        return document.sequence.tracks.first { $0.cutTransitions.contains { $0.id == id } }?.id
    }

    internal static func transitionLabel(_ command: NativeCutTransitionCommand) -> String {
        switch command {
        case .add, .replace: "Add transition"
        case .remove: "Remove transition"
        case .setLength: "Change transition length"
        case .setKind: "Change transition kind"
        case .setAlignment: "Change transition alignment"
        case .setDirection: "Change transition direction"
        case .setSoftness: "Change transition softness"
        case .setColor: "Change transition colour"
        case .setAngle, .setIris, .setStrength: "Change transition options"
        case .setEase: "Change transition ease"
        }
    }

    /// Records (and hands to `onNotice`) what the edit that turned `before` into the current document did to
    /// transitions.
    internal func reportTransitionChanges(from before: NativeProjectDocument) {
        lastNotice = nativeCutTransitionChangeNotice(before: before, after: document)
        if let lastNotice { onNotice?(lastNotice) }
    }
}

/// A cut: two clips of one track where the second starts as the first ends. Cuts are not stored; a transition
/// belongs to the cut it names.
public struct TimelineCut: Equatable, Hashable, Sendable {
    public var trackId: String
    public var fromClipId: String
    public var toClipId: String
    /// The timeline frame where the second clip starts.
    public var frame: Double
    public init(trackId: String, fromClipId: String, toClipId: String, frame: Double) {
        self.trackId = trackId; self.fromClipId = fromClipId; self.toClipId = toClipId; self.frame = frame
    }
}

/// What applying a transition to a cut did.
public enum TransitionApplyOutcome: Equatable, Sendable {
    /// Applied at `lengthFrames`; `shortenedFrom` is the length that was wanted when the media allowed less.
    case applied(lengthFrames: Double, shortenedFrom: Double?)
    /// Nothing changed; the message says why.
    case refused(String)

    public var applied: Bool { if case .applied = self { true } else { false } }
    /// The length it was shortened to, when the media allowed less than was wanted.
    public var shortenedLength: Double? { if case .applied(let length, .some) = self { length } else { nil } }
}

public extension TimelineEditor {
    /// The length a new transition gets when Settings has not set one (frames).
    static var standardTransitionFrames: Double { 15 }

    /// Every cut of the document in track and time order: each pair of clips on one track that touch.
    var allCuts: [TimelineCut] {
        document.sequence.tracks.flatMap { track -> [TimelineCut] in
            let clips = track.clips.sorted { $0.startFrame < $1.startFrame }
            return zip(clips, clips.dropFirst()).compactMap { a, b in
                a.startFrame + a.durationFrames == b.startFrame
                    ? TimelineCut(trackId: track.id, fromClipId: a.id, toClipId: b.id, frame: b.startFrame) : nil
            }
        }
    }

    /// The cuts "the selected cut" means: every cut between two selected clips; with none, the cut after the first
    /// selected clip, else the cut before it (the same pair the inspector's Transition group shows).
    func cuts(forSelection selection: Set<String>) -> [TimelineCut] {
        guard !selection.isEmpty else { return [] }
        let all = allCuts
        let between = all.filter { selection.contains($0.fromClipId) && selection.contains($0.toClipId) }
        if !between.isEmpty { return between }
        for track in document.sequence.tracks {
            for clip in track.clips.sorted(by: { $0.startFrame < $1.startFrame }) where selection.contains(clip.id) {
                if let cut = all.first(where: { $0.fromClipId == clip.id }) ?? all.first(where: { $0.toClipId == clip.id }) { return [cut] }
            }
        }
        return []
    }

    /// The cut of `trackId` (any track when nil) within `toleranceFrames` of `frame`, the nearest one.
    func cut(nearFrame frame: Double, toleranceFrames: Double, trackId: String? = nil) -> TimelineCut? {
        allCuts.filter { (trackId == nil || $0.trackId == trackId) && abs($0.frame - frame) <= toleranceFrames }
            .min { abs($0.frame - frame) < abs($1.frame - frame) }
    }

    /// The transition on `cut`, if it has one.
    func transition(on cut: TimelineCut) -> NativeCutTransition? {
        document.sequence.tracks.first { $0.id == cut.trackId }?.cutTransitions
            .first { $0.fromClipId == cut.fromClipId && $0.toClipId == cut.toClipId }
    }

    /// Puts a transition of `kind` on `cut`, replacing the one there, as one undo step; see `applyTransition(_:to:)`.
    @discardableResult
    func applyTransition(_ kind: NativeCutTransitionKind, direction: NativeTransitionDirection? = nil, color: String? = nil,
                         irisShape: NativeIrisShape? = nil, to cut: TimelineCut, lengthFrames: Double? = nil) -> TransitionApplyOutcome {
        applyTransition(kind, direction: direction, color: color, irisShape: irisShape, to: [cut], lengthFrames: lengthFrames)[0]
    }

    /// Puts a transition of `kind` on each of `cuts`, replacing the ones there, all in one undo step. The length is
    /// `lengthFrames`, else the cut's current transition's, else the default; it is shortened to what the clips and
    /// their handles allow, never below 2 frames (then that cut is refused with the reason). A refused cut changes
    /// nothing; the others still get theirs. One outcome per cut, in order.
    @discardableResult
    func applyTransition(_ kind: NativeCutTransitionKind, direction: NativeTransitionDirection? = nil, color: String? = nil,
                         irisShape: NativeIrisShape? = nil, to cuts: [TimelineCut], lengthFrames: Double? = nil) -> [TransitionApplyOutcome] {
        var doc = document
        var undoToOriginal: NativeProjectClipCommand?
        var outcomes: [TransitionApplyOutcome] = []
        for cut in cuts {
            if isTrackLocked(cut.trackId) { outcomes.append(.refused("Track is locked")); continue }
            switch plannedTransition(kind, direction: direction, color: color, irisShape: irisShape, cut: cut, lengthFrames: lengthFrames) {
            case .failure(let failure): outcomes.append(.refused(failure.message))
            case .success(let plan):
                do {
                    let r = try applyNativeCutTransitionCommand(doc, .replace(trackId: cut.trackId, transition: plan.transition), engine: engine)
                    guard case .success(let next, let inverse) = r else { outcomes.append(.refused(r.failure?.message ?? "The transition could not be applied.")); continue }
                    // The first edit's inverse restores the document as it was before any of them.
                    if undoToOriginal == nil { undoToOriginal = inverse }
                    doc = next
                    outcomes.append(.applied(lengthFrames: plan.length, shortenedFrom: plan.length < plan.wanted ? plan.wanted : nil))
                } catch { outcomes.append(.refused("The transition could not be applied.")) }
            }
        }
        guard let inverse = undoToOriginal else {
            if case .refused(let message)? = outcomes.first { lastFailure = NativeProjectClipFailure(code: .insufficientHandles, message: message) }
            return outcomes
        }
        lastFailure = nil
        withHistory("Add transition") { replaceDocument(doc, inverse: inverse) }
        return outcomes
    }

    /// The length `applyTransition` would give `kind` on `cut` and the length it wanted; nil when the cut cannot take
    /// one. A shorter length than wanted is the "shortened to N frames" note of the browser.
    func transitionFit(_ kind: NativeCutTransitionKind, on cut: TimelineCut, lengthFrames: Double? = nil) -> (length: Double, wanted: Double)? {
        guard case .success(let plan) = plannedTransition(kind, direction: nil, color: nil, cut: cut, lengthFrames: lengthFrames) else { return nil }
        return (plan.length, plan.wanted)
    }

    private func plannedTransition(_ kind: NativeCutTransitionKind, direction: NativeTransitionDirection?, color: String?, irisShape: NativeIrisShape? = nil, cut: TimelineCut,
                                   lengthFrames: Double?) -> Result<(transition: NativeCutTransition, length: Double, wanted: Double), TransitionPlanFailure> {
        guard let track = document.sequence.tracks.first(where: { $0.id == cut.trackId }),
              let from = track.clips.first(where: { $0.id == cut.fromClipId }),
              let to = track.clips.first(where: { $0.id == cut.toClipId }),
              from.startFrame + from.durationFrames == to.startFrame else {
            return .failure(TransitionPlanFailure("The two clips no longer meet at a cut."))
        }
        let existing = transition(on: cut)
        let alignment = existing?.alignment ?? .centre
        let wanted = lengthFrames ?? existing?.durationFrames ?? defaultTransitionFrames
        let assets = { (c: NativeProjectClip) in self.document.assets.first { $0.id == c.assetId } }
        let limit = nativeMaxTransitionLength(kind: kind, alignment: alignment, from: NativeTransitionSide(from, asset: assets(from)),
                                              to: NativeTransitionSide(to, asset: assets(to)))
        let length = min(wanted, limit.rounded(.down))
        guard length >= 2 else {
            let why = kind.overlaps ? "needs at least 2 frames of spare media beyond both clips" : "needs both clips to be at least 2 frames long"
            return .failure(TransitionPlanFailure("A \(kind.rawValue) \(why)."))
        }
        var transition = NativeCutTransition(id: UUID().uuidString.lowercased(), cut: (cut.fromClipId, cut.toClipId), kind: kind, durationFrames: length)
        if alignment != .centre { transition.alignment = alignment }
        if kind.usesDirection, let direction, direction != .left { transition.direction = direction }
        if kind == .iris, let irisShape { transition.irisShape = irisShape }
        if kind == .dip, let color, color.lowercased() != NativeCutTransition.defaultDipColor { transition.color = color }
        return .success((transition, length, wanted))
    }
}

/// Why a transition cannot go on a cut.
struct TransitionPlanFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: Adding, resizing and walking cuts from the keyboard

public extension TimelineEditor {
    /// The transitions of `track` the timeline draws: known entries on clips that still touch.
    internal static func transitionModels(_ track: NativeProjectTrack, fps: Double) -> [TimelineTransitionModel] {
        track.cutTransitions.compactMap { t in
            guard t.isKnown, let id = t.id, let kind = t.kind, let alignment = t.alignment, let length = t.durationFrames,
                  let to = track.clips.first(where: { $0.id == t.toClipId }), let from = track.clips.first(where: { $0.id == t.fromClipId }),
                  from.startFrame + from.durationFrames == to.startFrame else { return nil }
            let range = nativeCutTransitionRange(cut: to.startFrame, length: length, alignment: alignment)
            return TimelineTransitionModel(id: id, fromClipId: from.id, toClipId: to.id, start: range.start / fps, end: range.end / fps,
                                           cut: to.startFrame / fps, kind: kind.rawValue, durationFrames: length, alignment: alignment.rawValue)
        }
    }

    /// The cut a transition belongs to.
    func cut(ofTransition id: String) -> TimelineCut? {
        for track in document.sequence.tracks {
            guard let t = track.cutTransitions.first(where: { $0.id == id }), let from = t.fromClipId, let to = t.toClipId,
                  let toClip = track.clips.first(where: { $0.id == to }) else { continue }
            return TimelineCut(trackId: track.id, fromClipId: from, toClipId: to, frame: toClip.startFrame)
        }
        return nil
    }

    /// The track ⌘T acts on: the first selected clip's, else the topmost unlocked video track.
    func transitionTrackId(selection: Set<String>) -> String? {
        for track in document.sequence.tracks where track.clips.contains(where: { selection.contains($0.id) }) { return track.id }
        return tracks.first { $0.kind == "video" && !$0.locked }?.id
    }

    /// The cut nearest `frame` on the track ⌘T acts on (`transitionTrackId`).
    func nearestCut(toFrame frame: Double, selection: Set<String>) -> TimelineCut? {
        guard let trackId = transitionTrackId(selection: selection) else { return nil }
        return allCuts.filter { $0.trackId == trackId }.min { abs($0.frame - frame) < abs($1.frame - frame) }
    }

    /// ⌘T: the default transition (a dissolve, `defaultTransitionFrames`, centred) on the cut nearest `frame`, one undo
    /// step. A cut that already has a transition keeps its kind and length (nothing changes).
    @discardableResult
    func addDefaultTransition(nearFrame frame: Double, selection: Set<String>) -> TransitionApplyOutcome {
        guard let cut = nearestCut(toFrame: frame, selection: selection) else {
            return .refused("There is no cut on this track: clips must touch to take a transition.")
        }
        if let existing = transition(on: cut), existing.isKnown { return .refused("This cut already has a transition.") }
        return applyTransition(.dissolve, to: cut)
    }

    /// ⇧⌘T: the default transition on every cut between two selected clips, one undo step; cuts that already have
    /// one are left as they are.
    @discardableResult
    func addDefaultTransitions(forSelection selection: Set<String>) -> [TransitionApplyOutcome] {
        let cuts = allCuts.filter { selection.contains($0.fromClipId) && selection.contains($0.toClipId) && transition(on: $0) == nil }
        guard !cuts.isEmpty else { return [] }
        return applyTransition(.dissolve, to: cuts)
    }

    /// The longest `id` can be: the clips and, for a dissolve, their media beyond the in and out points allow.
    func maxTransitionLength(id: String) -> Double? {
        guard let cut = cut(ofTransition: id), let kind = document.sequence.tracks.lazy.flatMap(\.cutTransitions).first(where: { $0.id == id })?.kind,
              let fit = transitionFit(kind, on: cut, lengthFrames: 1_000_000) else { return nil }
        return fit.length
    }

    /// Sets the length of transition `id` to `frames`, shortened to `maxTransitionLength`, one undo step; the outcome
    /// says what it ended up as.
    @discardableResult
    func setTransitionLength(id: String, frames: Double) -> TransitionApplyOutcome {
        guard let limit = maxTransitionLength(id: id) else { return .refused("The transition no longer exists.") }
        let length = min(max(2, frames.rounded()), limit)
        guard length >= 2 else { return .refused("Not enough media to make this transition longer.") }
        let current = document.sequence.tracks.lazy.flatMap(\.cutTransitions).first { $0.id == id }?.durationFrames
        if current == length { return .applied(lengthFrames: length, shortenedFrom: length < frames ? frames : nil) }
        guard applyTransition(.setLength(id: id, durationFrames: length)) else {
            return .refused(lastFailure?.message ?? "The transition could not be changed.")
        }
        return .applied(lengthFrames: length, shortenedFrom: length < frames ? frames : nil)
    }

    /// The cut after (`forward`) or before the one at `frame` on `trackId` (the first or last when none is current),
    /// for walking cut to cut with ⌥← / ⌥→.
    func adjacentCut(from current: TimelineCut?, atFrame frame: Double, forward: Bool, trackId: String?) -> TimelineCut? {
        let id = current?.trackId ?? trackId ?? transitionTrackId(selection: [])
        let cuts = allCuts.filter { $0.trackId == id }.sorted { $0.frame < $1.frame }
        let at = current?.frame ?? frame
        return forward ? cuts.first { $0.frame > at + 0.5 } : cuts.last { $0.frame < at - 0.5 }
    }
}
