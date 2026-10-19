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
// Clip commands on a native document (move, trim, split, delete, restore). Rejections return the unchanged input
// document; `throws` only for re-parse failures outside a try and engine errors from slicing.
import Foundation

public struct NativeProjectClipAddress: Codable, Equatable, Hashable {
    public var sequenceId: String, trackId: String, clipId: String
    public init(sequenceId: String, trackId: String, clipId: String) { self.sequenceId = sequenceId; self.trackId = trackId; self.clipId = clipId }
}
public struct NativeProjectClipDestination: Codable, Equatable {
    public var trackId: String; public var startFrame: Double
    public init(trackId: String, startFrame: Double) { self.trackId = trackId; self.startFrame = startFrame }
}
public struct NativeProjectClipMove: Equatable {
    public var address: NativeProjectClipAddress; public var destination: NativeProjectClipDestination
    public init(address: NativeProjectClipAddress, destination: NativeProjectClipDestination) { self.address = address; self.destination = destination }
}

public indirect enum NativeProjectClipCommand: Equatable {
    case move(address: NativeProjectClipAddress, destination: NativeProjectClipDestination)
    case moveMany([NativeProjectClipMove])
    case trimIn(address: NativeProjectClipAddress, startFrame: Double)
    case trimOut(address: NativeProjectClipAddress, endFrameExclusive: Double)
    /// `rightBinding` is required when the source clip has a legacy DOM binding.
    case split(address: NativeProjectClipAddress, splitFrame: Double, rightBinding: NativeClipDomBinding? = nil)
    case delete(address: NativeProjectClipAddress)
    case deleteMany([NativeProjectClipAddress])
    case restoreDocument(NativeProjectDocument)
}

public enum NativeProjectClipFailureCode: String, Codable {
    case missingSequence = "missing-sequence", missingSourceTrack = "missing-source-track", missingDestinationTrack = "missing-destination-track"
    case missingClip = "missing-clip", incompatibleDestination = "incompatible-destination", invalidStartFrame = "invalid-start-frame"
    case duplicateTarget = "duplicate-target", destinationCollision = "destination-collision", invalidTrim = "invalid-trim"
    case invalidSplit = "invalid-split", nonIntegralSourceBoundary = "non-integral-source-boundary"
    case missingSplitBinding = "missing-split-binding", invalidSplitBinding = "invalid-split-binding"
    case duplicateSplitBinding = "duplicate-split-binding", generatedIdCollision = "generated-id-collision", documentMismatch = "document-mismatch"
}

public struct NativeProjectClipFailure: Equatable, Error {
    public var code: NativeProjectClipFailureCode; public var message: String
    public init(code: NativeProjectClipFailureCode, message: String) { self.code = code; self.message = message }
}

public enum NativeProjectClipCommandResult: Equatable {
    case success(document: NativeProjectDocument, inverse: NativeProjectClipCommand)
    /// The exact original document, never a partial clone.
    case failure(document: NativeProjectDocument, failure: NativeProjectClipFailure)
    public var ok: Bool { if case .success = self { return true }; return false }
    public var document: NativeProjectDocument { switch self { case .success(let d, _), .failure(let d, _): d } }
    public var failure: NativeProjectClipFailure? { if case .failure(_, let f) = self { return f }; return nil }
    public var inverse: NativeProjectClipCommand? { if case .success(_, let i) = self { return i }; return nil }
}

private func reject(_ d: NativeProjectDocument, _ code: NativeProjectClipFailureCode, _ m: String) -> NativeProjectClipCommandResult {
    .failure(document: d, failure: .init(code: code, message: m))
}
private func succeed(_ original: NativeProjectDocument, _ d: NativeProjectDocument, _ engine: KeyframeEngine?) throws -> NativeProjectClipCommandResult {
    .success(document: d, inverse: .restoreDocument(try cloneNativeDocument(original, engine)))
}

/// JSON.stringify([sequenceId, trackId, clipId]).
func moveAddressKey(_ a: NativeProjectClipAddress) -> String {
    jsJSONStringify(.array([.string(a.sequenceId), .string(a.trackId), .string(a.clipId)]))
}

