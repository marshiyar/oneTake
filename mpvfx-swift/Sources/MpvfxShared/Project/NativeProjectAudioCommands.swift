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
// Audio commands on a native document: detach a video's sound to its own clip and reattach it. Failures throw NativeAudioCommandError.
import Foundation

public struct NativeAudioCommandError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// Exact source/timeline alignment required before sound can be folded back in.
private func sameTiming(_ l: NativeProjectClip, _ r: NativeProjectClip) -> Bool {
    // Split up: the single-expression form exceeds the type checker's time limit.
    guard l.startFrame == r.startFrame, l.durationFrames == r.durationFrames, l.sourceInFrame == r.sourceInFrame else { return false }
    let ln: Double = l.sourceInFraction?.numerator ?? 0, ld: Double = l.sourceInFraction?.denominator ?? 1
    let rn: Double = r.sourceInFraction?.numerator ?? 0, rd: Double = r.sourceInFraction?.denominator ?? 1
    guard ln * rd == rn * ld else { return false }
    let lpn: Double = l.playbackRate?.numerator ?? 1, lpd: Double = l.playbackRate?.denominator ?? 1
    let rpn: Double = r.playbackRate?.numerator ?? 1, rpd: Double = r.playbackRate?.denominator ?? 1
    return lpn * rpd == rpn * lpd
}

private func allClips(_ d: NativeProjectDocument) -> [NativeProjectClip] { d.sequence.tracks.flatMap(\.clips) }

public struct NativeDetachAudioIds: Equatable {
    public var assetId: String, clipId: String, trackId: String
    public init(assetId: String, clipId: String, trackId: String) { self.assetId = assetId; self.clipId = clipId; self.trackId = trackId }
}

/// crypto.randomUUID() is lowercase; Foundation's uuidString is uppercase, so it is lowercased to match.
public func createNativeDetachAudioIds() -> NativeDetachAudioIds {
    func uuid() -> String { UUID().uuidString.lowercased() }
    return .init(assetId: "detached-audio-asset:\(uuid())", clipId: "detached-audio-clip:\(uuid())", trackId: "detached-audio-track:\(uuid())")
}

private func fail(_ m: String) -> NativeAudioCommandError { .init(message: m) }

/// Create a linked audio clip from a video without touching its picture edits.
public func detachNativeVideoAudio(_ source: NativeProjectDocument, videoClipId: String, hasAudioStream: Bool,
                                   ids: NativeDetachAudioIds = createNativeDetachAudioIds(), engine: KeyframeEngine? = nil) throws -> NativeProjectDocument {
    if !hasAudioStream { throw fail("This video has no audio stream to detach") }
    var d = try parseNativeProjectDocument(source, engine: engine)
    guard let (ti, ci) = d.sequence.tracks.enumerated().lazy.compactMap({ t in t.element.clips.firstIndex { $0.id == videoClipId }.map { (t.offset, $0) } }).first
    else { throw fail("Video clip \(videoClipId) was not found") }
    let video = d.sequence.tracks[ti].clips[ci]
    guard let asset = d.assets.first(where: { $0.id == video.assetId }), asset.kind == .video, let assetSource = asset.source, !assetSource.isEmpty else {
        throw fail("Only a video file can have its audio detached")
    }
    if allClips(d).contains(where: { $0.audioDetachedFrom == videoClipId }) { throw fail("This video's audio is already detached") }
    if d.assets.contains(where: { $0.id == ids.assetId }) || d.sequence.tracks.contains(where: { $0.id == ids.trackId }) ||
        allClips(d).contains(where: { $0.id == ids.clipId }) {
        throw fail("Detached audio IDs already exist in this project")
    }
    var audioClip = NativeProjectClip(id: ids.clipId, assetId: ids.assetId,
        audioGroupId: video.audioGroupId?.nilIfEmpty, audioFxChain: video.audioFxChain?.nilIfEmpty, audioAutomation: video.audioAutomation?.nilIfEmpty,
        audioDetachedFrom: video.id, binding: nil, startFrame: video.startFrame, durationFrames: video.durationFrames,
        sourceInFrame: video.sourceInFrame, sourceInFraction: video.sourceInFraction, playbackRate: video.playbackRate, muted: video.muted,
        staticParameters: (video.staticParameters ?? [:]).filter { $0.key.hasPrefix("audio.") }, cropPivotSegments: nil, effects: [],
        parameterTracks: video.parameterTracks.filter { $0.parameterId.hasPrefix("audio.") })
    audioClip.preservesPitch = video.preservesPitch
    var v = video
    v.muted = true; v.audioGroupId = nil; v.audioFxChain = nil; v.audioAutomation = nil
    v.parameterTracks = video.parameterTracks.filter { !$0.parameterId.hasPrefix("audio.") }
    d.sequence.tracks[ti].clips[ci] = v
    d.assets.append(.init(id: ids.assetId, kind: .audio, name: "\(asset.name) audio", source: assetSource, durationFrames: asset.durationFrames))
    let nextDisplay = max(-1, d.sequence.tracks.enumerated().map { $0.element.lane?.displayTrack ?? Double($0.offset) }.max() ?? -1) + 1
    let nextAuthored = max(-1, d.sequence.tracks.filter { $0.kind == .audio }.enumerated()
        .map { $0.element.lane?.authoredTrack ?? Double($0.offset) }.max() ?? -1) + 1
    d.sequence.tracks.append(.init(id: ids.trackId, kind: .audio, lane: .init(authoredTrack: nextAuthored, displayTrack: nextDisplay), clips: [audioClip]))
    return try parseNativeProjectDocument(d, engine: engine)
}

