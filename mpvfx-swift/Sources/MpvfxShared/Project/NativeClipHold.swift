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
// A held source frame on a clip (`clip.holdSourceFrame`) and its validation.
import Foundation

/// A held source frame on a clip: the clip shows one frame of its source for its whole length, so a hold is an
/// ordinary clip (trim, move, grade, keyframes) that does not move. Version 1 (`"v": 1`) holds `frame`, a whole
/// source frame index at the project frame rate, the unit of `sourceInFrame`. A hold written with another version
/// stays in the document exactly as written (every key kept), is not drawn and is not heard; the editor says so once
/// when the project opens (`NativeProjectDocument.undrawnContentNotices`).
public struct NativeClipHold: Codable, Equatable, Hashable, Sendable {
    /// The version this editor reads and writes.
    public static let currentVersion: Double = 1

    public var v: Double
    /// The held source frame (version 1 only; nil for a hold of another version).
    public var frame: Double?
    /// Keys this version does not know, kept in input order.
    public var spread = NativeSpreadKeys()

    public init(frame: Double) { v = Self.currentVersion; self.frame = frame }

    /// The hold is one this editor can draw.
    public var isCurrentVersion: Bool { v == Self.currentVersion }
    /// The source frame shown for the clip's whole length; nil for a hold of another version.
    public var sourceFrame: Double? { isCurrentVersion ? frame : nil }

    static func known(version v: Double) -> [String] { v == currentVersion ? ["v", "frame"] : ["v"] }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        v = try c.req(Double.self, "v")
        frame = v == Self.currentVersion ? try c.opt(Double.self, "frame") : nil
        spread = try decodeSpread(decoder, known: Self.known(version: v))
    }

    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: Self.known(version: v)) { k, c in
            if k == "v" { try c.put(v, "v") } else { try c.put(frame, "frame") }
        }
    }
}

/// Every bad value of `clip.holdSourceFrame` as a typed issue; nothing is clamped. A hold of another version is only
/// checked for its version number. `asset` is the clip's asset record (nil when it is missing, reported elsewhere).
/// Returns true when the clip holds no frame, so its source range is checked as usual.
func validateNativeClipHold(_ clip: NativeJSONValue, _ asset: NativeJSONValue?, _ path: String, _ issues: inout [NativeProjectDocumentValidationIssue]) -> Bool {
    guard clip["holdSourceFrame"] != nil else { return true }
    checkNativeClipHold(clip, asset, path, &issues)
    return false
}

private func checkNativeClipHold(_ clip: NativeJSONValue, _ asset: NativeJSONValue?, _ path: String, _ issues: inout [NativeProjectDocumentValidationIssue]) {
    guard let hold = clip["holdSourceFrame"] else { return }
    let p = "\(path).holdSourceFrame"
    guard hold.isRecord else { return pushIssue(&issues, .invalidClip, p, "Hold source frame must be an object with a version v") }
    guard isPositiveInteger(hold["v"]), let v = hold["v"]?.numberValue else {
        return pushIssue(&issues, .invalidClip, "\(p).v", "Hold version v must be a positive whole number")
    }
    guard v == NativeClipHold.currentVersion else { return }
    if !isNonNegativeInteger(hold["frame"]) {
        pushIssue(&issues, .invalidClip, "\(p).frame", "Held frame must be a whole non-negative source frame")
    }
    if let asset, asset["kind"]?.stringValue != "video" {
        pushIssue(&issues, .invalidClip, p, "Only a video clip can hold a source frame")
    }
    if let rate = clip["playbackRate"], rate["numerator"]?.numberValue != rate["denominator"]?.numberValue {
        pushIssue(&issues, .invalidPlaybackRate, "\(path).playbackRate", "A held clip shows one frame, so its playback rate must be 1")
    }
    if let frame = hold["frame"]?.numberValue, isPositiveInteger(asset?["durationFrames"]),
       let length = asset?["durationFrames"]?.numberValue, frame >= length {
        pushIssue(&issues, .sourceOutOfBounds, "\(p).frame", "Held frame is past the end of its source")
    }
}

public extension NativeProjectDocument {
    /// A clip whose hold was written with a version this editor does not read: kept unchanged, left out of preview,
    /// export and the mix.
    func isUndrawnHoldClip(_ clip: NativeProjectClip) -> Bool { clip.holdSourceFrame.map { !$0.isCurrentVersion } ?? false }

    /// Every clip preview and export leave out while the document keeps it (`isUndrawnElementClip`, `isUndrawnHoldClip`).
    func isUndrawnClip(_ clip: NativeProjectClip) -> Bool { isUndrawnElementClip(clip) || isUndrawnHoldClip(clip) }

    /// The notice for held frames written by a newer version of the editor (kept, not drawn); nil when there is none.
    var unsupportedHoldNotice: String? {
        let holds = sequence.tracks.reduce(0) { n, track in n + track.clips.filter(isUndrawnHoldClip).count }
        guard holds > 0 else { return nil }
        return holds == 1
            ? "1 held frame from a newer version of the editor is kept in the project but not drawn in preview or export."
            : "\(holds) held frames from a newer version of the editor are kept in the project but not drawn in preview or export."
    }
}
