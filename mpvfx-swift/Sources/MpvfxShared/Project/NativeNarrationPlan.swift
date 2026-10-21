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
// Narration plans (pure): place a WAV spoken from text as a new audio clip, or swap a narration clip's WAV after it
// was spoken again. A plan never ripples or trims a neighbour: a clip that would run into the next clip on its track
// is refused with that clip's name. The caller commits `document` as one undo step; the WAV a re-speak replaced stays
// in the project folder until the unused-media rules remove it.
import Foundation

/// A WAV already published into the project folder.
public struct NativeNarrationAudio: Equatable, Sendable {
    /// The new asset's id.
    public var assetId: String
    /// Project-relative path of the WAV.
    public var source: String
    public var name: String
    /// Length in sample frames at 48 kHz (the WAV's own count, never seconds).
    public var samples48k: Int
    public init(assetId: String, source: String, name: String, samples48k: Int) {
        self.assetId = assetId; self.source = source; self.name = name; self.samples48k = samples48k
    }
}

/// What a narration edit puts in the document: the spoken audio and the record it was spoken from.
public struct NativeNarrationEdit: Equatable, Sendable {
    public var audio: NativeNarrationAudio
    public var narration: NativeClipNarration
    public init(audio: NativeNarrationAudio, narration: NativeClipNarration) { self.audio = audio; self.narration = narration }
}

/// Where a new narration clip goes.
public struct NativeNarrationPlacement: Equatable, Sendable {
    public var trackId: String
    public var startFrame: Int
    public var clipId: String
    public init(trackId: String, startFrame: Int, clipId: String) { self.trackId = trackId; self.startFrame = startFrame; self.clipId = clipId }
}

public enum NativeNarrationPlanFailure: Error, Equatable, CustomStringConvertible {
    case clipNotFound(clipId: String)
    case notNarration(clipId: String)
    /// The record comes from a later version of the editor: the clip plays, but cannot be spoken again here.
    case unreadNarration(clipId: String)
    case trackNotFound(trackId: String)
    case trackNotAudio(trackId: String)
    case trackLocked(trackId: String)
    case invalidStart(frame: Int)
    /// The spoken audio is shorter than one project frame.
    case audioTooShort(samples48k: Int)
    /// The clip would run into `clipId` (named `name`) on its track.
    case overlapsClip(clipId: String, name: String)
    case documentRejected(message: String)

    public var description: String {
        switch self {
        case .clipNotFound(let id): return "Clip \(id) is not in the project"
        case .notNarration(let id): return "Clip \(id) was not made from text"
        case .unreadNarration: return "This narration comes from a newer version of the editor and cannot be spoken again here"
        case .trackNotFound(let id): return "Track \(id) is not in the project"
        case .trackNotAudio(let id): return "Track \(id) cannot hold audio clips"
        case .trackLocked(let id): return "Track \(id) is locked"
        case .invalidStart(let frame): return "Narration cannot start at frame \(frame)"
        case .audioTooShort: return "The spoken audio is shorter than one frame"
        case .overlapsClip(_, let name): return "The narration would overlap \"\(name)\" on its track"
        case .documentRejected(let message): return message
        }
    }
}

public struct NativeNarrationPlan: Equatable, Sendable {
    public var document: NativeProjectDocument
    public var clipId: String
    public var durationFrames: Int
}

public typealias NativeNarrationPlanResult = Result<NativeNarrationPlan, NativeNarrationPlanFailure>

/// Whole project frames inside `samples` at 48 kHz, rounded down so the clip never runs past the end of its WAV
/// (the import rounds an asset's length the same way). Integer arithmetic on the two rationals; nil when the frame
/// rate is not a positive whole rational or the product overflows.
public func nativeNarrationFrames(samples48k samples: Int, frameRate: RationalFrameRate) -> Int? {
    guard samples >= 0, let num = Int(exactly: frameRate.numerator), let den = Int(exactly: frameRate.denominator), num > 0, den > 0 else { return nil }
    let (product, overflow) = samples.multipliedReportingOverflow(by: num)
    let (divisor, overflow2) = 48_000.multipliedReportingOverflow(by: den)
    guard !overflow, !overflow2 else { return nil }
    return product / divisor
}

