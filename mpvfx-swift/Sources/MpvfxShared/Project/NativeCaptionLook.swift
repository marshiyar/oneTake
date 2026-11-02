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
// The look every cue of the caption track shares (`sequence.captions.look`), and the position a single cue may override.
// All sizes are fractions of the frame, so a look reads the same on a 16:9 and a 9:16 composition: `size`, `safeArea` and
// the plate padding scale with the frame's short edge, `maxWidth` with its width. Every field is optional and left out of the
// file while it holds its default, so a track without a look saves exactly as before. A look whose `v` this editor does not
// know (written by a newer version) stays in the document unchanged and is not drawn.
import Foundation

/// Where a caption sits in the frame: `bottom` or `top` (centred, against the safe area) or `custom` (the centre of the
/// text block at `x`, `y`, fractions 0…1 of the frame, pushed back inside the safe area when it would leave it).
public struct NativeCaptionPosition: Codable, Equatable, Hashable, Sendable {
    public static let places = ["bottom", "top", "custom"]
    public var place: String
    public var x: Double?
    public var y: Double?
    public init(place: String, x: Double? = nil, y: Double? = nil) { self.place = place; self.x = x; self.y = y }
    public static let bottom = NativeCaptionPosition(place: "bottom")
    public static let top = NativeCaptionPosition(place: "top")
    public static func custom(x: Double, y: Double) -> NativeCaptionPosition { .init(place: "custom", x: x, y: y) }
}

public struct NativeCaptionLook: Codable, Equatable, Hashable, Sendable {
    public static let version = 1
    public static let sizeRange = 0.01...0.25
    public static let weightRange = 1.0...1000.0
    public static let safeAreaRange = 0.0...0.4
    public static let maxWidthRange = 0.2...1.0
    public static let plateOpacityRange = 0.0...1.0
    public static let platePaddingRange = 0.0...2.0
    public static let maxOutlines = NativeTextLook.maxOutlines
    public static let defaultFontFamily = "Sans"
    public static let defaultSize = 0.06
    public static let defaultWeight = 700
    public static let defaultColor = "#FFFFFF"
    public static let defaultSafeArea = 0.05
    public static let defaultMaxWidth = 0.8
    public static let defaultPlatePadding = 0.35
    /// Lines a cue may take before the lane warns; the cue is still shown whole.
    public static let maxLines = 2

    /// The look's `v`.
    public var v: Int
    public var fontFamily: String?
    /// Font size as a fraction of the frame's short edge (0.01…0.25, default 0.06).
    public var size: Double?
    public var weight: Int?
    public var color: String?
    /// Letter outlines and drop shadow, the same objects a text layer's look holds (`NativeTextLook`), in px of a
    /// 1080 px short edge.
    public var outlines: [NativeTextLook.Outline]?
    public var shadow: NativeTextLook.Shadow?
    /// The box behind the text.
    public var plate: Plate?
    public var position: NativeCaptionPosition?
    /// Margin kept clear on every side, a fraction of the short edge (0…0.4, default 0.05).
    public var safeArea: Double?
    /// Widest a line may be, a fraction of the frame width (0.2…1, default 0.8).
    public var maxWidth: Double?
    /// The stored value of a look this version cannot read, written back verbatim.
    public private(set) var unsupported: NativeJSONValue?

    /// A box behind the text: `color` (`#RRGGBBAA` carries its opacity) and `padding` as a fraction of the font size
    /// (0…2, default 0.35).
    public struct Plate: Codable, Equatable, Hashable, Sendable {
        public var color: String
        public var padding: Double?
        public init(color: String, padding: Double? = nil) { self.color = color; self.padding = padding }
        public var resolvedPadding: Double { padding ?? NativeCaptionLook.defaultPlatePadding }
    }

    public init(fontFamily: String? = nil, size: Double? = nil, weight: Int? = nil, color: String? = nil,
                outlines: [NativeTextLook.Outline]? = nil, shadow: NativeTextLook.Shadow? = nil, plate: Plate? = nil,
                position: NativeCaptionPosition? = nil, safeArea: Double? = nil, maxWidth: Double? = nil) {
        v = Self.version
        self.fontFamily = fontFamily; self.size = size; self.weight = weight; self.color = color
        self.outlines = outlines; self.shadow = shadow; self.plate = plate; self.position = position
        self.safeArea = safeArea; self.maxWidth = maxWidth
    }

    /// False for a look kept verbatim because this version cannot read it.
    public var isSupported: Bool { unsupported == nil }

    public var resolvedFontFamily: String { fontFamily ?? Self.defaultFontFamily }
    public var resolvedSize: Double { size ?? Self.defaultSize }
    public var resolvedWeight: Int { weight ?? Self.defaultWeight }
    public var resolvedColor: String { color ?? Self.defaultColor }
    public var resolvedPosition: NativeCaptionPosition { position ?? .bottom }
    public var resolvedSafeArea: Double { safeArea ?? Self.defaultSafeArea }
    public var resolvedMaxWidth: Double { maxWidth ?? Self.defaultMaxWidth }

