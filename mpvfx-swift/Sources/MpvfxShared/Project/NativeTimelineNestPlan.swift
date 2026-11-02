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
// Nest, un-nest and make-unique plans: selected clips become one clip that holds them as its own small timeline, the
// clip's contents go back to the timeline, and a shared nested sequence is duplicated for one clip.
import Foundation

public enum NativeTimelineNestFailureCode: String, Sendable {
    case emptySelection = "empty-selection", clipNotFound = "clip-not-found", duplicateClip = "duplicate-clip"
    case notMainSequence = "not-main-sequence", lockedTrack = "locked-track", noVideoTrack = "no-video-track"
    case overlapsClip = "overlaps-clip", transitionCrossesSelection = "transition-crosses-selection"
    case notNested = "not-nested", sequenceMissing = "sequence-missing", unsupportedSequence = "unsupported-sequence"
    case trimmedOrRetimed = "trimmed-or-retimed", outerLookNotExpressible = "outer-look-not-expressible"
    case alreadyUnique = "already-unique", nativeCommandRejected = "native-command-rejected"
}

public struct NativeTimelineNestFailure: Error, Equatable {
    public var code: NativeTimelineNestFailureCode; public var message: String
    public init(code: NativeTimelineNestFailureCode, message: String) { self.code = code; self.message = message }
}

public struct NativeTimelineNestRequest: Equatable, Sendable {
    public var clips: [NativeProjectClipAddress]
    public init(clips: [NativeProjectClipAddress]) { self.clips = clips }
}

/// What Un-nest does with a look on the nested clip itself (grade, effects, animation, crop, fades, masks, ...) that
/// cannot be written into the clips it holds.
public enum NativeTimelineUnnestOuterLook: Sendable {
    /// Refuse and name what the nested clip carries, so the person can choose.
    case refuse
    /// Put the clips back and drop the nested clip's own look.
    case drop
}

public struct NativeTimelineUnnestRequest: Equatable, Sendable {
    public var address: NativeProjectClipAddress
    public var outerLook: NativeTimelineUnnestOuterLook
    public init(address: NativeProjectClipAddress, outerLook: NativeTimelineUnnestOuterLook = .refuse) {
        self.address = address; self.outerLook = outerLook
    }
}

public struct NativeTimelineNestPlan: Equatable {
    public var document: NativeProjectDocument
    public var sequenceId: String
    public var nestedClipId: String
}

public struct NativeTimelineUnnestPlan: Equatable {
    public var document: NativeProjectDocument
    /// The clips put back on the timeline, by their new ids (the ids they had inside the sequence when it was not shared).
    public var restoredClipIds: [String]
    /// Names of the nested clip's own look that were dropped (empty unless `.drop` was chosen and something was set).
    public var droppedLook: [String]
}

public struct NativeTimelineMakeUniquePlan: Equatable {
    public var document: NativeProjectDocument
    public var sequenceId: String
}

public typealias NativeTimelineNestPlanResult = Result<NativeTimelineNestPlan, NativeTimelineNestFailure>
public typealias NativeTimelineUnnestPlanResult = Result<NativeTimelineUnnestPlan, NativeTimelineNestFailure>
public typealias NativeTimelineMakeUniquePlanResult = Result<NativeTimelineMakeUniquePlan, NativeTimelineNestFailure>

private func fail<T>(_ code: NativeTimelineNestFailureCode, _ message: String) -> Result<T, NativeTimelineNestFailure> {
    .failure(.init(code: code, message: message))
}

/// Every id the document uses for tracks, clips, transitions, sequences and assets (new ids avoid all of them).
private func takenIds(_ d: NativeProjectDocument) -> Set<String> {
    var ids = Set<String>([d.sequence.id])
    ids.formUnion(d.assets.map(\.id)); ids.formUnion((d.sequences ?? []).map(\.id))
    let tracks = d.sequence.tracks + (d.sequences ?? []).flatMap(\.tracks)
    for t in tracks { ids.insert(t.id); for c in t.clips { ids.insert(c.id) }; for x in t.transitions ?? [] { if let id = x.id { ids.insert(id) } } }
    return ids
}

private func freshId(_ base: String, _ taken: inout Set<String>) -> String {
    var n = 2
    while taken.contains("\(base)-\(n)") { n += 1 }
    taken.insert("\(base)-\(n)")
    return "\(base)-\(n)"
}

private func insertSorted(_ clip: NativeProjectClip, into clips: inout [NativeProjectClip]) {
    if let at = clips.firstIndex(where: { $0.startFrame > clip.startFrame }) { clips.insert(clip, at: at) } else { clips.append(clip) }
}

private func occupied(_ clips: [NativeProjectClip], from start: Double, to end: Double) -> Bool {
    clips.contains { $0.startFrame < end && $0.startFrame + $0.durationFrames > start }
}