/// Reattach only while the two clips still describe the same source interval. Gain, mute and group membership transfer.
public func reattachNativeVideoAudio(_ source: NativeProjectDocument, audioClipId: String, engine: KeyframeEngine? = nil) throws -> NativeProjectDocument {
    var d = try parseNativeProjectDocument(source, engine: engine)
    let audioTrackIndex = d.sequence.tracks.firstIndex { $0.clips.contains { $0.id == audioClipId } }
    let audio = audioTrackIndex.flatMap { i in d.sequence.tracks[i].clips.first { $0.id == audioClipId } }
    guard let audio, let linked = audio.audioDetachedFrom, !linked.isEmpty, let audioTrackIndex else {
        throw fail("This clip is not linked to detached video audio")
    }
    let videoLoc = d.sequence.tracks.enumerated().lazy.compactMap { t in t.element.clips.firstIndex { $0.id == linked }.map { (t.offset, $0) } }.first
    let video = videoLoc.map { d.sequence.tracks[$0.0].clips[$0.1] }
    let audioAsset = d.assets.first { $0.id == audio.assetId }
    let videoAsset = video.flatMap { v in d.assets.first { $0.id == v.assetId } }
    guard let video, let (vt, vc) = videoLoc, videoAsset?.kind == .video, audioAsset?.kind == .audio,
          let vs = videoAsset?.source, !vs.isEmpty, audioAsset?.source == vs else {
        throw fail("The detached audio's source video is no longer available")
    }
    if allClips(d).filter({ $0.audioDetachedFrom == video.id }).count != 1 {
        throw fail("More than one audio clip links to this video; reattach is ambiguous")
    }
    if !sameTiming(video, audio) { throw fail("The detached audio or video was moved, trimmed, or retimed; align them before reattaching") }
    if (audio.staticParameters ?? [:]).keys.contains(where: { !$0.hasPrefix("audio.") }) {
        throw fail("The detached audio has edits that cannot be transferred safely to the video")
    }
    let videoEffectIds = Set(video.effects.map(\.id)), videoParameterIds = Set(video.parameterTracks.map(\.parameterId))
    if audio.effects.contains(where: { videoEffectIds.contains($0.id) }) || audio.parameterTracks.contains(where: { videoParameterIds.contains($0.parameterId) }) {
        throw fail("The detached audio has an effect or automation identity that conflicts with the video")
    }
    var v = video
    v.muted = audio.muted
    v.staticParameters = (video.staticParameters ?? [:]).merging(audio.staticParameters ?? [:]) { _, new in new }
    v.effects += audio.effects
    v.parameterTracks += audio.parameterTracks
    v.audioGroupId = audio.audioGroupId?.nilIfEmpty
    v.audioFxChain = audio.audioFxChain?.nilIfEmpty
    v.audioAutomation = audio.audioAutomation?.nilIfEmpty
    v.preservesPitch = audio.preservesPitch
    d.sequence.tracks[vt].clips[vc] = v
    d.sequence.tracks[audioTrackIndex].clips.removeAll { $0.id == audio.id }
    if d.sequence.tracks[audioTrackIndex].clips.isEmpty { d.sequence.tracks.remove(at: audioTrackIndex) }
    if !allClips(d).contains(where: { $0.assetId == audio.assetId }) { d.assets.removeAll { $0.id == audio.assetId } }
    return try parseNativeProjectDocument(d, engine: engine)
}

extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