    private enum Keys: String, CodingKey { case v, fontFamily, size, weight, color, outlines, shadow, plate, position, safeArea, maxWidth }

    public init(from decoder: Decoder) throws {
        let raw = try NativeJSONValue(from: decoder)
        if raw["v"]?.numberValue == 1, let typed = Self.parse(raw) { self = typed; return }
        v = Int(raw["v"]?.numberValue ?? 0); unsupported = raw
    }

    public func encode(to encoder: Encoder) throws {
        if let unsupported { try unsupported.encode(to: encoder); return }
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(v, forKey: .v)
        try c.encodeIfPresent(fontFamily, forKey: .fontFamily)
        try c.encodeIfPresent(size, forKey: .size)
        try c.encodeIfPresent(weight, forKey: .weight)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeIfPresent(outlines, forKey: .outlines)
        try c.encodeIfPresent(shadow, forKey: .shadow)
        try c.encodeIfPresent(plate, forKey: .plate)
        try c.encodeIfPresent(position, forKey: .position)
        try c.encodeIfPresent(safeArea, forKey: .safeArea)
        try c.encodeIfPresent(maxWidth, forKey: .maxWidth)
    }

    public func hash(into h: inout Hasher) {
        h.combine(v); h.combine(fontFamily); h.combine(size); h.combine(weight); h.combine(color); h.combine(outlines)
        h.combine(shadow); h.combine(plate); h.combine(position); h.combine(safeArea); h.combine(maxWidth)
        if let unsupported { h.combine(String(describing: unsupported)) }
    }

    /// A version-1 look read leniently: nil when a value has the wrong type (the validator names the problem).
    private static func parse(_ raw: NativeJSONValue) -> NativeCaptionLook? {
        guard raw.isRecord else { return nil }
        var look = NativeCaptionLook()
        func number(_ key: String) -> Double?? {
            guard let value = raw[key] else { return .some(nil) }
            guard let n = value.numberValue else { return nil }
            return .some(n)
        }
        func string(_ key: String) -> String?? {
            guard let value = raw[key] else { return .some(nil) }
            guard let s = value.stringValue else { return nil }
            return .some(s)
        }
        guard let size = number("size"), let weight = number("weight"), let safeArea = number("safeArea"),
              let maxWidth = number("maxWidth"), let family = string("fontFamily"), let color = string("color") else { return nil }
        look.size = size; look.safeArea = safeArea; look.maxWidth = maxWidth; look.fontFamily = family; look.color = color
        if let weight {
            guard weight == weight.rounded(), abs(weight) < 1e6 else { return nil }
            look.weight = Int(weight)
        }
        if let list = raw["outlines"] {
            guard let items = list.arrayValue else { return nil }
            var outlines: [NativeTextLook.Outline] = []
            for item in items {
                guard item.isRecord, let w = item["width"]?.numberValue, let c = item["color"]?.stringValue else { return nil }
                var position: String?
                if let p = item["position"] { guard let s = p.stringValue else { return nil }; position = s }
                outlines.append(.init(width: w, color: c, position: position))
            }
            look.outlines = outlines
        }
        if let s = raw["shadow"] {
            guard s.isRecord, let c = s["color"]?.stringValue else { return nil }
            for k in ["x", "y", "blur"] where s[k] != nil && s[k]?.numberValue == nil { return nil }
            look.shadow = .init(x: s["x"]?.numberValue, y: s["y"]?.numberValue, blur: s["blur"]?.numberValue, color: c)
        }
        if let p = raw["plate"] {
            guard p.isRecord, let c = p["color"]?.stringValue else { return nil }
            if p["padding"] != nil && p["padding"]?.numberValue == nil { return nil }
            look.plate = Plate(color: c, padding: p["padding"]?.numberValue)
        }
        if let p = raw["position"] {
            guard let position = NativeCaptionPosition.parse(p) else { return nil }
            look.position = position
        }
        return look
    }
}

extension NativeCaptionPosition {
    /// A position read leniently: nil when a value has the wrong type (the validator names the problem).
    static func parse(_ raw: NativeJSONValue) -> NativeCaptionPosition? {
        guard raw.isRecord, let place = raw["place"]?.stringValue else { return nil }
        for key in ["x", "y"] where raw[key] != nil && raw[key]?.numberValue == nil { return nil }
        return NativeCaptionPosition(place: place, x: raw["x"]?.numberValue, y: raw["y"]?.numberValue)
    }
}