private func validated(_ d: NativeProjectDocument, _ engine: KeyframeEngine?) throws -> NativeProjectDocument {
    do { return try parseNativeProjectDocument(d, engine: engine) }
    catch let e as NativeProjectDocumentValidationError { throw NativeTimelineNestFailure(code: .nativeCommandRejected, message: e.message) }
}

/// Plans Nest: the selected clips (on the main sequence) move into a new nested sequence, keeping their tracks, their
/// order and their timing relative to the earliest of them, and one clip that shows the sequence takes their time span
/// on the lowest selected video track. The nested clip's asset is an element asset named after the sequence. A cut
/// transition between two selected clips goes in with them; one between a selected and an unselected clip refuses the
/// nest, as does a selection whose span on the target track holds an unselected clip.
public func planNativeTimelineNest(_ document: NativeProjectDocument, _ request: NativeTimelineNestRequest,
                                   engine: KeyframeEngine?) throws -> NativeTimelineNestPlanResult {
    if request.clips.isEmpty { return fail(.emptySelection, "Select at least one clip to nest") }
    var picked: [(track: Int, clip: Int)] = []
    var seen = Set<NativeProjectClipAddress>()
    for a in request.clips {
        if !seen.insert(a).inserted { return fail(.duplicateClip, "Clip \(a.clipId) is selected more than once") }
        guard a.sequenceId == document.sequence.id else { return fail(.notMainSequence, "Only clips of the main sequence can be nested") }
        guard let t = document.sequence.tracks.firstIndex(where: { $0.id == a.trackId }),
              let c = document.sequence.tracks[t].clips.firstIndex(where: { $0.id == a.clipId }) else {
            return fail(.clipNotFound, "Clip \(a.clipId) is not on track \(a.trackId)")
        }
        if document.sequence.tracks[t].locked == true { return fail(.lockedTrack, "Track \(a.trackId) is locked") }
        picked.append((t, c))
    }
    let chosen = Set(request.clips.map(\.clipId))
    let trackIndexes = Set(picked.map(\.track)).sorted()
    for t in trackIndexes {
        for x in document.sequence.tracks[t].transitions ?? [] {
            let ends = [x.fromClipId, x.toClipId].compactMap { $0 }
            if ends.contains(where: chosen.contains), !ends.allSatisfy(chosen.contains) {
                return fail(.transitionCrossesSelection, "A transition joins a selected clip to one that is not selected")
            }
        }
    }
    let layers = nativeTrackStackingLayers(document.sequence.tracks)
    guard let target = trackIndexes.filter({ document.sequence.tracks[$0].kind != .audio }).min(by: { layers[$0] < layers[$1] }) else {
        return fail(.noVideoTrack, "Select at least one clip on a video track to nest")
    }
    let selected = picked.map { document.sequence.tracks[$0.track].clips[$0.clip] }
    let start = selected.map(\.startFrame).min()!, end = selected.map { $0.startFrame + $0.durationFrames }.max()!

    var next = document
    var nestedTracks: [NativeProjectTrack] = []
    for t in trackIndexes {
        var track = document.sequence.tracks[t]
        let moved = track.clips.filter { chosen.contains($0.id) }
        var inner = track
        inner.clips = moved.map { var c = $0; c.startFrame -= start; return c }
        inner.transitions = track.transitions?.filter { x in [x.fromClipId, x.toClipId].compactMap { $0 }.allSatisfy(chosen.contains) }
        if inner.transitions?.isEmpty == true { inner.transitions = nil }
        nestedTracks.append(inner)
        track.clips.removeAll { chosen.contains($0.id) }
        track.transitions = track.transitions?.filter { x in ![x.fromClipId, x.toClipId].compactMap { $0 }.allSatisfy(chosen.contains) }
        if track.transitions?.isEmpty == true { track.transitions = nil }
        next.sequence.tracks[t] = track
    }
    if occupied(next.sequence.tracks[target].clips, from: start, to: end) {
        return fail(.overlapsClip, "A clip that is not selected sits inside the span of the selection on its lowest video track")
    }

    var taken = takenIds(document)
    var n = 1
    while taken.contains("sequence:nest-\(n)") || taken.contains("asset:nest-\(n)") || taken.contains("clip:nest-\(n)") { n += 1 }
    let sequenceId = "sequence:nest-\(n)", assetId = "asset:nest-\(n)", clipId = "clip:nest-\(n)"
    taken.formUnion([sequenceId, assetId, clipId])
    let name = "Nested sequence \(n)"
    next.assets.append(NativeProjectAsset(id: assetId, kind: .element, name: name, durationFrames: end - start))
    var nested = NativeNestedSequence(id: sequenceId, name: name, tracks: nestedTracks,
                                      size: .init(width: document.canvas.width, height: document.canvas.height), fps: document.frameRate)
    nested.fps.spread = .init()
    next.sequences = (document.sequences ?? []) + [nested]
    var nestClip = NativeProjectClip.fresh(id: clipId, assetId: assetId, startFrame: start, durationFrames: end - start)
    nestClip.staticParameters = nil
    nestClip.sequenceId = sequenceId
    insertSorted(nestClip, into: &next.sequence.tracks[target].clips)
    do { return .success(.init(document: try validated(next, engine), sequenceId: sequenceId, nestedClipId: clipId)) }
    catch let f as NativeTimelineNestFailure { return .failure(f) }
}

