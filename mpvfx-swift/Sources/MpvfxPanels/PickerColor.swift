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
import MpvfxShared

/// A colour as the picker edits it: hue (0..<360), saturation, value and alpha (0…1). The picker keeps HSV so a
/// drag through grey or black keeps its hue; the document stores the hex `hex(allowAlpha:)` writes.
public struct PickerColor: Equatable, Sendable {
    public var hue: Double, saturation: Double, value: Double, alpha: Double

    public init(hue: Double, saturation: Double, value: Double, alpha: Double = 1) {
        self.hue = Self.wrapHue(hue)
        self.saturation = Self.unit(saturation); self.value = Self.unit(value); self.alpha = Self.unit(alpha)
    }

    /// `#rgb`, `#rrggbb` or `#rrggbbaa` (the `#` optional, any case); nil for anything else.
    public init?(hex: String) {
        guard let n = normalizedHexColor(hex) else { return nil }
        let body = Array(n.dropFirst())
        func byte(_ i: Int) -> Double? { UInt8(String(body[i..<i + 2]), radix: 16).map { Double($0) / 255 } }
        guard let r = byte(0), let g = byte(2), let b = byte(4) else { return nil }
        let a = body.count == 8 ? byte(6) : 1
        guard let a else { return nil }
        self = Self.fromRGB(r, g, b, alpha: a)
    }

    static func fromRGB(_ r: Double, _ g: Double, _ b: Double, alpha: Double) -> PickerColor {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = 60 * ((b - r) / d + 2) }
            else { h = 60 * ((r - g) / d + 4) }
        }
        return PickerColor(hue: h, saturation: mx > 0 ? d / mx : 0, value: mx, alpha: alpha)
    }

    /// The colour as 0…1 red, green and blue.
    public var rgb: (r: Double, g: Double, b: Double) { Self.rgb(hue: hue, saturation: saturation, value: value) }

    static func rgb(hue: Double, saturation s: Double, value v: Double) -> (r: Double, g: Double, b: Double) {
        let c = v * s, hp = wrapHue(hue) / 60, x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        let (r, g, b): (Double, Double, Double)
        switch Int(hp) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return (r + m, g + m, b + m)
    }

    /// Lowercase `#rrggbb`, or `#rrggbbaa` when `allowAlpha` and the alpha byte is below 255 (what `project.json`
    /// stores and the renderer reads).
    public func hex(allowAlpha: Bool) -> String {
        let (r, g, b) = rgb
        let bytes = [r, g, b].map { Self.byte($0) }
        let a = Self.byte(alpha)
        var s = "#" + bytes.map { String(format: "%02x", $0) }.joined()
        if allowAlpha && a < 255 { s += String(format: "%02x", a) }
        return s
    }

    static func byte(_ v: Double) -> Int { Int((unit(v) * 255).rounded()) }
    static func unit(_ v: Double) -> Double { v.isFinite ? min(1, max(0, v)) : 0 }
    static func wrapHue(_ h: Double) -> Double {
        guard h.isFinite else { return 0 }
        let w = h.truncatingRemainder(dividingBy: 360)
        return w < 0 ? w + 360 : w
    }
}
