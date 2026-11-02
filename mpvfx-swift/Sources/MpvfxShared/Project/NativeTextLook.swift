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

/// How the letters of a text layer are decorated beyond their fill: up to two outlines around the glyphs, a drop
/// shadow and a glow under them, a background plate behind each line or the whole block, and a two-colour gradient
/// in place of the solid fill (`clip.text.look`). Every field is optional and omitted when it holds its default, so a text
/// layer without a look saves exactly as before. A look whose `v` is not one this editor knows (written by a newer
/// version) stays in the document unchanged, is not drawn, and is counted by `unsupportedTextLooksNotice`.
public struct NativeTextLook: Codable, Equatable, Hashable, Sendable {
    public static let version = 1
    public static let maxOutlines = 2
    public static let outlineWidthRange = 0.0...100.0
    public static let shadowOffsetRange = -500.0...500.0
    public static let shadowBlurRange = 0.0...200.0
    public static let positions = ["outside", "center"]
    public static let glowRadiusRange = 0.0...200.0
    public static let glowStrengthRange = 0.0...1.0
    public static let plateModes = ["line", "block"]
    public static let platePaddingRange = 0.0...500.0
    public static let plateRadiusRange = 0.0...500.0
    public static let fillAngleRange = -360.0...360.0
    public static let defaultGlowRadius = 12.0
    public static let defaultGlowStrength = 1.0

    /// The look's `v`.
    public var v: Int
    /// Closest to the letters first; the second outline starts where the first ends.
    public var outlines: [Outline]?
    public var shadow: Shadow?
    /// A soft halo of `color` around the letters, outside any outline.
    public var glow: Glow?
    /// A rounded rectangle of `color` behind each line of text or behind the whole block.
    public var plate: Plate?
    /// Two colours across the text instead of the solid text colour.
    public var fill: Fill?
    /// The stored value of a look this version cannot read (its `v` or shape is unknown), written back verbatim.
    public private(set) var unsupported: NativeJSONValue?

    /// One outline: `width` px (0…100) of `color`. `position` `outside` (the default) puts it entirely outside the
    /// letter edge; `center` straddles the edge, so half of it shows because the fill is drawn over the inner half.
    public struct Outline: Codable, Equatable, Hashable, Sendable {
        public var width: Double
        public var color: String
        public var position: String?
        public init(width: Double, color: String, position: String? = nil) { self.width = width; self.color = color; self.position = position }
        public var resolvedPosition: String { position ?? "outside" }
    }

    /// A drop shadow under the letters: offset (`x`, `y` px, −500…500), `blur` px (0…200) and `color`.
    public struct Shadow: Codable, Equatable, Hashable, Sendable {
        public var x: Double?
        public var y: Double?
        public var blur: Double?
        public var color: String
        public init(x: Double? = nil, y: Double? = nil, blur: Double? = nil, color: String) {
            self.x = x; self.y = y; self.blur = blur; self.color = color
        }
        public var resolvedX: Double { x ?? 0 }
        public var resolvedY: Double { y ?? 0 }
        public var resolvedBlur: Double { blur ?? 0 }
    }

    /// A glow: a halo `radius` px (0…200, default 12) wide that reaches `strength` (0…1, default 1) of `color` at the
    /// edge of a large letter shape (a thin stroke gives a fainter halo). A strength of 0 draws nothing.
    public struct Glow: Codable, Equatable, Hashable, Sendable {
        public var radius: Double?
        public var strength: Double?
        public var color: String
        public init(radius: Double? = nil, strength: Double? = nil, color: String) { self.radius = radius; self.strength = strength; self.color = color }
        public var resolvedRadius: Double { radius ?? NativeTextLook.defaultGlowRadius }
        public var resolvedStrength: Double { strength ?? NativeTextLook.defaultGlowStrength }
        /// True when the glow changes the picture.
        public var isActive: Bool { resolvedStrength > 0 && !(color.count == 9 && color.lowercased().hasSuffix("00")) }
    }

    /// A plate behind the text: `mode` `line` (the default) puts one rounded rectangle behind each line, `block` one
    /// behind all of them. `paddingX` and `paddingY` px (0…500, default 0) grow it past the text; `radius` px (0…500,
    /// default 0) rounds its corners; `color` may carry alpha. Plates of neighbouring lines that touch or overlap (the gap
    /// between the lines is at most twice the vertical padding) join into one shape, and a line with no text gets none.
    public struct Plate: Codable, Equatable, Hashable, Sendable {
        public var mode: String?
        public var paddingX: Double?
        public var paddingY: Double?
        public var radius: Double?
        public var color: String
        public init(mode: String? = nil, paddingX: Double? = nil, paddingY: Double? = nil, radius: Double? = nil, color: String) {
            self.mode = mode; self.paddingX = paddingX; self.paddingY = paddingY; self.radius = radius; self.color = color
        }
        public var resolvedMode: String { mode ?? "line" }
        public var resolvedPaddingX: Double { paddingX ?? 0 }
        public var resolvedPaddingY: Double { paddingY ?? 0 }
        public var resolvedRadius: Double { radius ?? 0 }
        /// True when the plate changes the picture (its colour is not fully clear).
        public var isActive: Bool { !(color.count == 9 && color.lowercased().hasSuffix("00")) }
    }