/// A new audio clip of `edit.audio` (a new asset) at `placement`, carrying `edit.narration`.
public func planNativeNarrationInsert(_ document: NativeProjectDocument, _ edit: NativeNarrationEdit,
                                      at placement: NativeNarrationPlacement, engine: KeyframeEngine?) -> NativeNarrationPlanResult {
    guard placement.startFrame >= 0 else { return .failure(.invalidStart(frame: placement.startFrame)) }
    guard let t = document.sequence.tracks.firstIndex(where: { $0.id == placement.trackId }) else {
        return .failure(.trackNotFound(trackId: placement.trackId))
    }
    let track = document.sequence.tracks[t]
    guard track.kind != .video else { return .failure(.trackNotAudio(trackId: track.id)) }
    guard track.locked != true else { return .failure(.trackLocked(trackId: track.id)) }
    let frames: Int
    switch narrationLength(edit.audio, document) { case .failure(let f): return .failure(f); case .success(let n): frames = n }
    if let blocking = firstOverlap(document, track, start: placement.startFrame, frames: frames, ignoring: nil) {
        return .failure(blocking)
    }
    var doc = document
    doc.assets.append(NativeProjectAsset(id: edit.audio.assetId, kind: .audio, name: edit.audio.name, source: edit.audio.source,
                                         durationFrames: Double(frames)))
    var clip = NativeProjectClip.fresh(id: placement.clipId, assetId: edit.audio.assetId, startFrame: Double(placement.startFrame),
                                       durationFrames: Double(frames))
    clip.narration = .current(edit.narration)
    doc.sequence.tracks[t].clips.append(clip)
    return validated(doc, clipId: clip.id, frames: frames, engine: engine)
}

/// The narration clip `clipId` playing `edit.audio` (a new asset) from its start: start, track, volume, effects,
/// automation, keyframes and bus stay; asset, length and record change. Fades are cut to the new length as a trim of
/// the clip end cuts them.
public func planNativeNarrationRespeak(_ document: NativeProjectDocument, clipId: String, _ edit: NativeNarrationEdit,
                                       engine: KeyframeEngine?) -> NativeNarrationPlanResult {
    guard let (t, c) = locateClip(document, clipId) else { return .failure(.clipNotFound(clipId: clipId)) }
    let track = document.sequence.tracks[t]
    let old = track.clips[c]
    switch old.narration {
    case nil: return .failure(.notNarration(clipId: clipId))
    case .unread?: return .failure(.unreadNarration(clipId: clipId))
    case .current?: break
    }
    guard track.locked != true else { return .failure(.trackLocked(trackId: track.id)) }
    let frames: Int
    switch narrationLength(edit.audio, document) { case .failure(let f): return .failure(f); case .success(let n): frames = n }
    if let blocking = firstOverlap(document, track, start: Int(old.startFrame), frames: frames, ignoring: clipId) {
        return .failure(blocking)
    }
    var doc = document
    doc.assets.append(NativeProjectAsset(id: edit.audio.assetId, kind: .audio, name: edit.audio.name, source: edit.audio.source,
                                         durationFrames: Double(frames)))
    var clip = old
    clip.assetId = edit.audio.assetId
    clip.durationFrames = Double(frames)
    clip.sourceInFrame = 0
    clip.sourceInFraction = nil
    clip.narration = .current(edit.narration)
    clip.clampFades(movedEdge: .end)
    doc.sequence.tracks[t].clips[c] = clip
    return validated(doc, clipId: clipId, frames: frames, engine: engine)
}

private func narrationLength(_ audio: NativeNarrationAudio, _ document: NativeProjectDocument) -> Result<Int, NativeNarrationPlanFailure> {
    guard let frames = nativeNarrationFrames(samples48k: audio.samples48k, frameRate: document.frameRate) else {
        return .failure(.documentRejected(message: "The project frame rate cannot place narration"))
    }
    return frames >= 1 ? .success(frames) : .failure(.audioTooShort(samples48k: audio.samples48k))
}

private func locateClip(_ document: NativeProjectDocument, _ clipId: String) -> (Int, Int)? {
    for (t, track) in document.sequence.tracks.enumerated() {
        if let c = track.clips.firstIndex(where: { $0.id == clipId }) { return (t, c) }
    }
    return nil
}

/// The first clip on `track` (other than `ignoring`) that the span `start ..< start + frames` would cover, by start.
private func firstOverlap(_ document: NativeProjectDocument, _ track: NativeProjectTrack, start: Int, frames: Int,
                          ignoring: String?) -> NativeNarrationPlanFailure? {
    let end = Double(start + frames)
    let hit = track.clips
        .filter { $0.id != ignoring && $0.startFrame < end && $0.startFrame + $0.durationFrames > Double(start) }
        .min { $0.startFrame < $1.startFrame }
    guard let hit else { return nil }
    let name = document.assets.first(where: { $0.id == hit.assetId })?.name ?? hit.id
    return .overlapsClip(clipId: hit.id, name: name)
}

private func validated(_ doc: NativeProjectDocument, clipId: String, frames: Int, engine: KeyframeEngine?) -> NativeNarrationPlanResult {
    do {
        let parsed = try parseNativeProjectDocument(doc, engine: engine)
        return .success(NativeNarrationPlan(document: parsed, clipId: clipId, durationFrames: frames))
    } catch let e as NativeProjectDocumentValidationError {
        return .failure(.documentRejected(message: e.message))
    } catch {
        return .failure(.documentRejected(message: "\(error)"))
    }
}