/// Stable child clip ID: split commands are reproducible and collision-checkable.
public func nativeSplitClipId(_ clipId: String, splitFrame: Double) -> String { "native-split:\(clipId)|frame:\(jsNumberString(splitFrame))" }
private func nativeSplitTrackId(_ trackId: String, _ splitClipId: String, _ parameterId: String) -> String {
    "native-split-track:\(trackId)|clip:\(splitClipId)|parameter:\(parameterId)"
}
private func nativeSplitBaselineKeyframeId(_ trackId: String, _ splitFrame: Double) -> String {
    "native-split-baseline:\(trackId)|frame:\(jsNumberString(splitFrame))"
}

private struct ClipLocation { let trackIndex: Int; let clipIndex: Int; let track: NativeProjectTrack; let clip: NativeProjectClip }

private func locate(_ d: NativeProjectDocument, _ a: NativeProjectClipAddress) -> Result<ClipLocation, NativeProjectClipFailure> {
    if d.sequence.id != a.sequenceId { return .failure(.init(code: .missingSequence, message: "Sequence \(a.sequenceId) does not exist")) }
    guard let t = d.sequence.tracks.firstIndex(where: { $0.id == a.trackId }) else {
        return .failure(.init(code: .missingSourceTrack, message: "Track \(a.trackId) does not exist"))
    }
    let track = d.sequence.tracks[t]
    guard let c = track.clips.firstIndex(where: { $0.id == a.clipId }) else {
        return .failure(.init(code: .missingClip, message: "Clip \(a.clipId) does not exist on track \(track.id)"))
    }
    return .success(.init(trackIndex: t, clipIndex: c, track: track, clip: track.clips[c]))
}

private struct LocatedMove { let move: NativeProjectClipMove; let clip: NativeProjectClip; let destinationTrackIndex: Int }

/// Validate every requested edit against the same original document before mutation.
private func locateMoves(_ d: NativeProjectDocument, _ moves: [NativeProjectClipMove]) -> Result<[LocatedMove], NativeProjectClipFailure> {
    var addressed = Set<String>(), located: [LocatedMove] = []
    for m in moves {
        if d.sequence.id != m.address.sequenceId { return .failure(.init(code: .missingSequence, message: "Sequence \(m.address.sequenceId) does not exist")) }
        if !jsIsInteger(m.destination.startFrame) || m.destination.startFrame < 0 {
            return .failure(.init(code: .invalidStartFrame, message: "Destination startFrame must be a non-negative integer"))
        }
        let key = moveAddressKey(m.address)
        if addressed.contains(key) { return .failure(.init(code: .duplicateTarget, message: "Clip \(m.address.clipId) is targeted more than once")) }
        addressed.insert(key)
        guard let s = d.sequence.tracks.firstIndex(where: { $0.id == m.address.trackId }) else {
            return .failure(.init(code: .missingSourceTrack, message: "Track \(m.address.trackId) does not exist"))
        }
        let source = d.sequence.tracks[s]
        guard let c = source.clips.firstIndex(where: { $0.id == m.address.clipId }) else {
            return .failure(.init(code: .missingClip, message: "Clip \(m.address.clipId) does not exist on track \(source.id)"))
        }
        guard let dest = d.sequence.tracks.firstIndex(where: { $0.id == m.destination.trackId }) else {
            return .failure(.init(code: .missingDestinationTrack, message: "Destination track \(m.destination.trackId) does not exist"))
        }
        located.append(.init(move: m, clip: source.clips[c], destinationTrackIndex: dest))
    }
    return .success(located)
}

private func replaceClip(_ d: NativeProjectDocument, _ loc: ClipLocation, _ replacement: [NativeProjectClip], _ engine: KeyframeEngine?) throws -> NativeProjectDocument {
    var next = d
    next.sequence.tracks[loc.trackIndex].clips.replaceSubrange(loc.clipIndex...loc.clipIndex, with: replacement)
    return try parseNativeProjectDocument(next, engine: engine)
}

