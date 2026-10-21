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
// Slip and roll: edits that move source media under clips that stay where they are.
// A slip moves one clip's source in-point; position, length and keyframes (clip-local frames) are untouched.
// A roll moves the cut between two touching clips on one track: the outgoing clip's out-point and the incoming clip's
// in-point move together, so nothing else on the timeline moves. Both reject (never clamp) a delta outside the range
// `nativeSlipRange` / `nativeRollRange` report; callers clamp to that range first.
import Foundation

/// A roll of the cut between `outgoing` (left) and `incoming` (right) by `deltaFrames` timeline frames (+ = later).
public struct NativeProjectClipRoll: Equatable {
    public var outgoing: NativeProjectClipAddress, incoming: NativeProjectClipAddress, deltaFrames: Double
    public init(outgoing: NativeProjectClipAddress, incoming: NativeProjectClipAddress, deltaFrames: Double) {
        self.outgoing = outgoing; self.incoming = incoming; self.deltaFrames = deltaFrames
    }
}

/// Timeline frames of source media a clip can still reveal before its in-point (`head`) and after its out-point
/// (`tail`), at its playback rate. Stills and text have no source timeline: both are infinite.
public struct NativeSourceRoom: Equatable {
    public var head: Double, tail: Double
}

/// The source room of a clip, or nil when its asset is missing or the source time math overflows 64 bits.
/// Overflow mapping: as in trim (`NativeProjectClipCommands.swift`), a range too large to compute exactly is treated
/// as no room at all, so the edit is refused instead of guessed.
public func nativeClipSourceRoom(_ clip: NativeProjectClip, in d: NativeProjectDocument) -> NativeSourceRoom? {
    guard let asset = d.assets.first(where: { $0.id == clip.assetId }) else { return nil }
    guard nativeAssetConsumesSourceFrames(asset.kind) else { return NativeSourceRoom(head: .infinity, tail: .infinity) }
    let position = NativeSourcePosition(sourceInFrame: clip.sourceInFrame, sourceInFraction: clip.sourceInFraction)
    do {
        let available = try availableTimelineFrames(position, playbackRate: clip.playbackRate, sourceDurationFrames: asset.durationFrames)
        guard let head = sourceHeadFrames(position, clip.playbackRate) else { return nil }
        return NativeSourceRoom(head: head, tail: available - clip.durationFrames)
    } catch { return nil }
}

/// The largest whole number of timeline frames the in-point can move back before it passes source frame 0:
/// floor(in-point / rate) = floor((S·fd + fn)·rd / (fd·rn)), in checked Int64 like `advanceSourcePosition`, which
/// accepts a move back by k frames exactly when k·rn·fd <= (S·fd + fn)·rd. Nil on overflow or a malformed rate.
private func sourceHeadFrames(_ p: NativeSourcePosition, _ rate: NativePlaybackRate?) -> Double? {
    let r = rate ?? DEFAULT_NATIVE_PLAYBACK_RATE, f = p.sourceInFraction ?? NativePlaybackRate(numerator: 0, denominator: 1)
    guard let s = Int64(exactly: p.sourceInFrame), let fn = Int64(exactly: f.numerator), let fd = Int64(exactly: f.denominator),
          let rn = Int64(exactly: r.numerator), let rd = Int64(exactly: r.denominator), s >= 0, fn >= 0, fd > 0, rn > 0, rd > 0 else { return nil }
    let (whole, o1) = s.multipliedReportingOverflow(by: fd)
    let (inPoint, o2) = whole.addingReportingOverflow(fn)
    let (numerator, o3) = inPoint.multipliedReportingOverflow(by: rd)
    let (denominator, o4) = fd.multipliedReportingOverflow(by: rn)
    if o1 || o2 || o3 || o4 { return nil }
    return Double(numerator / denominator)
}

/// The slip deltas (timeline frames) a clip accepts, or nil when it cannot slip: a still or text clip, a missing clip,
/// or a clip whose source cannot hold its length.
public func nativeSlipRange(_ d: NativeProjectDocument, _ a: NativeProjectClipAddress) -> ClosedRange<Double>? {
    guard case .success(let loc) = locate(d, a), let room = nativeClipSourceRoom(loc.clip, in: d),
          room.head.isFinite, room.tail >= -room.head else { return nil }
    return -room.head...room.tail
}

/// The roll deltas (timeline frames) a cut accepts: both clips keep at least one frame and neither runs out of source
/// media. Nil when the clips are not adjacent on one track (`outgoing` ends exactly where `incoming` starts).
public func nativeRollRange(_ d: NativeProjectDocument, outgoing: NativeProjectClipAddress,
                            incoming: NativeProjectClipAddress) -> ClosedRange<Double>? {
    guard case .success(let left) = locate(d, outgoing), case .success(let right) = locate(d, incoming),
          left.trackIndex == right.trackIndex, left.clip.id != right.clip.id,
          left.clip.startFrame + left.clip.durationFrames == right.clip.startFrame,
          let leftRoom = nativeClipSourceRoom(left.clip, in: d), let rightRoom = nativeClipSourceRoom(right.clip, in: d) else { return nil }
    let lower = max(-(left.clip.durationFrames - 1), -rightRoom.head)
    let upper = min(right.clip.durationFrames - 1, leftRoom.tail)
    return lower <= upper ? lower...upper : nil
}

