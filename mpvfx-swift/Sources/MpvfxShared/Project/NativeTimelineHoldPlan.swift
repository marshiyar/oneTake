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
// Hold plans: the frame of a clip under the playhead held for a length, inserted (the rest of the track moves later)
// or overwriting what follows on the track.
import Foundation

/// Insert pushes the rest of the clip and every later clip on its track later; overwrite keeps the sequence length.
public enum NativeTimelineHoldMode: String, Sendable { case insert, overwrite }

public struct NativeTimelineHoldRequest: Equatable, Sendable {
    public var address: NativeProjectClipAddress
    /// The timeline frame under the playhead; the clip's frame shown there is the one held.
    public var frame: Double
    public var lengthFrames: Double
    public var mode: NativeTimelineHoldMode
    public init(address: NativeProjectClipAddress, frame: Double, lengthFrames: Double, mode: NativeTimelineHoldMode) {
        self.address = address; self.frame = frame; self.lengthFrames = lengthFrames; self.mode = mode
    }
}

public enum NativeTimelineHoldFailureCode: String, Sendable {
    case clipNotFound = "clip-not-found", lockedTrack = "locked-track", notAVideoClip = "not-a-video-clip"
    case alreadyHeld = "already-held", outsideClip = "playhead-outside-clip", invalidLength = "invalid-hold-length"
    case nativeCommandRejected = "native-command-rejected"
}

public struct NativeTimelineHoldFailure: Error, Equatable {
    public var code: NativeTimelineHoldFailureCode; public var message: String
    public init(code: NativeTimelineHoldFailureCode, message: String) { self.code = code; self.message = message }
}

public struct NativeTimelineHoldPlan: Equatable {
    public var document: NativeProjectDocument
    /// The new hold clip (the held frame's piece of the original clip).
    public var holdClipId: String
}

public typealias NativeTimelineHoldPlanResult = Result<NativeTimelineHoldPlan, NativeTimelineHoldFailure>

/// Plans a hold against one snapshot. The clip is cut at the playhead (not at its first frame); the frame under the
/// playhead becomes a clip of `lengthFrames` that shows that source frame (`holdSourceFrame`) and keeps the clip's
/// grade, crop, transform, style and effects. Insert: the rest of the clip starts at the hold's end with the next
/// source frame, and every later clip on the track moves later with it. Overwrite: the hold covers the frames after
/// the playhead, the rest of the clip keeps its timing after the hold, and other clips under the hold on the track
/// are trimmed or removed. Rejections are values; only a non-validation engine error throws.
public func planNativeTimelineHold(_ document: NativeProjectDocument, _ request: NativeTimelineHoldRequest,
                                   engine: KeyframeEngine?) throws -> NativeTimelineHoldPlanResult {
    if let failure = holdRequestFailure(document, request) { return .failure(failure) }
    var edit = HoldEdit(document: document, request: request, engine: engine, holdId: request.address.clipId)
    do {
        try edit.cutAtPlayhead()
        if request.mode == .insert { try edit.isolateHeldFrameAndRipple() } else { try edit.clearOverwrittenSpan() }
        return .success(try edit.finish())
    } catch let failure as NativeTimelineHoldFailure {
        return .failure(failure)
    } catch let invalid as NativeProjectDocumentValidationError {
        return .failure(.init(code: .nativeCommandRejected, message: invalid.message))
    }
}

private func holdRequestFailure(_ d: NativeProjectDocument, _ r: NativeTimelineHoldRequest) -> NativeTimelineHoldFailure? {
    guard let track = d.sequence.tracks.first(where: { $0.id == r.address.trackId }),
          let clip = track.clips.first(where: { $0.id == r.address.clipId }) else {
        return .init(code: .clipNotFound, message: "Clip \(r.address.clipId) is not on track \(r.address.trackId)")
    }
    if track.locked == true { return .init(code: .lockedTrack, message: "Track is locked") }
    if !isSafeInteger(r.lengthFrames) || r.lengthFrames < 1 {
        return .init(code: .invalidLength, message: "A hold lasts a whole number of frames, at least one")
    }
    if !isSafeInteger(r.frame) || r.frame < clip.startFrame || r.frame >= clip.startFrame + clip.durationFrames {
        return .init(code: .outsideClip, message: "Move the playhead onto the clip to hold its frame")
    }
    if clip.holdSourceFrame != nil { return .init(code: .alreadyHeld, message: "This clip already holds one frame") }
    if d.assets.first(where: { $0.id == clip.assetId })?.kind != .video {
        return .init(code: .notAVideoClip, message: "Only a frame of a video clip can be held")
    }
    return nil
}