/// Rebase a parameter track to a playable subrange. The engine cuts the track (timing curves and motion paths included)
/// so every remaining frame evaluates exactly as before; authored keys keep their identity, generated ones get
/// deterministic split-baseline IDs.
private func rebaseTrack(_ track: NativeParameterTrack, _ from: Double, _ until: Double, _ nextId: String, _ engine: KeyframeEngine?) throws -> NativeParameterTrack {
    var authoredIdByFrame: [Double: String] = [:]
    for k in track.keyframes { authoredIdByFrame[k.frame] = k.id }   // JS Map: a later duplicate frame wins (cannot occur)
    let keys = try (engine ?? keyframeEngine()).slice(VkfTrack(track), fromFrame: from, untilFrameExclusive: until).map { k in
        NativeKeyframe(id: (!k.generated ? authoredIdByFrame[k.sourceFrame] : nil).flatMap { $0.isEmpty ? nil : $0 }
                            ?? nativeSplitBaselineKeyframeId(track.id, k.sourceFrame),
                       frame: k.frame, value: k.value, outgoing: k.outgoing, outgoingPath: k.outgoingPath)
    }
    return try createNativeParameterTrack(.init(id: nextId, parameterId: track.parameterId, valueType: track.valueType,
                                                frameRate: track.frameRate, keyframes: keys, autoRotate: track.autoRotate), engine: engine)
}

private func rebasedTracks(_ clip: NativeProjectClip, _ from: Double, _ until: Double, _ engine: KeyframeEngine?,
                           _ idFor: (NativeParameterTrack) -> String) throws -> [NativeParameterTrack] {
    try clip.parameterTracks.map { try rebaseTrack($0, from, until, idFor($0), engine) }
}

private func setSource(_ clip: inout NativeProjectClip, _ p: NativeSourcePosition) {
    clip.sourceInFrame = p.sourceInFrame; clip.sourceInFraction = p.sourceInFraction   // sets `sourceInFraction` even when nil
}

private func applyTrimIn(_ d: NativeProjectDocument, _ a: NativeProjectClipAddress, _ startFrame: Double, _ engine: KeyframeEngine?) throws -> NativeProjectClipCommandResult {
    let loc: ClipLocation
    switch locate(d, a) { case .failure(let f): return reject(d, f.code, f.message); case .success(let l): loc = l }
    let delta = startFrame - loc.clip.startFrame
    if !isSafeInteger(startFrame) || startFrame < 0 || delta >= loc.clip.durationFrames {
        return reject(d, .invalidTrim, "Trim-in start must be a nonnegative integer before the clip end")
    }
    let clip = loc.clip
    let kind = d.assets.first { $0.id == clip.assetId }?.kind
    let position: NativeSourcePosition
    do {
        // Overflow mapping: a 64-bit overflow is a NativeSourceTimeRangeError and lands in this catch like the other
        // range errors; both become an invalid-trim rejection.
        position = try advanceSourcePosition(.init(sourceInFrame: clip.sourceInFrame, sourceInFraction: clip.sourceInFraction),
            playbackRate: clip.playbackRate, timelineFrames: kind.map { !nativeAssetConsumesSourceFrames($0) } == true ? 0 : delta)
    } catch { return reject(d, .invalidTrim, errorMessage(error) ?? "Invalid source boundary") }
    let tracks = try rebasedTracks(clip, delta, clip.durationFrames, engine) { $0.id }
    var next = clip
    next.startFrame = startFrame; setSource(&next, position)
    next.durationFrames = clip.durationFrames - delta
    next.parameterTracks = tracks
    next.cropPivotSegments = rebaseNativeCropPivotSegments(clip, rebasedTracks: tracks, fromFrame: delta, untilFrameExclusive: clip.durationFrames)
    return try succeed(d, try replaceClip(d, loc, [next], engine), engine)
}