/// The names of what a nested clip carries beyond its place on the timeline: its own look, which cannot be written
/// into the clips it holds.
func nativeNestedClipOuterLook(_ clip: NativeProjectClip) -> [String] {
    var names: [String] = []
    func note(_ name: String, _ present: Bool) { if present { names.append(name) } }
    note("effects", !clip.effects.isEmpty); note("keyframes", !clip.parameterTracks.isEmpty)
    note("size and position", !(clip.staticParameters?.isEmpty ?? true)); note("crop", clip.crop != nil)
    note("style", clip.style != nil); note("moves", clip.moves != nil); note("fades", clip.fadeInFrames != nil || clip.fadeOutFrames != nil)
    note("masks", clip.masks != nil); note("fit", clip.fit != nil); note("fill", clip.fill != nil)
    note("hidden", clip.hidden != nil); note("muted", clip.muted); note("audio", clip.audioGroupId != nil || clip.audioFxChain != nil || clip.audioAutomation != nil)
    note("pivot segments", clip.cropPivotSegments != nil); note("scale lock", clip.scaleRatioLocked != nil)
    return names
}

/// Plans Un-nest: the clips of the nested sequence go back to their tracks (a track that no longer exists is added
/// back from the sequence) at the nested clip's place; the nested clip goes. The nested clip must not be trimmed or
/// retimed. A look on the nested clip is not composed into the clips (there is no adjustment layer to keep it on yet):
/// it refuses, or with `.drop` is dropped. When the sequence is still shown by another clip it stays, and the restored
/// clips get new ids; otherwise it and its asset go and the clips keep their ids, so Nest then Un-nest restores the
/// document exactly.
public func planNativeTimelineUnnest(_ document: NativeProjectDocument, _ request: NativeTimelineUnnestRequest,
                                     engine: KeyframeEngine?) throws -> NativeTimelineUnnestPlanResult {
    let a = request.address
    guard a.sequenceId == document.sequence.id else { return fail(.notMainSequence, "Only a clip of the main sequence can be un-nested") }
    guard let t = document.sequence.tracks.firstIndex(where: { $0.id == a.trackId }),
          let c = document.sequence.tracks[t].clips.firstIndex(where: { $0.id == a.clipId }) else {
        return fail(.clipNotFound, "Clip \(a.clipId) is not on track \(a.trackId)")
    }
    if document.sequence.tracks[t].locked == true { return fail(.lockedTrack, "Track \(a.trackId) is locked") }
    let nestClip = document.sequence.tracks[t].clips[c]
    guard let sequenceId = nestClip.sequenceId else { return fail(.notNested, "Clip \(a.clipId) is not a nested clip") }
    guard let nested = document.nestedSequence(id: sequenceId) else { return fail(.sequenceMissing, "Missing nested sequence \(sequenceId)") }
    guard nested.isSupported else { return fail(.unsupportedSequence, "Nested sequence \(sequenceId) is from a newer version of the editor") }
    let rate = nestClip.playbackRate
    if nestClip.sourceInFrame != 0 || nestClip.sourceInFraction != nil || nestClip.speedRamp != nil || nestClip.holdSourceFrame != nil
        || (rate != nil && rate?.numerator != rate?.denominator) || nestClip.durationFrames != nested.contentFrames {
        return fail(.trimmedOrRetimed, "The nested clip is trimmed or retimed; restore its length and speed first")
    }
    let look = nativeNestedClipOuterLook(nestClip)
    if !look.isEmpty, case .refuse = request.outerLook {
        return fail(.outerLookNotExpressible, "The nested clip has its own \(look.joined(separator: ", ")); Un-nest cannot write that into the clips it holds")
    }

    var next = document
    next.sequence.tracks[t].clips.remove(at: c)
    let shared = document.nestedClipCount(sequenceId: sequenceId) > 1
    var taken = takenIds(document)
    var renamed: [String: String] = [:]
    var restored: [String] = []
    for inner in nested.tracks {
        var idx = next.sequence.tracks.firstIndex { $0.id == inner.id }
        if idx == nil {
            var empty = inner; empty.clips = []; empty.transitions = nil
            next.sequence.tracks.append(empty); idx = next.sequence.tracks.count - 1
        }
        for var clip in inner.clips {
            clip.startFrame += nestClip.startFrame
            if shared { let old = clip.id; clip.id = freshId(old, &taken); renamed[old] = clip.id }
            restored.append(clip.id)
            if occupied(next.sequence.tracks[idx!].clips, from: clip.startFrame, to: clip.startFrame + clip.durationFrames) {
                return fail(.overlapsClip, "Clip \(clip.id) would land on another clip of track \(inner.id)")
            }
            insertSorted(clip, into: &next.sequence.tracks[idx!].clips)
        }
        for x in inner.transitions ?? [] {
            var object = x.object
            if shared {
                object["id"] = .string(freshId(x.id ?? "transition", &taken))
                if let f = x.fromClipId, let r = renamed[f] { object["fromClipId"] = .string(r) }
                if let to = x.toClipId, let r = renamed[to] { object["toClipId"] = .string(r) }
            }
            next.sequence.tracks[idx!].transitions = (next.sequence.tracks[idx!].transitions ?? []) + [NativeCutTransition(object: object)]
        }
    }
    if !shared {
        next.sequences = document.sequences?.filter { $0.id != sequenceId }
        if next.sequences?.isEmpty == true { next.sequences = nil }
        let stillUsed = (next.sequence.tracks + (next.sequences ?? []).flatMap(\.tracks)).contains { $0.clips.contains { $0.assetId == nestClip.assetId } }
        if !stillUsed { next.assets.removeAll { $0.id == nestClip.assetId } }
    }
    do { return .success(.init(document: try validated(next, engine), restoredClipIds: restored, droppedLook: look)) }
    catch let f as NativeTimelineNestFailure { return .failure(f) }
}

