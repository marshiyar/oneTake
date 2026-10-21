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
// Hand-placed beat marks retained in the original media time.
import Foundation

/// Clip-owned source-frame marks. Unread versions retain every key and remain invisible.
public struct NativeClipBeats: Codable, Equatable, Sendable {
    public var v: Double = 1
    public var frames: [Double]?
    public var spread = NativeSpreadKeys()
    public init(frames: [Double]) { self.frames = frames }
    public var isSupported: Bool { v == 1 }
    static func known(_ v: Double) -> [String] { v == 1 ? ["v", "frames"] : ["v"] }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        v = try c.req(Double.self, "v")
        frames = v == 1 ? try c.opt([Double].self, "frames") : nil
        spread = try decodeSpread(decoder, known: Self.known(v))
    }
    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: Self.known(v)) { key, c in
            if key == "v" { try c.put(v, "v") } else { try c.put(frames, "frames") }
        }
    }
}

public extension NativeProjectClip {
    /// Frame in the original media, including fractional source-in and non-linear speed maps.
    func beatSourceFrame(atTimelineFrame frame: Double) -> Double {
        let local = frame - startFrame
        let displacement: Double
        if let speedRamp, speedRamp.isSupported { displacement = speedRamp.sourcePosition(atClipFrame: local) }
        else { displacement = local * (playbackRate.map { $0.numerator / $0.denominator } ?? 1) }
        return sourceInFrame + (sourceInFraction.map { $0.numerator / $0.denominator } ?? 0) + displacement
    }
    func beatTimelineFrame(sourceFrame: Double) -> Double? {
        let sourceIn = self.sourceInFrame + (sourceInFraction.map { $0.numerator / $0.denominator } ?? 0)
        let offset = sourceFrame - sourceIn
        guard offset >= 0, sourceFrame < beatSourceFrame(atTimelineFrame: startFrame + durationFrames) else { return nil }
        let local: Double
        if let speedRamp, speedRamp.isSupported { local = speedRamp.clipFrame(atSourcePosition: offset, durationFrames: durationFrames) }
        else { local = offset / (playbackRate.map { $0.numerator / $0.denominator } ?? 1) }
        return startFrame + local
    }
    var visibleBeatFrames: [(source: Double, timeline: Double)] {
        guard let beats, beats.isSupported, speedRamp?.isSupported != false else { return [] }
        return (beats.frames ?? []).compactMap { source in beatTimelineFrame(sourceFrame: source).map { (source, $0) } }
    }
}

func validateNativeClipBeats(_ clip: NativeJSONValue, _ asset: NativeJSONValue?, _ path: String,
                             _ issues: inout [NativeProjectDocumentValidationIssue]) {
    guard let beats = clip["beats"] else { return }
    let p = "\(path).beats"
    guard beats.isRecord else { return pushIssue(&issues, .invalidClip, p, "Beats must be an object") }
    guard isPositiveInteger(beats["v"]) else { return pushIssue(&issues, .invalidClip, "\(p).v", "Beat version must be a positive whole number") }
    guard beats["v"]?.numberValue == 1 else { return }
    if asset?["kind"]?.stringValue != "audio" { pushIssue(&issues, .invalidClip, p, "Beat marks belong to audio clips") }
    guard let frames = beats["frames"]?.arrayValue else { return pushIssue(&issues, .invalidClip, "\(p).frames", "Beat frames must be an array") }
    var previous = -1.0
    for (i, value) in frames.enumerated() {
        guard let frame = value.numberValue, frame.isFinite, frame >= 0, frame.rounded() == frame else {
            pushIssue(&issues, .invalidClip, "\(p).frames[\(i)]", "Beat must be a whole nonnegative source frame"); continue
        }
        if frame <= previous { pushIssue(&issues, .invalidClip, "\(p).frames[\(i)]", "Beat frames must be sorted and unique") }
        if let duration = asset?["durationFrames"]?.numberValue, frame >= duration {
            pushIssue(&issues, .sourceOutOfBounds, "\(p).frames[\(i)]", "Beat is past the source end")
        }
        previous = frame
    }
}

public extension NativeProjectDocument {
    var unsupportedBeatsNotice: String? {
        sequence.tracks.contains { $0.clips.contains { $0.beats?.isSupported == false } }
            ? "Beat marks from a newer editor are kept in the project but not drawn." : nil
    }
}