private func slipRollReject(_ d: NativeProjectDocument, _ code: NativeProjectClipFailureCode, _ m: String) -> NativeProjectClipCommandResult {
    .failure(document: d, failure: .init(code: code, message: m))
}

/// Dispatch for the two commands of this file; any other command is refused rather than guessed at.
func applyNativeSlipOrRoll(_ d: NativeProjectDocument, _ command: NativeProjectClipCommand,
                           _ engine: KeyframeEngine?) throws -> NativeProjectClipCommandResult {
    switch command {
    case let .slip(a, delta): return try applyNativeSlip(d, a, delta, engine)
    case .roll(let roll): return try applyNativeRoll(d, roll, engine)
    default: return slipRollReject(d, .documentMismatch, "Not a slip or roll command")
    }
}

/// `.slip`: move the clip's source in-point by `delta` timeline frames times its playback rate.
func applyNativeSlip(_ d: NativeProjectDocument, _ a: NativeProjectClipAddress, _ delta: Double,
                     _ engine: KeyframeEngine?) throws -> NativeProjectClipCommandResult {
    let loc: ClipLocation
    switch locate(d, a) { case .failure(let f): return slipRollReject(d, f.code, f.message); case .success(let l): loc = l }
    guard isSafeInteger(delta) else { return slipRollReject(d, .invalidSlip, "A slip moves the source by a whole number of frames") }
    if let kind = d.assets.first(where: { $0.id == loc.clip.assetId })?.kind, !nativeAssetConsumesSourceFrames(kind) {
        return slipRollReject(d, .invalidSlip, "Stills and text have no source media to slip")
    }
    guard let range = nativeSlipRange(d, a), range.contains(delta) else {
        return slipRollReject(d, .invalidSlip, "Cannot slip past the start or end of the source media")
    }
    let position: NativeSourcePosition
    do {
        position = try advanceSourcePosition(.init(sourceInFrame: loc.clip.sourceInFrame, sourceInFraction: loc.clip.sourceInFraction),
                                             playbackRate: loc.clip.playbackRate, timelineFrames: delta)
    } catch { return slipRollReject(d, .invalidSlip, errorMessage(error) ?? "Invalid source boundary") }
    var next = d
    next.sequence.tracks[loc.trackIndex].clips[loc.clipIndex].sourceInFrame = position.sourceInFrame
    next.sequence.tracks[loc.trackIndex].clips[loc.clipIndex].sourceInFraction = position.sourceInFraction
    return .success(document: try parseNativeProjectDocument(next, engine: engine), inverse: .restoreDocument(try cloneNativeDocument(d, engine)))
}

/// The new cut frame of a roll, or why the roll is refused.
private func rollCut(_ d: NativeProjectDocument, _ roll: NativeProjectClipRoll) -> Result<Double, NativeProjectClipFailure> {
    guard case .success(let left) = locate(d, roll.outgoing) else { return .failure(.init(code: .missingClip, message: "Clip \(roll.outgoing.clipId) does not exist")) }
    guard case .success = locate(d, roll.incoming) else { return .failure(.init(code: .missingClip, message: "Clip \(roll.incoming.clipId) does not exist")) }
    guard isSafeInteger(roll.deltaFrames) else { return .failure(.init(code: .invalidRoll, message: "A roll moves the cut by a whole number of frames")) }
    guard let range = nativeRollRange(d, outgoing: roll.outgoing, incoming: roll.incoming) else {
        return .failure(.init(code: .invalidRoll, message: "A roll needs two clips that touch on one track"))
    }
    guard range.contains(roll.deltaFrames) else {
        return .failure(.init(code: .invalidRoll, message: "The cut cannot move past either clip's source media or shrink a clip below one frame"))
    }
    return .success(left.clip.startFrame + left.clip.durationFrames + roll.deltaFrames)
}

/// `.roll`: trim the outgoing clip's end and the incoming clip's start to the same new cut. The clip that shrinks is
/// trimmed first, so the two never overlap in between; both trims rebase keyframes the way a plain trim does.
func applyNativeRoll(_ d: NativeProjectDocument, _ roll: NativeProjectClipRoll, _ engine: KeyframeEngine?) throws -> NativeProjectClipCommandResult {
    let cut: Double
    switch rollCut(d, roll) { case .failure(let f): return slipRollReject(d, f.code, f.message); case .success(let c): cut = c }
    let shrinkIncoming = NativeProjectClipCommand.trimIn(address: roll.incoming, startFrame: cut)
    let shrinkOutgoing = NativeProjectClipCommand.trimOut(address: roll.outgoing, endFrameExclusive: cut)
    var doc = d
    for step in roll.deltaFrames > 0 ? [shrinkIncoming, shrinkOutgoing] : [shrinkOutgoing, shrinkIncoming] {
        let r = try applyNativeProjectClipCommand(doc, step, engine: engine)
        guard case .success(let next, _) = r else {
            return slipRollReject(d, .invalidRoll, r.failure?.message ?? "The roll could not trim both clips")
        }
        doc = next
    }
    return .success(document: doc, inverse: .restoreDocument(try cloneNativeDocument(d, engine)))
}
