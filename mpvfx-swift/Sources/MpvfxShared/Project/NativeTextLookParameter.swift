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

/// The text look values a layer can animate: the width of each outline, the shadow offset and blur, the glow
/// strength, the plate opacity (the alpha of its colour) and the gradient angle. A value lives
/// in `clip.text.look` while it is not animated, and in a clip parameter track with the id below once it is; the
/// preview and the export read the track at the frame being drawn (`applying`), so both draw the same look.
public enum NativeTextLookParameter {
    public static let outlineWidthIds = (0..<NativeTextLook.maxOutlines).map { "text.look.outline.\($0).width" }
    public static let shadowXId = "text.look.shadow.x"
    public static let shadowYId = "text.look.shadow.y"
    public static let shadowBlurId = "text.look.shadow.blur"
    public static let glowStrengthId = "text.look.glow.strength"
    public static let plateOpacityId = "text.look.plate.opacity"
    public static let fillAngleId = "text.look.fill.angle"
    public static let all: [String] = outlineWidthIds + [shadowXId, shadowYId, shadowBlurId, glowStrengthId, plateOpacityId, fillAngleId]

    public static func isTextLookParameter(_ id: String) -> Bool { all.contains(id) }

    /// The document's range for the value; animated values are held to it when drawn.
    public static func range(of id: String) -> ClosedRange<Double>? {
        switch id {
        case _ where outlineWidthIds.contains(id): return NativeTextLook.outlineWidthRange
        case shadowXId, shadowYId: return NativeTextLook.shadowOffsetRange
        case shadowBlurId: return NativeTextLook.shadowBlurRange
        case glowStrengthId: return NativeTextLook.glowStrengthRange
        case plateOpacityId: return 0...1
        case fillAngleId: return NativeTextLook.fillAngleRange
        default: return nil
        }
    }

    /// The value the look holds, or nil when the look has no such part (no second outline, no shadow).
    public static func value(of id: String, in look: NativeTextLook?) -> Double? {
        guard let look, look.isSupported else { return nil }
        if let index = outlineWidthIds.firstIndex(of: id) {
            guard let outlines = look.outlines, outlines.indices.contains(index) else { return nil }
            return outlines[index].width
        }
        switch id {
        case glowStrengthId: return look.glow?.resolvedStrength
        case plateOpacityId: return look.plate.flatMap { opacity(ofColor: $0.color) }
        case fillAngleId: return look.fill?.resolvedAngle
        default: break
        }
        guard let shadow = look.shadow else { return nil }
        switch id {
        case shadowXId: return shadow.resolvedX
        case shadowYId: return shadow.resolvedY
        case shadowBlurId: return shadow.resolvedBlur
        default: return nil
        }
    }

    /// The alpha (0…1) of `#RGB`, `#RRGGBB` or `#RRGGBBAA`; nil for anything else.
    public static func opacity(ofColor color: String) -> Double? {
        let digits = color.hasPrefix("#") ? String(color.dropFirst()) : color
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        switch digits.count {
        case 3, 6: return 1
        case 8: return UInt8(digits.suffix(2), radix: 16).map { Double($0) / 255 }
        default: return nil
        }
    }

    /// `color` with its alpha set to `opacity`, as `#RRGGBB` when opaque and `#RRGGBBAA` otherwise.
    public static func color(_ color: String, opacity: Double) -> String? {
        var digits = color.hasPrefix("#") ? String(color.dropFirst()) : color
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 || digits.count == 8 else { return nil }
        let rgb = digits.prefix(6).lowercased()
        let alpha = Int((min(max(opacity, 0), 1) * 255).rounded())
        return alpha == 255 ? "#\(rgb)" : "#\(rgb)" + String(format: "%02x", alpha)
    }

    /// The look with the value stored, held to its range; nil when the look has no such part.
    public static func setting(_ value: Double, id: String, in look: NativeTextLook?) -> NativeTextLook? {
        guard var next = look, next.isSupported, let range = range(of: id), value.isFinite else { return nil }
        let held = min(max(value, range.lowerBound), range.upperBound)
        if let index = outlineWidthIds.firstIndex(of: id) {
            guard next.outlines?.indices.contains(index) == true else { return nil }
            next.outlines?[index].width = held
            return next
        }
        switch id {
        case glowStrengthId:
            guard var glow = next.glow else { return nil }
            glow.strength = held == NativeTextLook.defaultGlowStrength ? nil : held
            next.glow = glow
            return next
        case plateOpacityId:
            guard var plate = next.plate, let tinted = Self.color(plate.color, opacity: held) else { return nil }
            plate.color = tinted
            next.plate = plate
            return next
        case fillAngleId:
            guard var fill = next.fill else { return nil }
            fill.angle = held == 0 ? nil : held
            next.fill = fill
            return next
        default: break
        }
        guard var shadow = next.shadow else { return nil }
        // A default value is stored as an absent key, so a look that never animated saves as before.
        let stored: Double? = held == 0 ? nil : held
        switch id {
        case shadowXId: shadow.x = stored
        case shadowYId: shadow.y = stored
        default: shadow.blur = stored
        }
        next.shadow = shadow
        return next
    }

    /// The parameter ids of one look part, for removing its tracks together with the part.
    public static func ids(ofOutline index: Int) -> [String] { outlineWidthIds.indices.contains(index) ? [outlineWidthIds[index]] : [] }
    public static let shadowIds = [shadowXId, shadowYId, shadowBlurId]
    public static let glowIds = [glowStrengthId]
    public static let plateIds = [plateOpacityId]
    public static let fillIds = [fillAngleId]

    /// The text as drawn at one moment: every animated look value in `values` (a clip's parameters at that frame)
    /// replaces the stored one. Values for a part the look does not have are ignored.
    public static func applying(_ values: [String: NativeParameterValue], to text: NativeClipText) -> NativeClipText {
        guard var look = text.look, look.isSupported else { return text }
        var changed = false
        for id in all {
            guard case .number(let value)? = values[id], let next = setting(value, id: id, in: look) else { continue }
            look = next; changed = true
        }
        guard changed else { return text }
        var out = text
        out.look = look
        return out
    }
}