private func applyTrimOut(_ d: NativeProjectDocument, _ a: NativeProjectClipAddress, _ end: Double, _ engine: KeyframeEngine?) throws -> NativeProjectClipCommandResult {
    let loc: ClipLocation
    switch locate(d, a) { case .failure(let f): return reject(d, f.code, f.message); case .success(let l): loc = l }
    let nextDuration = end - loc.clip.startFrame
    if !isSafeInteger(end) || nextDuration <= 0 { return reject(d, .invalidTrim, "Trim-out end must be an integer after the clip start") }
    let clip = loc.clip
    let asset = d.assets.first { $0.id == clip.assetId }!
    if nativeAssetConsumesSourceFrames(asset.kind) {
        let fits: Bool
        do {
            fits = try sourceRangeFits(.init(sourceInFrame: clip.sourceInFrame, sourceInFraction: clip.sourceInFraction),
                                       playbackRate: clip.playbackRate, durationFrames: nextDuration, sourceDurationFrames: asset.durationFrames)
        } catch {
            // Overflow mapping: an end point beyond 64 bits is far past any real asset, so it is
            // treated like an out-of-range answer (`fits == false`): the same invalid-trim rejection.
            fits = false
        }
        if !fits { return reject(d, .invalidTrim, "Cannot extend beyond the end of the source media") }
    }
    let shrinking = nextDuration < clip.durationFrames
    let tracks = shrinking ? try rebasedTracks(clip, 0, nextDuration, engine) { $0.id } : clip.parameterTracks
    var next = clip
    next.durationFrames = nextDuration
    next.parameterTracks = tracks
    next.cropPivotSegments = shrinking ? rebaseNativeCropPivotSegments(clip, rebasedTracks: tracks, fromFrame: 0, untilFrameExclusive: nextDuration)
                                       : clip.cropPivotSegments
    return try succeed(d, try replaceClip(d, loc, [next], engine), engine)
}

private func applySplit(_ d: NativeProjectDocument, _ a: NativeProjectClipAddress, _ splitFrame: Double, _ rightBinding: NativeClipDomBinding?,
                        _ engine: KeyframeEngine?) throws -> NativeProjectClipCommandResult {
    let loc: ClipLocation
    switch locate(d, a) { case .failure(let f): return reject(d, f.code, f.message); case .success(let l): loc = l }
    let clip = loc.clip
    let local = splitFrame - clip.startFrame
    if !isSafeInteger(splitFrame) || local <= 0 || local >= clip.durationFrames {
        return reject(d, .invalidSplit, "Split frame must be an integer strictly inside the clip")
    }
    let position: NativeSourcePosition
    do {
        let asset = d.assets.first { $0.id == clip.assetId }!
        // Overflow mapping: as in trim-in, a 64-bit overflow is rejected like the other range errors (invalid-split).
        position = try advanceSourcePosition(.init(sourceInFrame: clip.sourceInFrame, sourceInFraction: clip.sourceInFraction),
            playbackRate: clip.playbackRate, timelineFrames: nativeAssetConsumesSourceFrames(asset.kind) ? local : 0)
    } catch { return reject(d, .invalidSplit, errorMessage(error) ?? "Invalid source boundary") }
    if clip.binding != nil && rightBinding == nil {
        return reject(d, .missingSplitBinding, "Splitting a bound clip requires an explicit unique binding for the right clip")
    }
    let rightId = nativeSplitClipId(clip.id, splitFrame: splitFrame)
    if d.sequence.tracks.contains(where: { $0.clips.contains { $0.id == rightId } }) {
        return reject(d, .generatedIdCollision, "Split clip ID \(rightId) already exists")
    }
    let leftTracks = try rebasedTracks(clip, 0, local, engine) { $0.id }
    let rightTracks = try rebasedTracks(clip, local, clip.durationFrames, engine) { nativeSplitTrackId($0.id, rightId, $0.parameterId) }
    var left = clip
    left.durationFrames = local; left.parameterTracks = leftTracks
    left.cropPivotSegments = rebaseNativeCropPivotSegments(clip, rebasedTracks: leftTracks, fromFrame: 0, untilFrameExclusive: local)
    var right = clip
    right.id = rightId; right.startFrame = splitFrame; right.durationFrames = clip.durationFrames - local
    setSource(&right, position)
    if let rightBinding { right.binding = rightBinding }
    right.parameterTracks = rightTracks
    right.cropPivotSegments = rebaseNativeCropPivotSegments(clip, rebasedTracks: rightTracks, fromFrame: local, untilFrameExclusive: clip.durationFrames)
    do { return try succeed(d, try replaceClip(d, loc, [left, right], engine), engine) }
    catch let e as NativeProjectDocumentValidationError {
        if e.issues.contains(where: { $0.code == .duplicateBinding }) {
            return reject(d, .duplicateSplitBinding, "The right clip binding must be unique within the native project")
        }
        if e.issues.contains(where: { $0.code == .invalidBinding }) { return reject(d, .invalidSplitBinding, "The right clip binding is invalid") }
        throw e
    }
}

