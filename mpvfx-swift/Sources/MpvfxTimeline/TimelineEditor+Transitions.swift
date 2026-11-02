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
public struct TimelineCut: Equatable, Sendable {
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
    /// The length a new transition gets (frames), until the Settings default of the timeline slice replaces it.
    static var defaultTransitionFrames: Double { 15 }

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
                         to cut: TimelineCut, lengthFrames: Double? = nil) -> TransitionApplyOutcome {
        applyTransition(kind, direction: direction, color: color, to: [cut], lengthFrames: lengthFrames)[0]
    }

    /// Puts a transition of `kind` on each of `cuts`, replacing the ones there, all in one undo step. The length is
    /// `lengthFrames`, else the cut's current transition's, else the default; it is shortened to what the clips and
    /// their handles allow, never below 2 frames (then that cut is refused with the reason). A refused cut changes
    /// nothing; the others still get theirs. One outcome per cut, in order.
    @discardableResult
    func applyTransition(_ kind: NativeCutTransitionKind, direction: NativeTransitionDirection? = nil, color: String? = nil,
                         to cuts: [TimelineCut], lengthFrames: Double? = nil) -> [TransitionApplyOutcome] {
        var doc = document
        var undoToOriginal: NativeProjectClipCommand?
        var outcomes: [TransitionApplyOutcome] = []
        for cut in cuts {
            if isTrackLocked(cut.trackId) { outcomes.append(.refused("Track is locked")); continue }
            switch plannedTransition(kind, direction: direction, color: color, cut: cut, lengthFrames: lengthFrames) {
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

    private func plannedTransition(_ kind: NativeCutTransitionKind, direction: NativeTransitionDirection?, color: String?, cut: TimelineCut,
                                   lengthFrames: Double?) -> Result<(transition: NativeCutTransition, length: Double, wanted: Double), TransitionPlanFailure> {
        guard let track = document.sequence.tracks.first(where: { $0.id == cut.trackId }),
              let from = track.clips.first(where: { $0.id == cut.fromClipId }),
              let to = track.clips.first(where: { $0.id == cut.toClipId }),
              from.startFrame + from.durationFrames == to.startFrame else {
            return .failure(TransitionPlanFailure("The two clips no longer meet at a cut."))
        }
        let existing = transition(on: cut)
        let alignment = existing?.alignment ?? .centre
        let wanted = lengthFrames ?? existing?.durationFrames ?? Self.defaultTransitionFrames
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
        if kind == .wipe || kind == .push, let direction, direction != .left { transition.direction = direction }
        if kind == .dip, let color, color.lowercased() != NativeCutTransition.defaultDipColor { transition.color = color }
        return .success((transition, length, wanted))
    }
}

/// Why a transition cannot go on a cut.
struct TransitionPlanFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
