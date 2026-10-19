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

extension ThemeColor {
    /// The hue/saturation/lightness colour `hsl(h, s%, l%)` (h in degrees, s and l 0…1).
    public init(hue h: Double, saturation s: Double, lightness l: Double, alpha: Double = 1) {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double)
        switch hp {
        case ..<1: (r1, g1, b1) = (c, x, 0)
        case ..<2: (r1, g1, b1) = (x, c, 0)
        case ..<3: (r1, g1, b1) = (0, c, x)
        case ..<4: (r1, g1, b1) = (0, x, c)
        case ..<5: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        let m = l - c / 2
        self.init(r: r1 + m, g: g1 + m, b: b1 + m, a: alpha)
    }
}

/// The Audio FX rack's hues (preset style and FX family). Dark values are the original
/// hsl() colours exactly; light values are derived: the same hue taken darker until it holds
/// 3:1 against the light inset panel (it marks an edge, the WCAG non-text minimum), and the washes behind a preset
/// bracket go near-white instead of near-black so the light ink keeps AA on them.
extension ThemeTokens {
    public struct FxHue: Sendable { public let h: Double, s: Double, l: Double }

    /// Each preset's title colour (also its bracket's left edge), as hsl().
    public static let fxPresetHues: [String: FxHue] = [
        "voice-clean": FxHue(h: 202, s: 0.82, l: 0.66), "voice-broadcast": FxHue(h: 214, s: 0.84, l: 0.70),
        "voice-warm": FxHue(h: 32, s: 0.88, l: 0.66),
        "rumble-cut": FxHue(h: 196, s: 0.78, l: 0.64), "room-gate": FxHue(h: 196, s: 0.78, l: 0.64),
        "boom-tame": FxHue(h: 196, s: 0.78, l: 0.64), "harsh-tame": FxHue(h: 196, s: 0.78, l: 0.64),
        "telephone": FxHue(h: 186, s: 0.85, l: 0.62), "radio-am": FxHue(h: 42, s: 0.92, l: 0.62),
        "megaphone": FxHue(h: 12, s: 0.90, l: 0.64), "lofi-tape": FxHue(h: 28, s: 0.72, l: 0.62),
        "pa-system": FxHue(h: 222, s: 0.80, l: 0.70), "intercom": FxHue(h: 96, s: 0.68, l: 0.60),
        "doofus-worble": FxHue(h: 288, s: 0.85, l: 0.72), "chipmunk": FxHue(h: 54, s: 0.88, l: 0.66),
        "giant": FxHue(h: 250, s: 0.72, l: 0.68), "monster": FxHue(h: 350, s: 0.78, l: 0.64),
        "room-tight": FxHue(h: 252, s: 0.74, l: 0.72), "room-natural": FxHue(h: 258, s: 0.78, l: 0.72),
        "hall": FxHue(h: 246, s: 0.84, l: 0.74), "slap-echo": FxHue(h: 274, s: 0.76, l: 0.70),
        "dub-throw": FxHue(h: 312, s: 0.78, l: 0.70),
    ]
    /// FX_PRESET_STYLE_DEFAULT's colour, for a preset with no entry.
    public static let fxPresetDefaultHue = FxHue(h: 220, s: 0.24, l: 0.72)

    /// The same hue made dark enough to hold `ratio` against `bg` (light mode's edge colour).
    static func darkened(_ hue: FxHue, against bg: ThemeColor, ratio: Double) -> ThemeColor {
        var l = hue.l
        var c = ThemeColor(hue: hue.h, saturation: hue.s, lightness: l)
        while c.contrast(bg) < ratio && l > 0.05 { l -= 0.01; c = ThemeColor(hue: hue.h, saturation: hue.s, lightness: l) }
        return c
    }
    static func edgePair(_ hue: FxHue) -> ThemePair {
        ThemePair(ThemeColor(hue: hue.h, saturation: hue.s, lightness: hue.l), darkened(hue, against: panelBgInsetPair.light, ratio: 3))
    }

    /// A preset bracket's left edge.
    public static func fxPresetEdgePair(_ presetId: String) -> ThemePair { edgePair(fxPresetHues[presetId] ?? fxPresetDefaultHue) }
    /// The wash behind a preset bracket (fxPresetBackground: the hue at 22% saturation, 11% lightness); nil for a
    /// preset with no character of its own. Light: the hue at 45% saturation, 94% lightness.
    public static func fxPresetWashPair(_ presetId: String) -> ThemePair? {
        guard let hue = fxPresetHues[presetId] else { return nil }
        return ThemePair(ThemeColor(hue: hue.h, saturation: 0.22, lightness: 0.11), ThemeColor(hue: hue.h, saturation: 0.45, lightness: 0.94))
    }

    /// FAMILY_HUE (filter, dynamics, nonlinear, time, smart).
    public static let fxFamilyHues: [String: Double] = ["filter": 205, "dynamics": 25, "nonlinear": 310, "time": 165, "smart": 95]
    /// A module's tint (fxFamilyTint): its family's hue at 32% saturation, lightness 62%…76% by `step` (0…1, its
    /// place among its family's siblings in the registry).
    public static func fxFamilyTintPair(_ family: String, step: Double) -> ThemePair {
        edgePair(FxHue(h: fxFamilyHues[family] ?? fxFamilyHues["filter"]!, s: 0.32, l: (62 + max(0, min(1, step)) * 14) / 100))
    }
}