private func applyDeleteMany(_ d: NativeProjectDocument, _ addresses: [NativeProjectClipAddress], _ engine: KeyframeEngine?) throws -> NativeProjectClipCommandResult {
    var seen = Set<String>(), locations: [ClipLocation] = []
    for a in addresses {
        let key = moveAddressKey(a)
        if seen.contains(key) { return reject(d, .duplicateTarget, "Clip \(a.clipId) is targeted more than once") }
        seen.insert(key)
        switch locate(d, a) { case .failure(let f): return reject(d, f.code, f.message); case .success(let l): locations.append(l) }
    }
    let removed = Set(locations.map { moveAddressKey(.init(sequenceId: d.sequence.id, trackId: $0.track.id, clipId: $0.clip.id)) })
    var next = d
    next.sequence.tracks = d.sequence.tracks.map { t in
        var t = t
        t.clips = t.clips.filter { !removed.contains(moveAddressKey(.init(sequenceId: d.sequence.id, trackId: t.id, clipId: $0.id))) }
        return t
    }
    return try succeed(d, try parseNativeProjectDocument(next, engine: engine), engine)
}

/// Pure native move command. Clips are copied only to change `startFrame`; all media-local state is retained exactly.
/// Multi-clip commands validate first and then order destinations by frame plus durable source address, never input order.
public func applyNativeProjectClipCommand(_ d: NativeProjectDocument, _ command: NativeProjectClipCommand,
                                          engine: KeyframeEngine? = nil) throws -> NativeProjectClipCommandResult {
    let moves: [NativeProjectClipMove]
    switch command {
    case .restoreDocument(let restored):
        if restored.id != d.id { return reject(d, .documentMismatch, "An inverse can only restore its source project") }
        return try succeed(d, try cloneNativeDocument(restored, engine), engine)
    case let .trimIn(a, f): return try applyTrimIn(d, a, f, engine)
    case let .trimOut(a, f): return try applyTrimOut(d, a, f, engine)
    case let .split(a, f, b): return try applySplit(d, a, f, b, engine)
    case .delete(let a): return try applyDeleteMany(d, [a], engine)
    case .deleteMany(let list): return try applyDeleteMany(d, list, engine)
    case let .move(a, dest): moves = [.init(address: a, destination: dest)]
    case .moveMany(let list): moves = list
    }
    let located: [LocatedMove]
    switch locateMoves(d, moves) { case .failure(let f): return reject(d, f.code, f.message); case .success(let l): located = l }
    let moving = Set(located.map { moveAddressKey($0.move.address) })
    let ordered = jsStableSorted(located) { l, r in
        if l.destinationTrackIndex != r.destinationTrackIndex { return l.destinationTrackIndex < r.destinationTrackIndex ? -1 : 1 }
        if l.move.destination.startFrame != r.move.destination.startFrame { return l.move.destination.startFrame < r.move.destination.startFrame ? -1 : 1 }
        return jsLocaleCompare(moveAddressKey(l.move.address), moveAddressKey(r.move.address))
    }
    func assetKind(_ c: NativeProjectClip) -> String { d.assets.first { $0.id == c.assetId }?.kind == .audio ? "audio" : "video" }
    var next = d
    next.sequence.tracks = d.sequence.tracks.enumerated().map { trackIndex, track in
        let stationary = track.clips.enumerated().filter { !moving.contains(moveAddressKey(.init(sequenceId: d.sequence.id, trackId: track.id, clipId: $0.element.id))) }
            .map { (clip: $0.element, stableOrder: $0.offset) }
        let arrivals = ordered.filter { $0.destinationTrackIndex == trackIndex }.enumerated().map { i, m -> (clip: NativeProjectClip, stableOrder: Int) in
            var c = m.clip; c.startFrame = m.move.destination.startFrame; return (c, track.clips.count + i)
        }
        let all = stationary + arrivals
        var t = track
        if Set(all.map { assetKind($0.clip) }).contains(where: { $0 != track.kind.rawValue }) { t.kind = .mixed }
        t.clips = jsStableSorted(all) { l, r in
            l.clip.startFrame != r.clip.startFrame ? (l.clip.startFrame < r.clip.startFrame ? -1 : 1) : (l.stableOrder < r.stableOrder ? -1 : l.stableOrder > r.stableOrder ? 1 : 0)
        }.map(\.clip)
        return t
    }
    return try succeed(d, try parseNativeProjectDocument(next, engine: engine), engine)
}