    /// A gradient fill from `from` to `to` along `angle` degrees (0 runs left to right, 90 top to bottom; −360…360,
    /// default 0), across the bounds of the letters.
    public struct Fill: Codable, Equatable, Hashable, Sendable {
        public var from: String
        public var to: String
        public var angle: Double?
        public init(from: String, to: String, angle: Double? = nil) { self.from = from; self.to = to; self.angle = angle }
        public var resolvedAngle: Double { angle ?? 0 }
    }

    public init(outlines: [Outline]? = nil, shadow: Shadow? = nil, glow: Glow? = nil, plate: Plate? = nil, fill: Fill? = nil) {
        v = Self.version; self.outlines = outlines; self.shadow = shadow; self.glow = glow; self.plate = plate; self.fill = fill
    }

    /// False for a look kept verbatim because this version cannot read it.
    public var isSupported: Bool { unsupported == nil }
    /// A supported look that draws nothing extra.
    public var isEmpty: Bool {
        isSupported && (outlines ?? []).isEmpty && shadow == nil && glow?.isActive != true && plate?.isActive != true && fill == nil
    }

    private enum Keys: String, CodingKey { case v, outlines, shadow, glow, plate, fill }

    public init(from decoder: Decoder) throws {
        let raw = try NativeJSONValue(from: decoder)
        let typed = raw["v"]?.numberValue == 1 ? Self.parse(raw) : nil
        if let typed { self = typed; return }
        v = Int(raw["v"]?.numberValue ?? 0); unsupported = raw
    }

    public func encode(to encoder: Encoder) throws {
        if let unsupported { try unsupported.encode(to: encoder); return }
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(v, forKey: .v)
        try c.encodeIfPresent(outlines, forKey: .outlines)
        try c.encodeIfPresent(shadow, forKey: .shadow)
        try c.encodeIfPresent(glow, forKey: .glow)
        try c.encodeIfPresent(plate, forKey: .plate)
        try c.encodeIfPresent(fill, forKey: .fill)
    }

    public func hash(into h: inout Hasher) {
        h.combine(v); h.combine(outlines); h.combine(shadow); h.combine(glow); h.combine(plate); h.combine(fill)
        if let unsupported { h.combine(String(describing: unsupported)) }
    }

    /// A version-1 look read leniently: nil when a value has the wrong type (the validator names the problem).
    private static func parse(_ raw: NativeJSONValue) -> NativeTextLook? {
        guard raw.isRecord else { return nil }
        var look = NativeTextLook()
        if let list = raw["outlines"] {
            guard let items = list.arrayValue else { return nil }
            var outlines: [Outline] = []
            for item in items {
                guard item.isRecord, let w = item["width"]?.numberValue, let c = item["color"]?.stringValue else { return nil }
                var position: String?
                if let p = item["position"] { guard let s = p.stringValue else { return nil }; position = s }
                outlines.append(Outline(width: w, color: c, position: position))
            }
            look.outlines = outlines
        }
        if let s = raw["shadow"] {
            guard s.isRecord, let c = s["color"]?.stringValue else { return nil }
            for k in ["x", "y", "blur"] where s[k] != nil && s[k]?.numberValue == nil { return nil }
            look.shadow = Shadow(x: s["x"]?.numberValue, y: s["y"]?.numberValue, blur: s["blur"]?.numberValue, color: c)
        }
        if let g = raw["glow"] {
            guard g.isRecord, let c = g["color"]?.stringValue else { return nil }
            for k in ["radius", "strength"] where g[k] != nil && g[k]?.numberValue == nil { return nil }
            look.glow = Glow(radius: g["radius"]?.numberValue, strength: g["strength"]?.numberValue, color: c)
        }
        if let p = raw["plate"] {
            guard p.isRecord, let c = p["color"]?.stringValue else { return nil }
            for k in ["paddingX", "paddingY", "radius"] where p[k] != nil && p[k]?.numberValue == nil { return nil }
            if let m = p["mode"], m.stringValue == nil { return nil }
            look.plate = Plate(mode: p["mode"]?.stringValue, paddingX: p["paddingX"]?.numberValue, paddingY: p["paddingY"]?.numberValue,
                               radius: p["radius"]?.numberValue, color: c)
        }
        if let f = raw["fill"] {
            guard f.isRecord, let from = f["from"]?.stringValue, let to = f["to"]?.stringValue else { return nil }
            if f["angle"] != nil && f["angle"]?.numberValue == nil { return nil }
            look.fill = Fill(from: from, to: to, angle: f["angle"]?.numberValue)
        }
        return look
    }
}

