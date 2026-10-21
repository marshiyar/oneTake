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
// Cut transitions on a track (`track.transitions`): a dissolve, or a dip through a colour, softening the cut
// between two adjacent clips. A transition belongs to the cut, not to either clip: clip start and duration never
// change because of one, and the overlap it draws is taken from the media beyond each clip's in and out points
// (its handles). Each entry is kept as the JSON object it was read from, so an entry from a newer version of the
// editor (an unknown `v` or `kind`) is saved back unchanged and drawn as a hard cut.
import Foundation

/// The transition kinds this version of the editor draws.
public enum NativeCutTransitionKind: String, CaseIterable, Sendable {
    /// The incoming clip fades up over the outgoing one, which stays at full opacity under it.
    case dissolve
    /// The outgoing clip fades to a colour up to the cut, and the incoming clip fades up from it.
    case dip
}

/// Where the transition's range sits relative to the cut.
public enum NativeCutTransitionAlignment: String, CaseIterable, Sendable {
    /// Half before the cut, half after (the default); an odd length puts the extra frame after the cut.
    case centre
    /// The whole range is before the cut.
    case endsAtCut
    /// The whole range is after the cut.
    case startsAtCut
}

/// One `track.transitions` entry: `{ "v": 1, "id", "fromClipId", "toClipId", "kind", "durationFrames",
/// "alignment", "color"? }`.
public struct NativeCutTransition: Codable, Equatable, Sendable {
    /// The only entry version this editor draws.
    public static let version = 1
    /// The dip colour when `color` is absent.
    public static let defaultDipColor = "#000000"

    /// The entry as stored, unknown keys included.
    public var object: NativeJSONObject

    public init(object: NativeJSONObject) { self.object = object }

    /// A new centred entry on the cut from `cut.from` to `cut.to`; set `alignment` and `color` after.
    public init(id: String, cut: (from: String, to: String), kind: NativeCutTransitionKind, durationFrames: Double) {
        var o = NativeJSONObject()
        o["v"] = .number(Double(Self.version)); o["id"] = .string(id)
        o["fromClipId"] = .string(cut.from); o["toClipId"] = .string(cut.to)
        o["kind"] = .string(kind.rawValue); o["durationFrames"] = .number(durationFrames)
        o["alignment"] = .string(NativeCutTransitionAlignment.centre.rawValue)
        object = o
    }

    public init(from decoder: Decoder) throws { object = try NativeJSONObject(from: decoder) }
    public func encode(to encoder: Encoder) throws { try object.encode(to: encoder) }

    public var id: String? { object["id"]?.stringValue }
    public var fromClipId: String? { object["fromClipId"]?.stringValue }
    public var toClipId: String? { object["toClipId"]?.stringValue }
    public var durationFrames: Double? {
        get { object["durationFrames"]?.numberValue }
        set { object["durationFrames"] = newValue.map { .number($0) } }
    }
    /// The kind, when this editor knows it.
    public var kind: NativeCutTransitionKind? {
        get { object["kind"]?.stringValue.flatMap(NativeCutTransitionKind.init(rawValue:)) }
        set { object["kind"] = newValue.map { .string($0.rawValue) } }
    }
    /// The alignment; absent reads as centred.
    public var alignment: NativeCutTransitionAlignment? {
        get { object["alignment"] == nil ? .centre : object["alignment"]?.stringValue.flatMap(NativeCutTransitionAlignment.init(rawValue:)) }
        set { object["alignment"] = newValue.map { .string($0.rawValue) } }
    }
    public var color: String? {
        get { object["color"]?.stringValue }
        set { object["color"] = newValue.map { .string($0) } }
    }

    /// Written by this version of the editor (`v` 1, a known kind): validated, drawn and edited. Any other entry is
    /// kept as it is and drawn as a hard cut.
    public var isKnown: Bool { object["v"] == .number(Double(Self.version)) && kind != nil }
}

public extension NativeProjectTrack {
    /// The track's transitions (none when absent).
    var cutTransitions: [NativeCutTransition] { transitions ?? [] }
}

public extension NativeProjectDocument {
    /// Transitions kept in the document but drawn as hard cuts: entries from a newer version of the editor.
    var unknownTransitionCount: Int {
        sequence.tracks.reduce(0) { n, track in n + track.cutTransitions.filter { !$0.isKnown }.count }
    }

    /// The one notice shown on open when the document holds transitions this editor cannot draw; nil when none.
    var undrawnTransitionsNotice: String? {
        let n = unknownTransitionCount
        guard n > 0 else { return nil }
        return n == 1
            ? "1 transition from a newer version of the editor is kept in the project and drawn as a hard cut."
            : "\(n) transitions from a newer version of the editor are kept in the project and drawn as hard cuts."
    }

    /// Every notice the document needs on open (layers or transitions kept but not drawn), in a fixed order.
    var openNotices: [String] { [undrawnElementLayersNotice, undrawnTransitionsNotice].compactMap { $0 } }
}
