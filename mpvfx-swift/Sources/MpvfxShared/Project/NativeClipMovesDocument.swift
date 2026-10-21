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
// `clip.moves` in project.json: a clip's In, Out and Loop moves.
//
//   "moves": { "v": 1,
//              "in"?:   { "kind", "frames", "direction"?, "amount"?, "ease"? },
//              "out"?:  { "kind", "frames", "direction"?, "amount"?, "ease"? },
//              "loop"?: { "kind", "periodFrames", "amount"?, "ease"? } }
//
// The object is kept exactly as it was read (`stored`): a version or kind this build does not know, and keys it
// does not know, survive open + save unchanged; such a move is not drawn (`isReadable`, `unreadableMovesNotice`).
// The kinds and their formulas are in NativeClipMoves.swift; validation in NativeClipMovesValidation.swift.
import Foundation

/// Which edge of the clip an In or Out move is attached to.
public enum NativeMoveEdge: String, CaseIterable, Sendable { case `in`, out }

/// An In or Out move: `frames` long from the clip's first frame (In) or up to its last frame (Out).
public struct NativeEdgeMove: Equatable, Sendable {
    public var kind: NativeEdgeMoveKind
    /// Length in timeline frames (a positive integer).
    public var frames: Int
    /// Slide only: the edge the layer comes from (In) or goes to (Out). Absent: left.
    public var direction: NativeMoveDirection? = nil
    /// The kind's size (NativeEdgeMoveKind.defaultAmount, `accepts(amount:)`). Absent: the kind's default.
    public var amount: Double? = nil
    /// The keyframe engine interpolation the move eases with. Absent: ease-out for In, ease-in for Out.
    public var ease: NativeInterpolation? = nil

    public var resolvedAmount: Double { amount ?? kind.defaultAmount }
    public var resolvedDirection: NativeMoveDirection { direction ?? .left }
    public func resolvedEase(_ edge: NativeMoveEdge) -> NativeInterpolation { ease ?? NativeMoveEase.defaultEase(edge) }
}

extension NativeEdgeMove {
    /// A move with the kind's default direction, amount and ease; set those properties to change them.
    public init(kind: NativeEdgeMoveKind, frames: Int) { self.init(kind: kind, frames: frames, direction: nil, amount: nil, ease: nil) }
}

/// A Loop move: repeats every `periodFrames` frames from the clip's first frame to its last.
public struct NativeLoopMove: Equatable, Sendable {
    public var kind: NativeLoopMoveKind
    /// One full cycle in timeline frames: an even integer, at least 2 (each half is a whole number of frames).
    public var periodFrames: Int
    /// The kind's size (NativeLoopMoveKind.defaultAmount, `accepts(amount:)`). Absent: the kind's default.
    public var amount: Double?
    /// The keyframe engine interpolation of each half period. Absent: ease-in-out.
    public var ease: NativeInterpolation?

    public init(kind: NativeLoopMoveKind, periodFrames: Int, amount: Double? = nil, ease: NativeInterpolation? = nil) {
        self.kind = kind; self.periodFrames = periodFrames; self.amount = amount; self.ease = ease
    }

    public var resolvedAmount: Double { amount ?? kind.defaultAmount }
    public var resolvedEase: NativeInterpolation { ease ?? NativeMoveEase.easeInOut }
}

/// The eases a move takes when it names none: the keyframe menu's presets (TimelineKeyframeMenu.swift).
public enum NativeMoveEase {
    public static let easeIn = NativeInterpolation.cubicBezier(CubicBezierControlPoints(x1: 0.42, y1: 0, x2: 1, y2: 1))
    public static let easeOut = NativeInterpolation.cubicBezier(CubicBezierControlPoints(x1: 0, y1: 0, x2: 0.58, y2: 1))
    public static let easeInOut = NativeInterpolation.cubicBezier(CubicBezierControlPoints(x1: 0.42, y1: 0, x2: 0.58, y2: 1))
    /// An entrance arrives softly (ease-out); an exit leaves softly (ease-in).
    public static func defaultEase(_ edge: NativeMoveEdge) -> NativeInterpolation { edge == .in ? easeOut : easeIn }
}

/// `clip.moves`, kept as stored. Typed reads return nil for a move this build cannot draw.
public struct NativeClipMoves: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// The object as read or last written, including keys, versions and kinds this build does not know.
    public internal(set) var stored: NativeJSONObject

    public init(in inMove: NativeEdgeMove? = nil, out outMove: NativeEdgeMove? = nil, loop: NativeLoopMove? = nil) {
        stored = ["v": .number(Double(Self.currentVersion))]
        self.inMove = inMove; self.outMove = outMove; self.loop = loop
    }
    public init(stored: NativeJSONObject) { self.stored = stored }
    public init(from decoder: Decoder) throws { stored = try NativeJSONObject(from: decoder) }
    public func encode(to encoder: Encoder) throws { try stored.encode(to: encoder) }

    /// `v` as stored (nil when missing or not a number; the validator rejects both).
    public var version: Double? { stored["v"]?.numberValue }
    public var isCurrentVersion: Bool { version == Double(Self.currentVersion) }
    /// No In, Out or Loop is stored (the clip then omits `moves`).
    public var isEmpty: Bool { NativeMoveSlot.allCases.allSatisfy { stored[$0.rawValue] == nil } }
    /// Everything stored can be drawn: the current version, and only kinds this build knows.
    public var isReadable: Bool {
        isCurrentVersion && NativeMoveSlot.allCases.allSatisfy { stored[$0.rawValue] == nil || read($0) }
    }

    public var inMove: NativeEdgeMove? {
        get { isCurrentVersion ? stored["in"].flatMap(NativeEdgeMove.init(json:)) : nil }
        set { stored["in"] = newValue?.json }
    }
    public var outMove: NativeEdgeMove? {
        get { isCurrentVersion ? stored["out"].flatMap(NativeEdgeMove.init(json:)) : nil }
        set { stored["out"] = newValue?.json }
    }
    public var loop: NativeLoopMove? {
        get { isCurrentVersion ? stored["loop"].flatMap(NativeLoopMove.init(json:)) : nil }
        set { stored["loop"] = newValue?.json }
    }
    public func edgeMove(_ edge: NativeMoveEdge) -> NativeEdgeMove? { edge == .in ? inMove : outMove }

    /// Removes one slot as stored, whatever it holds (split: the In leaves the right part, the Out the left).
    public mutating func remove(_ slot: NativeMoveSlot) { stored.removeValue(forKey: slot.rawValue) }

    private func read(_ slot: NativeMoveSlot) -> Bool {
        switch slot { case .in: inMove != nil; case .out: outMove != nil; case .loop: loop != nil }
    }
}