/// Validation of `clip.text.look` (NativeClipText): every bad value is an issue, nothing is clamped. A look with a
/// `v` other than 1 is kept and not validated further.
func validateNativeTextLook(_ look: NativeJSONValue?, _ path: String, _ issues: inout [NativeProjectDocumentValidationIssue]) {
    guard let look else { return }
    guard look.isRecord else { return pushIssue(&issues, .invalidClip, path, "Text look must be an object") }
    guard let v = look["v"]?.numberValue else { return pushIssue(&issues, .invalidClip, "\(path).v", "Text look v must be a number") }
    guard v == 1 else { return }
    func range(_ value: NativeJSONValue?, _ p: String, _ r: ClosedRange<Double>, _ what: String) {
        guard let value else { return }
        if value.numberValue.map({ $0.isFinite && r.contains($0) }) != true {
            pushIssue(&issues, .invalidClip, p, "\(what) must be a number from \(Int(r.lowerBound)) to \(Int(r.upperBound))")
        }
    }
    func color(_ value: NativeJSONValue?, _ p: String) {
        if value?.stringValue.map(isNativeHexColor) != true { pushIssue(&issues, .invalidClip, p, "Text look colors must be #RGB, #RRGGBB or #RRGGBBAA") }
    }
    if let raw = look["outlines"] {
        guard let list = raw.arrayValue else { return pushIssue(&issues, .invalidClip, "\(path).outlines", "Outlines must be an array") }
        if list.count > NativeTextLook.maxOutlines {
            pushIssue(&issues, .invalidClip, "\(path).outlines", "A text look has at most \(NativeTextLook.maxOutlines) outlines")
        }
        for (i, o) in list.enumerated() {
            let p = "\(path).outlines[\(i)]"
            guard o.isRecord else { pushIssue(&issues, .invalidClip, p, "An outline must be an object"); continue }
            if o["width"] == nil { pushIssue(&issues, .invalidClip, "\(p).width", "An outline needs a width") }
            range(o["width"], "\(p).width", NativeTextLook.outlineWidthRange, "Outline width")
            color(o["color"], "\(p).color")
            if let pos = o["position"], pos.stringValue.map(NativeTextLook.positions.contains) != true {
                pushIssue(&issues, .invalidClip, "\(p).position", "Outline position must be one of \(NativeTextLook.positions.joined(separator: ", "))")
            }
        }
    }
    if let s = look["shadow"] {
        guard s.isRecord else { return pushIssue(&issues, .invalidClip, "\(path).shadow", "Shadow must be an object") }
        range(s["x"], "\(path).shadow.x", NativeTextLook.shadowOffsetRange, "Shadow x offset")
        range(s["y"], "\(path).shadow.y", NativeTextLook.shadowOffsetRange, "Shadow y offset")
        range(s["blur"], "\(path).shadow.blur", NativeTextLook.shadowBlurRange, "Shadow blur")
        color(s["color"], "\(path).shadow.color")
    }
    if let g = look["glow"] {
        if g.isRecord {
            range(g["radius"], "\(path).glow.radius", NativeTextLook.glowRadiusRange, "Glow radius")
            if let strength = g["strength"],
               strength.numberValue.map({ $0.isFinite && NativeTextLook.glowStrengthRange.contains($0) }) != true {
                pushIssue(&issues, .invalidClip, "\(path).glow.strength", "Glow strength must be a number from 0 to 1")
            }
            color(g["color"], "\(path).glow.color")
        } else { pushIssue(&issues, .invalidClip, "\(path).glow", "Glow must be an object") }
    }
    if let p = look["plate"] {
        if p.isRecord {
            if let mode = p["mode"], mode.stringValue.map(NativeTextLook.plateModes.contains) != true {
                pushIssue(&issues, .invalidClip, "\(path).plate.mode", "Plate mode must be one of \(NativeTextLook.plateModes.joined(separator: ", "))")
            }
            range(p["paddingX"], "\(path).plate.paddingX", NativeTextLook.platePaddingRange, "Plate horizontal padding")
            range(p["paddingY"], "\(path).plate.paddingY", NativeTextLook.platePaddingRange, "Plate vertical padding")
            range(p["radius"], "\(path).plate.radius", NativeTextLook.plateRadiusRange, "Plate corner radius")
            color(p["color"], "\(path).plate.color")
        } else { pushIssue(&issues, .invalidClip, "\(path).plate", "Plate must be an object") }
    }
    if let f = look["fill"] {
        if f.isRecord {
            color(f["from"], "\(path).fill.from")
            color(f["to"], "\(path).fill.to")
            range(f["angle"], "\(path).fill.angle", NativeTextLook.fillAngleRange, "Fill angle")
        } else { pushIssue(&issues, .invalidClip, "\(path).fill", "Fill must be an object") }
    }
}

public extension NativeProjectDocument {
    /// One notice for text looks from a newer version, retained in the document but not drawn.
    var unsupportedTextLooksNotice: String? {
        let count = sequence.tracks.flatMap(\.clips).filter {
            resolvedText($0, textStyles ?? [])?.look?.isSupported == false
        }.count
        guard count > 0 else { return nil }
        return count == 1
            ? "1 text look from a newer version of the editor is kept in the project but not drawn in preview or export."
            : "\(count) text looks from a newer version of the editor are kept in the project but not drawn in preview or export."
    }
}
