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
import Foundation

/// How a text layer's content arrives (`clip.text.reveal`) or leaves (`clip.text.unreveal`): per character, word or
/// line, each unit starting `staggerFrames` after the one before it and taking `unitFrames` to arrive. Every field is
/// optional and a field left nil is not written (`normalized` drops the ones that hold their default), so a text layer
/// without a reveal saves exactly as before. A reveal
/// whose `v` is not one this editor knows (written by a newer version) stays in the document unchanged, is not drawn
/// (the text shows in full), and is counted by `unsupportedTextRevealsNotice`.
public struct NativeTextReveal: Codable, Equatable, Hashable, Sendable {
    public static let version = 1
    public static let units = ["characters", "words", "lines"]
    public static let styles = ["fade", "rise", "grow", "typeOn"]
    public static let orders = ["forward", "backward", "center", "random"]
    public static let defaultUnit = "words"
    public static let defaultStyle = "fade"
    public static let defaultOrder = "forward"
    public static let defaultStaggerFrames = 3.0
    public static let defaultUnitFrames = 12.0
    public static let staggerFramesRange = 0.0...600.0
    public static let unitFramesRange = 1.0...600.0
    public static let seedRange = 0...Int(Int32.max)

    /// The reveal's `v`.
    public var v: Int
    /// characters, words or lines (default words).
    public var unit: String?
    /// fade, rise, grow or typeOn (default fade).
    public var style: String?
    /// Frames between the starts of two units that follow each other in the order (default 3).
    public var staggerFrames: Double?
    /// Frames one unit takes from hidden to shown (default 12); ignored by typeOn, whose units appear at once.
    public var unitFrames: Double?
    /// forward, backward, center (outwards from the middle) or random (default forward).
    public var order: String?
    /// Seed of the random order (default 0): the same seed gives the same order in preview, export and every run.
    public var seed: Int?
    /// typeOn only: a bar in the text colour, blinking at the end of the shown text.
    public var cursor: Bool?
    /// The stored value of a reveal this version cannot read (its `v` or shape is unknown), written back verbatim.
    public private(set) var unsupported: NativeJSONValue?

    public init(unit: String? = nil, style: String? = nil, staggerFrames: Double? = nil, unitFrames: Double? = nil,
                order: String? = nil, seed: Int? = nil, cursor: Bool? = nil) {
        v = Self.version; self.unit = unit; self.style = style; self.staggerFrames = staggerFrames
        self.unitFrames = unitFrames; self.order = order; self.seed = seed; self.cursor = cursor
    }

    public var resolvedUnit: String { unit ?? Self.defaultUnit }
    public var resolvedStyle: String { style ?? Self.defaultStyle }
    public var resolvedOrder: String { order ?? Self.defaultOrder }
    public var resolvedStaggerFrames: Double { staggerFrames ?? Self.defaultStaggerFrames }
    public var resolvedUnitFrames: Double { unitFrames ?? Self.defaultUnitFrames }
    public var resolvedSeed: Int { seed ?? 0 }
    public var hasCursor: Bool { cursor == true && resolvedStyle == "typeOn" }

    /// The same reveal with every field that holds its default left out, which is how it is stored.
    public var normalized: NativeTextReveal {
        var r = self
        if r.unit == Self.defaultUnit { r.unit = nil }
        if r.style == Self.defaultStyle { r.style = nil }
        if r.order == Self.defaultOrder { r.order = nil }
        if r.staggerFrames == Self.defaultStaggerFrames { r.staggerFrames = nil }
        if r.unitFrames == Self.defaultUnitFrames { r.unitFrames = nil }
        if r.seed == 0 { r.seed = nil }
        if r.cursor == false { r.cursor = nil }
        return r
    }

    /// False for a reveal kept verbatim because this version cannot read it.
    public var isSupported: Bool { unsupported == nil }

    private enum Keys: String, CodingKey { case v, unit, style, staggerFrames, unitFrames, order, seed, cursor }

    public init(from decoder: Decoder) throws {
        let raw = try NativeJSONValue(from: decoder)
        if raw["v"]?.numberValue == 1, let typed = Self.parse(raw) { self = typed; return }
        v = raw["v"]?.numberValue.flatMap { Int(exactly: $0) } ?? 0; unsupported = raw
    }

    public func encode(to encoder: Encoder) throws {
        if let unsupported { try unsupported.encode(to: encoder); return }
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(v, forKey: .v)
        try c.encodeIfPresent(unit, forKey: .unit)
        try c.encodeIfPresent(style, forKey: .style)
        try c.encodeIfPresent(staggerFrames, forKey: .staggerFrames)
        try c.encodeIfPresent(unitFrames, forKey: .unitFrames)
        try c.encodeIfPresent(order, forKey: .order)
        try c.encodeIfPresent(seed, forKey: .seed)
        try c.encodeIfPresent(cursor, forKey: .cursor)
    }