/// Validation of `sequence.captions.look` (NativeCaptionTrack): every bad value is an issue, nothing is clamped. A look
/// with a `v` other than 1 is kept and not validated further.
func validateNativeCaptionLook(_ look: NativeJSONValue?, _ path: String, _ issues: inout [NativeProjectDocumentValidationIssue]) {
    guard let look else { return }
    guard look.isRecord else { return pushIssue(&issues, .invalidCaption, path, "Caption look must be an object") }
    guard let v = look["v"]?.numberValue else { return pushIssue(&issues, .invalidCaption, "\(path).v", "Caption look v must be a number") }
    guard v == 1 else { return }
    func range(_ value: NativeJSONValue?, _ p: String, _ r: ClosedRange<Double>, _ what: String, whole: Bool = false) {
        guard let value else { return }
        let ok = value.numberValue.map { $0.isFinite && r.contains($0) && (!whole || $0 == $0.rounded()) } ?? false
        if !ok { pushIssue(&issues, .invalidCaption, p, "\(what) must be \(whole ? "a whole " : "a ")number from \(r.lowerBound) to \(r.upperBound)") }
    }
    func color(_ value: NativeJSONValue?, _ p: String) {
        if value?.stringValue.map(isNativeHexColor) != true { pushIssue(&issues, .invalidCaption, p, "Caption colors must be #RGB, #RRGGBB or #RRGGBBAA") }
    }
    if let family = look["fontFamily"], family.stringValue?.isEmpty != false {
        pushIssue(&issues, .invalidCaption, "\(path).fontFamily", "Caption font family must be a non-empty string")
    }
    range(look["size"], "\(path).size", NativeCaptionLook.sizeRange, "Caption size")
    range(look["weight"], "\(path).weight", NativeCaptionLook.weightRange, "Caption weight", whole: true)
    if look["color"] != nil { color(look["color"], "\(path).color") }
    range(look["safeArea"], "\(path).safeArea", NativeCaptionLook.safeAreaRange, "Caption safe area")
    range(look["maxWidth"], "\(path).maxWidth", NativeCaptionLook.maxWidthRange, "Caption maximum width")
    if let raw = look["outlines"] {
        guard let list = raw.arrayValue else { return pushIssue(&issues, .invalidCaption, "\(path).outlines", "Outlines must be an array") }
        if list.count > NativeCaptionLook.maxOutlines {
            pushIssue(&issues, .invalidCaption, "\(path).outlines", "A caption look has at most \(NativeCaptionLook.maxOutlines) outlines")
        }
        for (i, o) in list.enumerated() {
            let p = "\(path).outlines[\(i)]"
            guard o.isRecord else { pushIssue(&issues, .invalidCaption, p, "An outline must be an object"); continue }
            if o["width"] == nil { pushIssue(&issues, .invalidCaption, "\(p).width", "An outline needs a width") }
            range(o["width"], "\(p).width", NativeTextLook.outlineWidthRange, "Outline width")
            color(o["color"], "\(p).color")
            if let pos = o["position"], pos.stringValue.map(NativeTextLook.positions.contains) != true {
                pushIssue(&issues, .invalidCaption, "\(p).position", "Outline position must be one of \(NativeTextLook.positions.joined(separator: ", "))")
            }
        }
    }
    if let s = look["shadow"] {
        if s.isRecord {
            range(s["x"], "\(path).shadow.x", NativeTextLook.shadowOffsetRange, "Shadow x offset")
            range(s["y"], "\(path).shadow.y", NativeTextLook.shadowOffsetRange, "Shadow y offset")
            range(s["blur"], "\(path).shadow.blur", NativeTextLook.shadowBlurRange, "Shadow blur")
            color(s["color"], "\(path).shadow.color")
        } else {
            pushIssue(&issues, .invalidCaption, "\(path).shadow", "Shadow must be an object")
        }
    }
    if let p = look["plate"] {
        if p.isRecord {
            color(p["color"], "\(path).plate.color")
            range(p["padding"], "\(path).plate.padding", NativeCaptionLook.platePaddingRange, "Plate padding")
        } else {
            pushIssue(&issues, .invalidCaption, "\(path).plate", "Plate must be an object")
        }
    }
    validateNativeCaptionPosition(look["position"], "\(path).position", &issues)
}

/// Validation of a caption position (the track look's, or a cue's own): a known `place`, and for `custom` an `x` and `y`
/// from 0 to 1. `x` and `y` on `bottom` or `top` are refused, so a position has one meaning.
func validateNativeCaptionPosition(_ raw: NativeJSONValue?, _ path: String, _ issues: inout [NativeProjectDocumentValidationIssue]) {
    guard let raw else { return }
    guard raw.isRecord else { return pushIssue(&issues, .invalidCaption, path, "Caption position must be an object") }
    guard let place = raw["place"]?.stringValue, NativeCaptionPosition.places.contains(place) else {
        return pushIssue(&issues, .invalidCaption, "\(path).place", "Caption position place must be one of \(NativeCaptionPosition.places.joined(separator: ", "))")
    }
    for key in ["x", "y"] {
        let value = raw[key]
        if place == "custom" {
            if value?.numberValue.map({ $0.isFinite && (0.0...1.0).contains($0) }) != true {
                pushIssue(&issues, .invalidCaption, "\(path).\(key)", "A custom caption position needs \(key) as a number from 0 to 1")
            }
        } else if value != nil {
            pushIssue(&issues, .invalidCaption, "\(path).\(key)", "Only a custom caption position has \(key)")
        }
    }
}