/// Plans Make unique: the clip gets its own copy of a nested sequence it shares with other clips (new sequence id,
/// new clip and transition ids inside it, its own element asset); the other clips keep the original. Refused when the
/// clip is the only one showing the sequence.
public func planNativeTimelineMakeUnique(_ document: NativeProjectDocument, address a: NativeProjectClipAddress,
                                         engine: KeyframeEngine?) throws -> NativeTimelineMakeUniquePlanResult {
    guard a.sequenceId == document.sequence.id else { return fail(.notMainSequence, "Only a clip of the main sequence can be made unique") }
    guard let t = document.sequence.tracks.firstIndex(where: { $0.id == a.trackId }),
          let c = document.sequence.tracks[t].clips.firstIndex(where: { $0.id == a.clipId }) else {
        return fail(.clipNotFound, "Clip \(a.clipId) is not on track \(a.trackId)")
    }
    if document.sequence.tracks[t].locked == true { return fail(.lockedTrack, "Track \(a.trackId) is locked") }
    let clip = document.sequence.tracks[t].clips[c]
    guard let sequenceId = clip.sequenceId else { return fail(.notNested, "Clip \(a.clipId) is not a nested clip") }
    guard let original = document.nestedSequence(id: sequenceId) else { return fail(.sequenceMissing, "Missing nested sequence \(sequenceId)") }
    guard original.isSupported else { return fail(.unsupportedSequence, "Nested sequence \(sequenceId) is from a newer version of the editor") }
    if document.nestedClipCount(sequenceId: sequenceId) < 2 { return fail(.alreadyUnique, "Only this clip shows the nested sequence") }

    var taken = takenIds(document)
    var copy = original
    copy.id = freshId(original.id, &taken)
    copy.name = "\(original.name) copy"
    var renamed: [String: String] = [:]
    for ti in copy.tracks.indices {
        for ci in copy.tracks[ti].clips.indices {
            let old = copy.tracks[ti].clips[ci].id
            copy.tracks[ti].clips[ci].id = freshId(old, &taken); renamed[old] = copy.tracks[ti].clips[ci].id
        }
    }
    for ti in copy.tracks.indices {
        copy.tracks[ti].transitions = copy.tracks[ti].transitions?.map { x in
            var o = x.object
            o["id"] = .string(freshId(x.id ?? "transition", &taken))
            if let f = x.fromClipId, let r = renamed[f] { o["fromClipId"] = .string(r) }
            if let to = x.toClipId, let r = renamed[to] { o["toClipId"] = .string(r) }
            return NativeCutTransition(object: o)
        }
    }
    var next = document
    let assetId = freshId(clip.assetId, &taken)
    if let source = document.assets.first(where: { $0.id == clip.assetId }) {
        var asset = source; asset.id = assetId; asset.name = copy.name
        next.assets.append(asset)
    }
    next.sequences = (document.sequences ?? []) + [copy]
    next.sequence.tracks[t].clips[c].sequenceId = copy.id
    next.sequence.tracks[t].clips[c].assetId = assetId
    do { return .success(.init(document: try validated(next, engine), sequenceId: copy.id)) }
    catch let f as NativeTimelineNestFailure { return .failure(f) }
}