/// The three keys of `moves` that hold a move.
public enum NativeMoveSlot: String, CaseIterable, Sendable { case `in`, out, loop }

// MARK: JSON of one move

extension NativeEdgeMove {
    init?(json: NativeJSONValue) {
        guard let kind = json["kind"]?.stringValue.flatMap(NativeEdgeMoveKind.init(rawValue:)),
              let frames = nativeMoveInteger(json["frames"]) else { return nil }
        self.init(kind: kind, frames: frames, direction: json["direction"]?.stringValue.flatMap(NativeMoveDirection.init(rawValue:)),
                  amount: json["amount"]?.numberValue, ease: json["ease"].flatMap(nativeMoveInterpolation))
    }
    var json: NativeJSONValue {
        var o: NativeJSONObject = ["kind": .string(kind.rawValue), "frames": .number(Double(frames))]
        if let direction { o["direction"] = .string(direction.rawValue) }
        if let amount { o["amount"] = .number(amount) }
        if let ease { o["ease"] = nativeMoveInterpolationJSON(ease) }
        return .object(o)
    }
}

extension NativeLoopMove {
    init?(json: NativeJSONValue) {
        guard let kind = json["kind"]?.stringValue.flatMap(NativeLoopMoveKind.init(rawValue:)),
              let period = nativeMoveInteger(json["periodFrames"]) else { return nil }
        self.init(kind: kind, periodFrames: period, amount: json["amount"]?.numberValue, ease: json["ease"].flatMap(nativeMoveInterpolation))
    }
    var json: NativeJSONValue {
        var o: NativeJSONObject = ["kind": .string(kind.rawValue), "periodFrames": .number(Double(periodFrames))]
        if let amount { o["amount"] = .number(amount) }
        if let ease { o["ease"] = nativeMoveInterpolationJSON(ease) }
        return .object(o)
    }
}

/// A whole number of frames that fits an Int (the validator has already required a positive integer).
func nativeMoveInteger(_ v: NativeJSONValue?) -> Int? {
    guard let n = v?.numberValue, jsIsInteger(n), abs(n) <= jsMaxSafeInteger else { return nil }
    return Int(n)
}

/// A move's `ease`: the keyframe `outgoing` shape (`{"type":"linear"}`, `{"type":"cubic-bezier","controlPoints":{…}}`).
func nativeMoveInterpolation(_ v: NativeJSONValue) -> NativeInterpolation? {
    switch v["type"]?.stringValue {
    case "hold": return .hold
    case "linear": return .linear
    case "cubic-bezier":
        let cp = v["controlPoints"]
        guard let x1 = cp?["x1"]?.numberValue, let y1 = cp?["y1"]?.numberValue,
              let x2 = cp?["x2"]?.numberValue, let y2 = cp?["y2"]?.numberValue else { return nil }
        return .cubicBezier(CubicBezierControlPoints(x1: x1, y1: y1, x2: x2, y2: y2))
    default: return nil
    }
}

func nativeMoveInterpolationJSON(_ ease: NativeInterpolation) -> NativeJSONValue {
    switch ease {
    case .hold: return .object(["type": .string("hold")])
    case .linear: return .object(["type": .string("linear")])
    case .cubicBezier(let p):
        let cp: NativeJSONObject = ["x1": .number(p.x1), "y1": .number(p.y1), "x2": .number(p.x2), "y2": .number(p.y2)]
        return .object(["type": .string("cubic-bezier"), "controlPoints": .object(cp)])
    }
}

// MARK: Moves the renderer skips

public extension NativeProjectDocument {
    /// Clips whose moves are kept but not drawn: a version or a kind from a newer editor.
    var unreadableMovesClipCount: Int {
        sequence.tracks.reduce(0) { n, track in n + track.clips.filter { $0.moves.map { !$0.isReadable } ?? false }.count }
    }

    /// The one notice shown on open when some moves cannot be drawn; nil when every move can.
    var unreadableMovesNotice: String? {
        let n = unreadableMovesClipCount
        guard n > 0 else { return nil }
        return n == 1
            ? "Moves on 1 clip are from a newer version of the editor: they are kept in the project but not drawn in preview or export."
            : "Moves on \(n) clips are from a newer version of the editor: they are kept in the project but not drawn in preview or export."
    }
}
