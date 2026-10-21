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
// Cut transition edits (add, set length, kind, alignment or colour, remove), each one document change with a
// restore-document inverse, so each is one undo step; and the rules clip edits follow: moving a clip away from the
// other, or deleting either, removes the transition, a split inside its range removes it, and a trim that leaves
// too little media shortens it to what fits, all in the same step as the clip edit.
import Foundation

public enum NativeCutTransitionCommand: Equatable {
    /// Adds `transition` (its `fromClipId` / `toClipId` name two touching clips of the track).
    case add(trackId: String, transition: NativeCutTransition)
    case setLength(id: String, durationFrames: Double)
    case setKind(id: String, kind: NativeCutTransitionKind)
    case setAlignment(id: String, alignment: NativeCutTransitionAlignment)
    /// nil: the default dip colour (black).
    case setColor(id: String, color: String?)
    case remove(id: String)
}

/// Applies a transition edit. A refusal (unknown track or transition, a value the validator rejects, a dissolve
/// with too little handle) returns `.failure` with the unchanged document; nothing is clamped.
public func applyNativeCutTransitionCommand(_ d: NativeProjectDocument, _ command: NativeCutTransitionCommand,
                                            engine: KeyframeEngine? = nil) throws -> NativeProjectClipCommandResult {
    let edited: (document: NativeProjectDocument, id: String)
    switch editedTransitions(d, command) {
    case .failure(let f): return .failure(document: d, failure: f)
    case .success(let e): edited = e
    }
    if let shortfall = nativeDissolveShortfall(edited.document, transitionId: edited.id) {
        return .failure(document: d, failure: .init(code: .insufficientHandles, message: shortfall))
    }
    do {
        let parsed = try parseNativeProjectDocument(edited.document, engine: engine)
        return .success(document: parsed, inverse: .restoreDocument(try cloneNativeDocument(d, engine)))
    } catch let e as NativeProjectDocumentValidationError {
        return .failure(document: d, failure: .init(code: .invalidTransition, message: e.message))
    }
}

/// Where a transition is: its track and its index there.
private func locateTransition(_ d: NativeProjectDocument, _ id: String) -> (track: Int, index: Int)? {
    for (t, track) in d.sequence.tracks.enumerated() {
        if let i = track.cutTransitions.firstIndex(where: { $0.id == id }) { return (t, i) }
    }
    return nil
}

/// The document with the command's change made (not yet validated), and the id of the transition it touched.
private func editedTransitions(_ d: NativeProjectDocument, _ command: NativeCutTransitionCommand)
    -> Result<(document: NativeProjectDocument, id: String), NativeProjectClipFailure> {
    var next = d
    if case let .add(trackId, transition) = command {
        guard let t = d.sequence.tracks.firstIndex(where: { $0.id == trackId }) else {
            return .failure(.init(code: .missingSourceTrack, message: "Track \(trackId) does not exist"))
        }
        next.sequence.tracks[t].transitions = d.sequence.tracks[t].cutTransitions + [transition]
        return .success((next, transition.id ?? ""))
    }
    let id = transitionId(of: command)
    guard let at = locateTransition(d, id) else {
        return .failure(.init(code: .missingTransition, message: "Transition \(id) does not exist"))
    }
    var list = d.sequence.tracks[at.track].cutTransitions
    if case .remove = command { list.remove(at: at.index) } else { edit(&list[at.index], command) }
    next.sequence.tracks[at.track].transitions = list.isEmpty ? nil : list
    return .success((next, id))
}

private func transitionId(of command: NativeCutTransitionCommand) -> String {
    switch command {
    case .add(_, let t): t.id ?? ""
    case .setLength(let id, _), .setKind(let id, _), .setAlignment(let id, _), .setColor(let id, _), .remove(let id): id
    }
}

private func edit(_ t: inout NativeCutTransition, _ command: NativeCutTransitionCommand) {
    switch command {
    case .setLength(_, let length): t.durationFrames = length
    case .setKind(_, let kind): t.kind = kind
    case .setAlignment(_, let alignment): t.alignment = alignment
    case .setColor(_, let color): t.color = color
    case .add, .remove: break
    }
}

/// The refusal message when the dissolve `transitionId` needs more media than one of its clips has beyond its in or
/// out point ("Clip "Interview 2" has 6 frames of media after its out point; this dissolve needs 12"); nil when it
/// fits, is a dip, or cannot be checked yet (the validator then reports what is wrong).
public func nativeDissolveShortfall(_ d: NativeProjectDocument, transitionId: String) -> String? {
    guard let at = locateTransition(d, transitionId) else { return nil }
    let track = d.sequence.tracks[at.track], entry = track.cutTransitions[at.index]
    guard entry.isKnown, entry.kind == .dissolve, let alignment = entry.alignment, let length = entry.durationFrames,
          let from = track.clips.first(where: { $0.id == entry.fromClipId }),
          let to = track.clips.first(where: { $0.id == entry.toClipId }) else { return nil }
    let asset = { (c: NativeProjectClip) in d.assets.first { $0.id == c.assetId } }
    let range = nativeCutTransitionRange(cut: to.startFrame, length: length, alignment: alignment)
    let needAfter = range.end - to.startFrame, needBefore = to.startFrame - range.start
    let fromHandles = nativeClipHandles(from, asset: asset(from)), toHandles = nativeClipHandles(to, asset: asset(to))
    if needAfter > fromHandles.after {
        return handleMessage(asset(from)?.name ?? from.id, has: fromHandles.after, side: "after its out point", needs: needAfter)
    }
    if needBefore > toHandles.before {
        return handleMessage(asset(to)?.name ?? to.id, has: toHandles.before, side: "before its in point", needs: needBefore)
    }
    return nil
}

