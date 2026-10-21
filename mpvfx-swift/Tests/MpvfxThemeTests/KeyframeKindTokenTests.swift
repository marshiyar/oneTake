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
import XCTest
@testable import MpvfxTheme

/// #201: the six keyframe-kind colours stay readable as marks (WCAG 2.x non-text contrast, 3:1) on every surface
/// they are drawn on, in dark and light, and stay apart from each other under simulated colour-vision deficiency.
/// The shape carries the kind, so these checks keep the colour a reliable second cue rather than the only one.
final class KeyframeKindTokenTests: XCTestCase {
    static let kinds: [(name: String, pair: ThemePair)] = [
        ("transform", ThemeTokens.keyframeTransformPair), ("3d", ThemeTokens.keyframe3DPair),
        ("opacity", ThemeTokens.keyframeOpacityPair), ("color", ThemeTokens.keyframeColorPair),
        ("effect", ThemeTokens.keyframeEffectPair), ("audio", ThemeTokens.keyframeAudioPair),
    ]

    /// `ink` at `alpha` over the opaque `base`.
    static func over(_ ink: ThemeColor, _ alpha: Double, _ base: ThemeColor) -> ThemeColor {
        ThemeColor(r: ink.r * alpha + base.r * (1 - alpha), g: ink.g * alpha + base.g * (1 - alpha), b: ink.b * alpha + base.b * (1 - alpha))
    }

    /// Every surface a mark sits on in `mode`: the lane row (its 2.5 % property wash and 4.5 % summary wash), the
    /// track header column, and the inspector row.
    static func surfaces(_ mode: ThemeMode) -> [(String, ThemeColor)] {
        let row = ThemeTokens.timelineRowPair.value(mode), ink = ThemeTokens.whitePair.value(mode)
        return [("lane", over(ink, 0.025, row)), ("summary lane", over(ink, 0.045, row)), ("row", row),
                ("gutter", ThemeTokens.timelineGutterPair.value(mode)), ("inspector", ThemeTokens.panelBgInsetPair.value(mode))]
    }

    func testEveryKindColourHasThreeToOneOnEverySurfaceInBothModes() {
        let checks = [ThemeMode.dark, .light].flatMap { mode in
            Self.kinds.flatMap { kind in Self.surfaces(mode).map { ("\(kind.name) on \($0.0) (\(mode))", kind.pair.value(mode).contrast($0.1)) } }
        }
        XCTAssertEqual(checks.filter { $0.1 < 3 }.map(\.0), [], "below 3:1")
    }

    // MARK: Colour-vision deficiency

    /// Machado, Oliveira and Fernandes (2009), "A Physiologically-based Model for Simulation of Color Vision
    /// Deficiency", IEEE TVCG 15(6), doi:10.1109/TVCG.2009.113, severity 1.0 matrices on linear RGB
    /// (https://www.inf.ufrgs.br/~oliveira/pubs_files/CVD_Simulation/CVD_Simulation.html; values as transcribed in
    /// colorspacious 1.1.2 `cvd.py`).
    static let machado: [String: [[Double]]] = [
        "protanopia": [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]],
        "deuteranopia": [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881]],
        "tritanopia": [[1.255528, -0.076749, -0.178779], [-0.078411, 0.930809, 0.147602], [0.004733, 0.691367, 0.303900]],
    ]

    /// CIE L*a*b* (D65) of a colour after the optional simulation matrix.
    static func lab(_ c: ThemeColor, _ m: [[Double]]?) -> [Double] {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let v = [lin(c.r), lin(c.g), lin(c.b)]
        let s = m.map { m in m.map { row in min(1, max(0, row[0] * v[0] + row[1] * v[1] + row[2] * v[2])) } } ?? v
        let x = 0.4124 * s[0] + 0.3576 * s[1] + 0.1805 * s[2], y = 0.2126 * s[0] + 0.7152 * s[1] + 0.0722 * s[2]
        let z = 0.0193 * s[0] + 0.1192 * s[1] + 0.9505 * s[2]
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        let fx = f(x / 0.95047), fy = f(y), fz = f(z / 1.08883)
        return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)]
    }

    /// Smallest CIE76 ΔE between two kinds' colours in `mode` under `simulation` (nil: normal vision).
    static func closestPair(_ mode: ThemeMode, _ simulation: [[Double]]?) -> (distance: Double, pair: String) {
        var best = (distance: Double.infinity, pair: "")
        for i in kinds.indices {
            for j in kinds.indices where j > i {
                let a = lab(kinds[i].pair.value(mode), simulation), b = lab(kinds[j].pair.value(mode), simulation)
                let d = sqrt(zip(a, b).map { ($0 - $1) * ($0 - $1) }.reduce(0, +))
                if d < best.distance { best = (d, "\(kinds[i].name)/\(kinds[j].name)") }
            }
        }
        return best
    }

    func testKindColoursStayApartForNormalAndDeficientVision() {
        // Normal vision: clearly different hues (ΔE ≥ 25). Simulated dichromacy: still separable (ΔE ≥ 9; the
        // closest pairs measured 9.9 tritan in dark and 10.3 protan in light when these values were chosen).
        let modes = [ThemeMode.dark, .light]
        let normal = modes.map { Self.closestPair($0, nil) }
        XCTAssertEqual(normal.filter { $0.distance < 25 }.map(\.pair), [], "normal vision")
        let simulated = modes.flatMap { mode in Self.machado.map { (name: "\(mode) \($0.key)", closest: Self.closestPair(mode, $0.value)) } }
        XCTAssertEqual(simulated.filter { $0.closest.distance < 9 }.map { "\($0.name): \($0.closest.pair) \($0.closest.distance)" }, [])
    }
}