/// The hold as a run of clip commands on one track, then the held piece rewritten.
private struct HoldEdit {
    var document: NativeProjectDocument
    let request: NativeTimelineHoldRequest
    let engine: KeyframeEngine?
    /// The piece of the clip that starts at the playhead and becomes the hold.
    var holdId: String

    var trackId: String { request.address.trackId }
    var frame: Double { request.frame }
    var length: Double { request.lengthFrames }
    var track: NativeProjectTrack? { document.sequence.tracks.first { $0.id == trackId } }

    func address(_ id: String) -> NativeProjectClipAddress { .init(sequenceId: document.sequence.id, trackId: trackId, clipId: id) }
    func clip(_ id: String) -> NativeProjectClip? { track?.clips.first { $0.id == id } }

    mutating func run(_ command: NativeProjectClipCommand) throws {
        switch try applyNativeProjectClipCommand(document, command, engine: engine) {
        case .success(let next, _): document = next
        case .failure(_, let f): throw NativeTimelineHoldFailure(code: .nativeCommandRejected, message: f.message)
        }
    }

    /// At the clip's first frame nothing is cut: the hold goes before the rest of the clip.
    mutating func cutAtPlayhead() throws {
        guard let c = clip(holdId), frame > c.startFrame else { return }
        try run(.split(address: address(holdId), splitFrame: frame))
        holdId = nativeSplitClipId(holdId, splitFrame: frame)
    }

    /// Insert: the frame under the playhead alone becomes the hold; everything after it on the track moves later by
    /// the frames the hold adds. At the clip's last frame nothing follows on the clip.
    mutating func isolateHeldFrameAndRipple() throws {
        guard let c = clip(holdId) else { return }
        if c.durationFrames > 1 { try run(.split(address: address(holdId), splitFrame: frame + 1)) }
        try shift(clipsFrom: frame + 1, by: length - 1)
    }

    mutating func shift(clipsFrom start: Double, by delta: Double) throws {
        guard delta != 0, let track else { return }
        let moves = track.clips.filter { $0.startFrame >= start }.map { c in
            NativeProjectClipMove(address: address(c.id), destination: .init(trackId: trackId, startFrame: c.startFrame + delta))
        }
        guard let first = moves.first else { return }
        try run(moves.count == 1 ? .move(address: first.address, destination: first.destination) : .moveMany(moves))
    }

    /// Overwrite: the hold covers [frame, frame + length) on its track. The clip past the hold keeps its timing;
    /// other clips under the hold are trimmed to its end or removed.
    mutating func clearOverwrittenSpan() throws {
        let end = frame + length
        if let c = clip(holdId), c.startFrame + c.durationFrames > end { try run(.split(address: address(holdId), splitFrame: end)) }
        if let c = clip(holdId), c.durationFrames > 1 { try run(.trimOut(address: address(holdId), endFrameExclusive: frame + 1)) }
        guard let track else { return }
        let under = track.clips.filter { $0.id != holdId && $0.startFrame < end && $0.startFrame + $0.durationFrames > frame }
        for c in under where c.startFrame + c.durationFrames > end { try run(.trimIn(address: address(c.id), startFrame: end)) }
        let covered = under.filter { $0.startFrame + $0.durationFrames <= end }.map { address($0.id) }
        guard let first = covered.first else { return }
        try run(covered.count == 1 ? .delete(address: first) : .deleteMany(covered))
    }

    /// The held piece shows its first source frame for `length` frames at speed 1.
    func finish() throws -> NativeTimelineHoldPlan {
        var next = document
        guard let t = next.sequence.tracks.firstIndex(where: { $0.id == trackId }),
              let i = next.sequence.tracks[t].clips.firstIndex(where: { $0.id == holdId }) else {
            throw NativeTimelineHoldFailure(code: .clipNotFound, message: "The held piece of clip \(request.address.clipId) is missing")
        }
        var hold = next.sequence.tracks[t].clips[i]
        hold.holdSourceFrame = NativeClipHold(frame: hold.sourceInFrame)
        hold.durationFrames = length
        hold.playbackRate = nil
        hold.sourceInFraction = nil
        next.sequence.tracks[t].clips[i] = hold
        return NativeTimelineHoldPlan(document: try parseNativeProjectDocument(next, engine: engine), holdClipId: holdId)
    }
}