private func handleMessage(_ name: String, has: Double, side: String, needs: Double) -> String {
    let frames = has == 1 ? "1 frame" : "\(jsNumberString(has)) frames"
    return "Clip \"\(name)\" has \(frames) of media \(side); this dissolve needs \(jsNumberString(needs))"
}

// MARK: Clip edits

/// The document with every known transition made to fit its clips after a clip edit: a transition whose clips
/// are gone from its track or no longer touch is removed, and one longer than its clips or (a dissolve) their
/// handles allow is shortened to the longest that fits, or removed when not even one frame fits. Entries from a
/// newer version of the editor are kept as they are.
public func reconcileNativeCutTransitions(_ d: NativeProjectDocument) -> NativeProjectDocument {
    let assets = Dictionary(d.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var out = d
    for t in out.sequence.tracks.indices where out.sequence.tracks[t].transitions != nil {
        out.sequence.tracks[t].transitions = reconciledTransitions(out.sequence.tracks[t], assets)
    }
    return out
}

private func reconciledTransitions(_ track: NativeProjectTrack, _ assets: [String: NativeProjectAsset]) -> [NativeCutTransition]? {
    let list = track.cutTransitions
    let clips = Dictionary(track.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var kept: [NativeCutTransition] = []
    for var entry in list {
        guard entry.isKnown else { kept.append(entry); continue }
        guard let kind = entry.kind, let alignment = entry.alignment,
              let from = entry.fromClipId.flatMap({ clips[$0] }), let to = entry.toClipId.flatMap({ clips[$0] }),
              from.startFrame + from.durationFrames == to.startFrame else { continue }
        let limit = nativeMaxTransitionLength(kind: kind, alignment: alignment, from: NativeTransitionSide(from, asset: assets[from.assetId]),
                                              to: NativeTransitionSide(to, asset: assets[to.assetId]))
        if let length = entry.durationFrames, length > limit {
            guard limit >= 1 else { continue }
            entry.durationFrames = limit
        }
        kept.append(entry)
    }
    return kept.isEmpty && !list.isEmpty ? nil : kept
}

/// A track's transitions after `clipId` is split at `splitFrame` into itself and `rightId`: a split inside a
/// transition's range removes it; a split before the range of the clip's outgoing transition hands that
/// transition to the right part, which now meets the next clip.
func nativeCutTransitionsAfterSplit(_ track: NativeProjectTrack, clipId: String, splitFrame: Double, rightId: String) -> [NativeCutTransition]? {
    guard let list = track.transitions else { return nil }
    let starts = Dictionary(track.clips.map { ($0.id, $0.startFrame) }, uniquingKeysWith: { a, _ in a })
    var kept: [NativeCutTransition] = []
    for var entry in list {
        guard entry.isKnown, entry.fromClipId == clipId || entry.toClipId == clipId,
              let alignment = entry.alignment, let length = entry.durationFrames,
              let cut = entry.toClipId.flatMap({ starts[$0] }) else { kept.append(entry); continue }
        let range = nativeCutTransitionRange(cut: cut, length: length, alignment: alignment)
        if entry.fromClipId == clipId {
            guard splitFrame <= range.start else { continue }
            entry.object["fromClipId"] = .string(rightId)
        } else if splitFrame < range.end { continue }
        kept.append(entry)
    }
    return kept.isEmpty && !list.isEmpty ? nil : kept
}

/// What a clip edit did to the transitions, for the toast ("Removed the transition between "A" and "B"…"); nil
/// when it changed none.
public func nativeCutTransitionChangeNotice(before: NativeProjectDocument, after: NativeProjectDocument) -> String? {
    let names = Dictionary(before.assets.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    let clipNames = Dictionary(before.sequence.tracks.flatMap(\.clips).map { ($0.id, names[$0.assetId] ?? $0.id) },
                               uniquingKeysWith: { a, _ in a })
    let kept = Dictionary(after.sequence.tracks.flatMap(\.cutTransitions).compactMap { t in t.id.map { ($0, t) } },
                          uniquingKeysWith: { a, _ in a })
    var lines: [String] = []
    for old in before.sequence.tracks.flatMap(\.cutTransitions) where old.isKnown {
        guard let id = old.id else { continue }
        let between = "the transition between \"\(clipNames[old.fromClipId ?? ""] ?? "?")\" and \"\(clipNames[old.toClipId ?? ""] ?? "?")\""
        guard let new = kept[id] else { lines.append("Removed \(between): its clips no longer meet at that cut."); continue }
        if let was = old.durationFrames, let now = new.durationFrames, now < was {
            let by = was - now == 1 ? "1 frame" : "\(jsNumberString(was - now)) frames"
            lines.append("Shortened \(between) by \(by) to fit the media.")
        }
    }
    return lines.isEmpty ? nil : lines.joined(separator: " ")
}
