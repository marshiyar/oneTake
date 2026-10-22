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
    /// Version of the stored beat schema (encoded as `v`).
    public var version: Double = 1
    /// Sorted, unique whole source-frame positions for the supported schema.
    public var frames: [Double]
    /// Unknown data retained unchanged for forward compatibility.
    public var spread: NativeSpreadKeys = NativeSpreadKeys()

    /// Whether this editor can interpret the stored beat data.
    public var isSupported: Bool { version == 1 }


    /// Create supported beat data from validated source-frame positions.
    public init(frames: [Double]) { self.frames = frames }

    /// Decode known marks while retaining every unknown field.
    public init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<NativeAnyCodingKey> = try decoder.container(
            keyedBy: NativeAnyCodingKey.self)
        version = try container.req(Double.self, "v")
        frames = version == 1 ? try container.req([Double].self, "frames") : []
        spread = try decodeSpread(decoder, known: Self.known(version))
    }

    /// Encode the supported schema or the original unknown payload.
    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: Self.known(version)) { key, container in
            if key == "v" { try container.put(version, "v") } else { try container.put(frames, "frames") }
        }
    }

    private static func known(_ version: Double) -> [String] { version == 1 ? ["v", "frames"] : ["v"] }

}

extension NativeProjectClip {
    /// Supported marks currently visible inside the clip range.
    public var visibleBeatFrames: [(source: Double, timeline: Double)] {
        guard let beats, beats.isSupported, speedRamp?.isSupported != false else {
            return []
        }
        return beats.frames.compactMap { source in beatTimelineFrame(sourceFrame: source).map { (source, $0) } }
    }

    /// Frame in the original media, including fractional source-in and non-linear speed maps.
    public func beatSourceFrame(atTimelineFrame frame: Double) -> Double {
        let local: Double = frame - startFrame
        let displacement: Double
        if let speedRamp, speedRamp.isSupported {
            displacement = speedRamp.sourcePosition(atClipFrame: local)
        } else {
            displacement = local * (playbackRate.map { $0.numerator / $0.denominator } ?? 1)
        }
        return sourceInFrame + (sourceInFraction.map { $0.numerator / $0.denominator } ?? 0) + displacement
    }
    /// Composition frame for a visible source mark, or nil outside the clip range.
    public func beatTimelineFrame(sourceFrame: Double) -> Double? {
        let sourceIn: Double = self.sourceInFrame + (sourceInFraction.map { $0.numerator / $0.denominator } ?? 0)
        let offset: Double = sourceFrame - sourceIn
        guard offset >= 0, sourceFrame < beatSourceFrame(atTimelineFrame: startFrame + durationFrames) else {
            return nil
        }
        let local: Double
        if let speedRamp, speedRamp.isSupported {
            local = speedRamp.clipFrame(atSourcePosition: offset, durationFrames: durationFrames)
        } else {
            local = offset / (playbackRate.map { $0.numerator / $0.denominator } ?? 1)
        }
        return startFrame + local
    }

}

internal func validateNativeClipBeats(
    _ clip: NativeJSONValue, _ asset: NativeJSONValue?, _ path: String,
    _ issues: inout [NativeProjectDocumentValidationIssue]
) {
    guard let beats = clip["beats"] else {
        return
    }
    let beatPath: String = "\(path).beats"
    guard validateBeatSchema(beats, path: beatPath, issues: &issues) else {
        return
    }
    validateBeatAsset(asset, path: beatPath, issues: &issues)
    validateBeatFrames(beats["frames"], asset: asset, path: "\(beatPath).frames", issues: &issues)
}

private func validateBeatSchema(
    _ beats: NativeJSONValue, path: String,
    issues: inout [NativeProjectDocumentValidationIssue]
) -> Bool {
    guard beats.isRecord else {
        pushIssue(&issues, .invalidClip, path, "Beats must be an object")
        return false
    }
    guard isPositiveInteger(beats["v"]) else {
        pushIssue(&issues, .invalidClip, "\(path).v", "Beat version must be a positive whole number")
        return false
    }
    return beats["v"]?.numberValue == 1
}

private func validateBeatAsset(
    _ asset: NativeJSONValue?, path: String,
    issues: inout [NativeProjectDocumentValidationIssue]
) {
    if asset?["kind"]?.stringValue != "audio" {
        pushIssue(&issues, .invalidClip, path, "Beat marks belong to audio clips")
    }
}

private func validateBeatFrames(
    _ input: NativeJSONValue?, asset: NativeJSONValue?, path: String,
    issues: inout [NativeProjectDocumentValidationIssue]
) {
    guard let frames = input?.arrayValue else {
        pushIssue(&issues, .invalidClip, path, "Beat frames must be an array")
        return
    }
    var previous: Double = -1.0
    for (index, value) in frames.enumerated() {
        let framePath: String = "\(path)[\(index)]"
        guard let frame = validatedBeatFrame(value, path: framePath, issues: &issues) else {
            continue
        }
        if frame <= previous {
            pushIssue(&issues, .invalidClip, framePath, "Beat frames must be sorted and unique")
        }
        if let duration = asset?["durationFrames"]?.numberValue, frame >= duration {
            pushIssue(&issues, .sourceOutOfBounds, framePath, "Beat is past the source end")
        }
        previous = frame
    }
}

private func validatedBeatFrame(
    _ value: NativeJSONValue, path: String,
    issues: inout [NativeProjectDocumentValidationIssue]
) -> Double? {
    guard let frame = value.numberValue, frame.isFinite, frame >= 0, frame.rounded() == frame else {
        pushIssue(&issues, .invalidClip, path, "Beat must be a whole nonnegative source frame")
        return nil
    }
    return frame
}

extension NativeProjectDocument {
    /// One open notice when newer beat data is retained but cannot be displayed.
    public var unsupportedBeatsNotice: String? {
        sequence.tracks.contains { $0.clips.contains { $0.beats?.isSupported == false } }
            ? "Beat marks from a newer editor are kept in the project but not drawn." : nil
    }
}