    public func hash(into h: inout Hasher) {
        h.combine(v); h.combine(unit); h.combine(style); h.combine(staggerFrames); h.combine(unitFrames)
        h.combine(order); h.combine(seed); h.combine(cursor)
        if let unsupported { h.combine(String(describing: unsupported)) }
    }

    /// A version-1 reveal read leniently: nil when a value has the wrong type (the validator names the problem).
    private static func parse(_ raw: NativeJSONValue) -> NativeTextReveal? {
        guard raw.isRecord else { return nil }
        var reveal = NativeTextReveal()
        for key in ["unit", "style", "order"] where raw[key] != nil && raw[key]?.stringValue == nil { return nil }
        for key in ["staggerFrames", "unitFrames", "seed"] where raw[key] != nil && raw[key]?.numberValue == nil { return nil }
        if let c = raw["cursor"], c.boolValue == nil { return nil }
        reveal.unit = raw["unit"]?.stringValue; reveal.style = raw["style"]?.stringValue; reveal.order = raw["order"]?.stringValue
        reveal.staggerFrames = raw["staggerFrames"]?.numberValue; reveal.unitFrames = raw["unitFrames"]?.numberValue
        if let n = raw["seed"]?.numberValue { guard let whole = Int(exactly: n) else { return nil }; reveal.seed = whole }
        reveal.cursor = raw["cursor"]?.boolValue
        return reveal
    }
}

/// Validation of `clip.text.reveal` / `clip.text.unreveal` (NativeClipText): every bad value is an issue, nothing is
/// clamped. A reveal with a `v` other than 1 is kept and not validated further.
func validateNativeTextReveal(_ reveal: NativeJSONValue?, _ path: String, _ issues: inout [NativeProjectDocumentValidationIssue]) {
    guard let reveal else { return }
    guard reveal.isRecord else { return pushIssue(&issues, .invalidClip, path, "Text reveal must be an object") }
    guard let v = reveal["v"]?.numberValue else { return pushIssue(&issues, .invalidClip, "\(path).v", "Text reveal v must be a number") }
    guard v == 1 else { return }
    for (key, allowed) in [("unit", NativeTextReveal.units), ("style", NativeTextReveal.styles), ("order", NativeTextReveal.orders)] {
        if let value = reveal[key], value.stringValue.map(allowed.contains) != true {
            pushIssue(&issues, .invalidClip, "\(path).\(key)", "Text reveal \(key) must be one of \(allowed.joined(separator: ", "))")
        }
    }
    for (key, range, label) in [("staggerFrames", NativeTextReveal.staggerFramesRange, "Stagger"),
                                ("unitFrames", NativeTextReveal.unitFramesRange, "Unit length")] {
        if let value = reveal[key], value.numberValue.map({ $0.isFinite && range.contains($0) }) != true {
            pushIssue(&issues, .invalidClip, "\(path).\(key)", "\(label) must be a number of frames from \(Int(range.lowerBound)) to \(Int(range.upperBound))")
        }
    }
    if let seed = reveal["seed"],
       seed.numberValue.map({ $0.isFinite && $0 == $0.rounded() && Double(NativeTextReveal.seedRange.lowerBound) <= $0 && $0 <= Double(NativeTextReveal.seedRange.upperBound) }) != true {
        pushIssue(&issues, .invalidClip, "\(path).seed", "Seed must be a whole number from 0 to \(NativeTextReveal.seedRange.upperBound)")
    }
    if let cursor = reveal["cursor"], cursor.boolValue == nil {
        pushIssue(&issues, .invalidClip, "\(path).cursor", "Cursor must be true or false")
    }
}

public extension NativeProjectDocument {
    /// One notice for text reveals from a newer version, retained in the document but not drawn.
    var unsupportedTextRevealsNotice: String? {
        let count = sequence.tracks.flatMap(\.clips).reduce(0) { total, clip in
            guard let text = resolvedText(clip, textStyles ?? []) else { return total }
            return total + [text.reveal, text.unreveal].filter { $0?.isSupported == false }.count
        }
        guard count > 0 else { return nil }
        return count == 1
            ? "1 text reveal from a newer version of the editor is kept in the project but not drawn in preview or export."
            : "\(count) text reveals from a newer version of the editor are kept in the project but not drawn in preview or export."
    }
}

/// When each unit of a text layer arrives and leaves. Pure arithmetic on frames, so preview and export, which both
/// ask it, cannot disagree. The reveal and the unreveal each count their own units (they may use different ones).
public struct NativeTextRevealTiming: Equatable, Sendable {
    /// Frames from the start of the first unit to the end of the last (stagger and unit length after compression).
    public let revealFrames: Double
    public let unrevealFrames: Double
    /// Factor applied to both reveals' frames so they fit the clip: 1 when they already do, below 1 when compressed.
    public let compression: Double
    public var isCompressed: Bool { compression < 1 }

