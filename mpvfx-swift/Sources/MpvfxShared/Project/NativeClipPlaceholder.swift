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
// A clip marked as a placeholder for a project template (`clip.placeholder`) and its validation.
import Foundation

/// A clip marked as a placeholder: a slot in a project template that a new project fills with media. Version 1
/// (`"v": 1`) holds `index`, the placeholder's number (a whole number from 1, unique in the project), and an optional
/// `label`. A placeholder written with another version stays in the document exactly as written (every key kept), is
/// not drawn and is not exported; the editor says so once when the project opens
/// (`NativeProjectDocument.undrawnContentNotices`).
public struct NativeClipPlaceholder: Codable, Equatable, Hashable, Sendable {
    /// The version this editor reads and writes.
    public static let currentVersion: Double = 1

    public var v: Double
    /// The placeholder's number, shown on the clip and named when export refuses it (version 1 only).
    public var index: Double?
    /// What the slot is for, e.g. "Intro" (version 1 only).
    public var label: String?
    /// Keys this version does not know, kept in input order.
    public var spread = NativeSpreadKeys()

    public init(index: Int, label: String? = nil) { v = Self.currentVersion; self.index = Double(index); self.label = label }

    /// The placeholder is one this editor can draw and fill.
    public var isCurrentVersion: Bool { v == Self.currentVersion }
    /// The placeholder's number; nil for a placeholder of another version.
    public var number: Int? { isCurrentVersion ? index.flatMap { Int(exactly: $0) } : nil }

    static func known(version v: Double) -> [String] { v == currentVersion ? ["v", "index", "label"] : ["v"] }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        v = try c.req(Double.self, "v")
        index = v == Self.currentVersion ? try c.opt(Double.self, "index") : nil
        label = v == Self.currentVersion ? try c.opt(String.self, "label") : nil
        spread = try decodeSpread(decoder, known: Self.known(version: v))
    }

    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: Self.known(version: v)) { k, c in
            switch k { case "v": try c.put(v, "v"); case "index": try c.put(index, "index"); default: try c.put(label, "label") }
        }
    }
}

/// Every bad value of `clip.placeholder` as a typed issue; nothing is clamped. A placeholder of another version is only
/// checked for its version number. `numbers` collects the version 1 numbers seen so far, so two clips never share one.
func validateNativeClipPlaceholder(_ clip: NativeJSONValue, _ path: String, _ numbers: inout Set<Double>, _ issues: inout [NativeProjectDocumentValidationIssue]) {
    guard let placeholder = clip["placeholder"] else { return }
    let p = "\(path).placeholder"
    guard placeholder.isRecord else { return pushIssue(&issues, .invalidClip, p, "Placeholder must be an object with a version v") }
    guard isPositiveInteger(placeholder["v"]), let v = placeholder["v"]?.numberValue else {
        return pushIssue(&issues, .invalidClip, "\(p).v", "Placeholder version v must be a positive whole number")
    }
    guard v == NativeClipPlaceholder.currentVersion else { return }
    if isPositiveInteger(placeholder["index"]), let n = placeholder["index"]?.numberValue {
        if !numbers.insert(n).inserted {
            pushIssue(&issues, .invalidClip, "\(p).index", "Placeholder number \(Int(n)) is used by another clip")
        }
    } else {
        pushIssue(&issues, .invalidClip, "\(p).index", "Placeholder index must be a whole number from 1")
    }
    if let label = placeholder["label"], !isNonEmptyString(label) {
        pushIssue(&issues, .invalidClip, "\(p).label", "Placeholder label must be a non-empty string")
    }
}

public extension NativeProjectDocument {
    /// A clip whose placeholder was written with a version this editor does not read: kept unchanged, left out of preview
    /// and export.
    func isUndrawnPlaceholderClip(_ clip: NativeProjectClip) -> Bool { clip.placeholder.map { !$0.isCurrentVersion } ?? false }

    /// The numbers of the placeholders still waiting for media, in order. A placeholder is filled by replacing its
    /// media, which takes the marker away.
    var unfilledPlaceholderNumbers: [Int] {
        sequence.tracks.flatMap(\.clips).compactMap { $0.placeholder?.number }.sorted()
    }

    /// The notice for placeholders written by a newer version of the editor (kept, not drawn); nil when there is none.
    var unsupportedPlaceholderNotice: String? {
        let n = sequence.tracks.reduce(0) { total, track in total + track.clips.filter(isUndrawnPlaceholderClip).count }
        guard n > 0 else { return nil }
        return n == 1
            ? "1 placeholder from a newer version of the editor is kept in the project but not drawn in preview or export."
            : "\(n) placeholders from a newer version of the editor are kept in the project but not drawn in preview or export."
    }
}
