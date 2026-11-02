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
// Beat marks retained in the original media time: hand-placed ones, and the ones a beat analysis found.
import Foundation

/// The marks a beat analysis wrote (`beats.analysis`): re-running the analysis replaces these and leaves `frames` alone.
public struct NativeBeatAnalysis: Codable, Equatable, Sendable {
    /// The choices an analysis offers for keeping only every Nth beat.
    public static let everyChoices: [Double] = [1, 2, 4]
    /// Sorted, unique whole source-frame positions the analysis found.
    public var frames: [Double]
    /// Onset strength of each frame, 0...1, in the same order; empty when not recorded.
    public var strengths: [Double]
    /// How readily onsets became beats, 0...1 (higher finds more).
    public var sensitivity: Double
    /// Every Nth beat of the track was kept: 1, 2 or 4.
    public var every: Double

    public init(frames: [Double], strengths: [Double] = [], sensitivity: Double = 0.5, every: Double = 1) {
        self.frames = frames; self.strengths = strengths; self.sensitivity = sensitivity; self.every = every
    }

    private enum CodingKeys: String, CodingKey { case frames, strengths, sensitivity, every }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frames = try c.decode([Double].self, forKey: .frames)
        strengths = try c.decodeIfPresent([Double].self, forKey: .strengths) ?? []
        sensitivity = try c.decode(Double.self, forKey: .sensitivity)
        every = try c.decode(Double.self, forKey: .every)
    }

    /// Strengths are left out when none were recorded.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(frames, forKey: .frames)
        if !strengths.isEmpty { try c.encode(strengths, forKey: .strengths) }
        try c.encode(sensitivity, forKey: .sensitivity)
        try c.encode(every, forKey: .every)
    }
}

/// Clip-owned source-frame marks. Unread versions retain every key and remain invisible.
public struct NativeClipBeats: Codable, Equatable, Sendable {
    /// Version of the stored beat schema (encoded as `v`).
    public var version: Double = 1
    /// Sorted, unique whole source-frame positions of the hand-placed marks for the supported schema.
    public var frames: [Double]
    /// The marks found by analysis, kept apart from the hand-placed ones; nil when no analysis has run.
    public var analysis: NativeBeatAnalysis?
    /// Unknown data retained unchanged for forward compatibility.
    public var spread: NativeSpreadKeys = NativeSpreadKeys()

    /// Whether this editor can interpret the stored beat data.
    public var isSupported: Bool { version == 1 }


    /// Create supported beat data from validated source-frame positions.
    public init(frames: [Double], analysis: NativeBeatAnalysis? = nil) { self.frames = frames; self.analysis = analysis }

    /// Hand-placed and analysed marks together, sorted and unique: what the timeline draws and snaps to.
    public var allFrames: [Double] {
        guard let analysis, !analysis.frames.isEmpty else { return frames }
        return Array(Set(frames).union(analysis.frames)).sorted()
    }

    /// Decode known marks while retaining every unknown field.
    public init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<NativeAnyCodingKey> = try decoder.container(
            keyedBy: NativeAnyCodingKey.self)
        version = try container.req(Double.self, "v")
        frames = version == 1 ? try container.req([Double].self, "frames") : []
        analysis = version == 1 ? try container.opt(NativeBeatAnalysis.self, "analysis") : nil
        spread = try decodeSpread(decoder, known: Self.known(version))
    }

    /// Encode the supported schema or the original unknown payload.
    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: Self.known(version)) { key, container in
            switch key {
            case "v": try container.put(version, "v")
            case "analysis": try container.put(analysis, "analysis")
            default: try container.put(frames, "frames")
            }
        }
    }

    private static func known(_ version: Double) -> [String] { version == 1 ? ["v", "frames", "analysis"] : ["v"] }

}

extension NativeProjectClip {
    /// Supported marks currently visible inside the clip range.
    public var visibleBeatFrames: [(source: Double, timeline: Double)] {
        guard let beats, beats.isSupported, speedRamp?.isSupported != false else {
            return []
        }
        return beats.allFrames.compactMap { source in beatTimelineFrame(sourceFrame: source).map { (source, $0) } }
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
    if let analysis = beats["analysis"] {
        validateBeatAnalysis(analysis, asset: asset, path: "\(beatPath).analysis", issues: &issues)
    }
}

/// The analysed marks follow the hand-placed rules (sorted, unique, whole source frames inside the media); each strength
/// is 0...1 and there is one per mark when any are stored; the settings are in range.
private func validateBeatAnalysis(
    _ analysis: NativeJSONValue, asset: NativeJSONValue?, path: String,
    issues: inout [NativeProjectDocumentValidationIssue]
) {
    guard analysis.isRecord else {
        pushIssue(&issues, .invalidClip, path, "Beat analysis must be an object")
        return
    }
    validateBeatFrames(analysis["frames"], asset: asset, path: "\(path).frames", issues: &issues)
    if let strengths = analysis["strengths"] {
        if let list = strengths.arrayValue {
            if list.count != (analysis["frames"]?.arrayValue?.count ?? 0) {
                pushIssue(&issues, .invalidClip, "\(path).strengths", "There must be one strength for each analysed beat")
            }
            for (index, value) in list.enumerated() where !(value.numberValue.map { $0.isFinite && $0 >= 0 && $0 <= 1 } ?? false) {
                pushIssue(&issues, .invalidClip, "\(path).strengths[\(index)]", "Beat strength must be a number from 0 to 1")
            }
        } else {
            pushIssue(&issues, .invalidClip, "\(path).strengths", "Beat strengths must be an array")
        }
    }
    if !(analysis["sensitivity"]?.numberValue.map { $0.isFinite && $0 >= 0 && $0 <= 1 } ?? false) {
        pushIssue(&issues, .invalidClip, "\(path).sensitivity", "Sensitivity must be a number from 0 to 1")
    }
    if !(analysis["every"]?.numberValue.map { NativeBeatAnalysis.everyChoices.contains($0) } ?? false) {
        pushIssue(&issues, .invalidClip, "\(path).every", "Keep every 1st, 2nd or 4th beat")
    }
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