    let revealCount: Int
    let unrevealCount: Int
    let clipFrames: Double
    let reveal: NativeTextReveal?
    let unreveal: NativeTextReveal?
    /// Position of each unit in its reveal order (0 starts first), per reveal.
    let inRanks: [Int]
    let outRanks: [Int]

    /// `unitCount` units arrive; `unrevealUnitCount` leave (the same number when nil). An unsupported reveal counts as none.
    public init(unitCount: Int, unrevealUnitCount: Int? = nil, clipFrames: Double, reveal: NativeTextReveal?, unreveal: NativeTextReveal?) {
        let reveal = reveal?.isSupported == true ? reveal : nil
        let unreveal = unreveal?.isSupported == true ? unreveal : nil
        let inCount = max(0, unitCount), outCount = max(0, unrevealUnitCount ?? unitCount)
        revealCount = inCount; unrevealCount = outCount; self.clipFrames = clipFrames; self.reveal = reveal; self.unreveal = unreveal
        func span(_ r: NativeTextReveal?, _ n: Int) -> Double {
            guard let r, n > 0 else { return 0 }
            return Double(n - 1) * r.resolvedStaggerFrames + (r.resolvedStyle == "typeOn" ? 0 : r.resolvedUnitFrames)
        }
        let natural = span(reveal, inCount) + span(unreveal, outCount)
        compression = natural > clipFrames && natural > 0 ? max(0, clipFrames) / natural : 1
        revealFrames = span(reveal, inCount) * compression; unrevealFrames = span(unreveal, outCount) * compression
        inRanks = Self.ranks(inCount, reveal); outRanks = Self.ranks(outCount, unreveal)
    }

    /// True when the reveal or unreveal changes the letters at clip-local `frame`: before the reveal ends or once the
    /// unreveal has begun. Between them the letters are drawn exactly as a text layer without a reveal draws them
    /// (a type-on cursor, which blinks, is the renderer's own matter).
    public func isAnimating(atFrame frame: Double) -> Bool {
        if reveal != nil, revealCount > 0, frame < revealFrames { return true }
        if unreveal != nil, unrevealCount > 0, frame > clipFrames - unrevealFrames { return true }
        return false
    }

    /// How far unit `index` has arrived at clip-local `frame`: 0 (hidden) … 1 (shown). 1 without a reveal.
    public func arrived(ofUnit index: Int, atFrame frame: Double) -> Double {
        guard let reveal, inRanks.indices.contains(index) else { return 1 }
        let start = Double(inRanks[index]) * reveal.resolvedStaggerFrames * compression
        return Self.progress(frame - start, reveal, compression)
    }

    /// How much of unit `index` the unreveal has not yet taken away at `frame`: 1 (shown) … 0 (gone). 1 without an unreveal.
    public func remaining(ofUnit index: Int, atFrame frame: Double) -> Double {
        guard let unreveal, outRanks.indices.contains(index) else { return 1 }
        let start = clipFrames - unrevealFrames + Double(outRanks[index]) * unreveal.resolvedStaggerFrames * compression
        return 1 - Self.progress(frame - start, unreveal, compression)
    }

    /// Both amounts of unit `index`, when the reveal and the unreveal use the same units.
    public func amounts(ofUnit index: Int, atFrame frame: Double) -> (arrived: Double, remaining: Double) {
        (arrived(ofUnit: index, atFrame: frame), remaining(ofUnit: index, atFrame: frame))
    }

    private static func progress(_ elapsed: Double, _ r: NativeTextReveal, _ compression: Double) -> Double {
        if r.resolvedStyle == "typeOn" { return elapsed >= 0 ? 1 : 0 }
        return min(1, max(0, elapsed / (r.resolvedUnitFrames * compression)))
    }

    /// The order the units arrive in: `ranks[i]` is the position of unit `i`.
    static func ranks(_ n: Int, _ r: NativeTextReveal?) -> [Int] {
        guard let r, n > 0 else { return Array(0..<max(0, n)) }
        switch r.resolvedOrder {
        case "backward": return (0..<n).map { n - 1 - $0 }
        case "center":
            let middle = Double(n - 1) / 2
            let arrival = (0..<n).sorted { (abs(Double($0) - middle), $0) < (abs(Double($1) - middle), $1) }
            return invert(arrival)
        case "random":
            var rng = SplitMix64(seed: UInt64(r.resolvedSeed))
            var arrival = Array(0..<n)
            if n > 1 { for i in stride(from: n - 1, to: 0, by: -1) { arrival.swapAt(i, Int(rng.next() % UInt64(i + 1))) } }
            return invert(arrival)
        default: return Array(0..<n)
        }
    }

    private static func invert(_ arrival: [Int]) -> [Int] {
        var ranks = [Int](repeating: 0, count: arrival.count)
        for (rank, unit) in arrival.enumerated() { ranks[unit] = rank }
        return ranks
    }
}

/// A small fixed generator, so a seeded order is the same on every platform and in every run.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
