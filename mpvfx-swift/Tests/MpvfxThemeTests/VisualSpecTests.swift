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
import XCTest
@testable import MpvfxTheme

private typealias T = ThemeTokens

/// docs/DESIGN.md is the visual spec: its token table, one accent, neutral surfaces and readable text.
final class VisualSpecTests: XCTestCase {
    static let doc = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("docs/DESIGN.md")

    /// The tokens the spec's table names.
    static let tokens: [String: ThemePair] = [
        "studioBg": T.studioBgPair, "panelBg": T.panelBgPair, "panelBgInset": T.panelBgInsetPair, "panelInput": T.panelInputPair,
        "panelSurface": T.panelSurfacePair, "panelHover": T.panelHoverPair, "panelBorder": T.panelBorderPair,
        "panelBorderInput": T.panelBorderInputPair, "panelHairline": T.panelHairlinePair, "popover": T.popoverPair,
        "timelineSurface": T.timelineSurfacePair, "timelineRow": T.timelineRowPair, "timelineGutter": T.timelineGutterPair,
        "viewport": T.viewportPair, "studioAccent": T.studioAccentPair, "mint": T.mintPair, "accentEdge": T.accentEdgePair,
        "clipVideo": T.clipVideoPair, "clipVideoHover": T.clipVideoHoverPair, "clipAudio": T.clipAudioPair,
        "clipAudioHover": T.clipAudioHoverPair, "waveform": T.waveformPair,
    ]

    /// `| \`name\` | \`#RRGGBB\` | ... |` rows of the colour table.
    static func specRows() throws -> [String: ThemeColor] {
        let text = try String(contentsOf: doc, encoding: .utf8)
        let row = try NSRegularExpression(pattern: #"^\| `(\w+)` \| `#([0-9A-Fa-f]{6})` \|"#, options: .anchorsMatchLines)
        var out: [String: ThemeColor] = [:]
        for m in row.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let n = Range(m.range(at: 1), in: text), let h = Range(m.range(at: 2), in: text) else { continue }
            out[String(text[n])] = ThemeColor(UInt32(text[h], radix: 16)!)
        }
        return out
    }

    func testTheTokensAreTheSpecsValues() throws {
        let spec = try Self.specRows()
        XCTAssertEqual(Set(spec.keys), Set(Self.tokens.keys), "the spec's table and this test name the same tokens")
        for (name, value) in spec.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(Self.tokens[name]?.dark, value, "\(name): ThemeTokens.swift and docs/DESIGN.md disagree")
        }
    }

    /// Hue in degrees (0..<360) and saturation (0...1, HSV) of an opaque colour.
    static func hueSat(_ c: ThemeColor) -> (hue: Double, sat: Double) {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b), d = mx - mn
        guard d > 0 else { return (0, 0) }
        var h: Double
        if mx == c.r { h = (c.g - c.b) / d } else if mx == c.g { h = (c.b - c.r) / d + 2 } else { h = (c.r - c.g) / d + 4 }
        h *= 60; if h < 0 { h += 360 }
        return (h, d / mx)
    }

    /// Principle 2: the chrome has one accent. Every accent token is the same blue in both modes.
    func testOneAccentHue() {
        for m in ThemeMode.allCases {
            let hues = [T.studioAccentPair, T.mintPair, T.accentEdgePair].map { Self.hueSat($0.value(m)) }
            for (h, s) in hues {
                XCTAssertEqual(h, 216, accuracy: 12, "\(m) accent hue \(h)")
                XCTAssertGreaterThan(s, 0.5, "\(m) accent is a colour, not a grey")
            }
        }
    }

    /// Principle 1: the panel surfaces are neutral grey (no tint), dark, and step in a narrow range so they read as
    /// one surface; the shell behind them is darker than every panel so the seams show.
    func testSurfacesAreOneNeutralGrey() {
        let surfaces = [T.panelBgPair, T.panelBgInsetPair, T.panelInputPair, T.panelSurfacePair, T.panelHoverPair,
                        T.popoverPair, T.timelineSurfacePair, T.timelineRowPair, T.timelineGutterPair, T.viewportPair].map(\.dark)
        for s in surfaces {
            XCTAssertEqual(s.r, s.g, accuracy: 1e-9); XCTAssertEqual(s.g, s.b, accuracy: 1e-9)
            XCTAssertLessThan(s.r, 0.2, "dark surface")
        }
        XCTAssertLessThan(surfaces.map(\.r).max()! - surfaces.map(\.r).min()!, 0.12, "surfaces stay within a narrow band")
        XCTAssertTrue(surfaces.allSatisfy { $0.relativeLuminance > T.studioBgPair.dark.relativeLuminance }, "seams are darker than panels")
        XCTAssertEqual(T.panelBgPair.dark, T.timelineSurfacePair.dark, "panels and the timeline are the same grey")
    }

    /// Principle 6: text is readable on every dark surface it is drawn on.
    func testDarkTextContrast() {
        let surfaces = [T.panelBgPair, T.panelBgInsetPair, T.panelInputPair, T.panelSurfacePair, T.popoverPair,
                        T.timelineSurfacePair, T.timelineRowPair, T.timelineGutterPair].map(\.dark)
        func worst(_ p: ThemePair) -> Double { surfaces.map { p.dark.contrast($0) }.min()! }
        for (name, p) in [("text0", T.textPairs[0]), ("text1", T.textPairs[1]), ("text2", T.textPairs[2]),
                          ("accent", T.studioAccentPair), ("mint", T.mintPair), ("red400", T.red400Pair)] {
            XCTAssertGreaterThanOrEqual(worst(p), 4.5, "\(name) body text reaches AA")
        }
        for (name, p) in [("text3", T.textPairs[3]), ("studioMuted", T.studioMutedPair)] {
            XCTAssertGreaterThanOrEqual(worst(p), 3, "\(name) muted text reaches 3:1")
        }
    }

    /// Principle 3: clips are coloured by kind. Video and audio differ in hue, their labels read on them in both
    /// modes, hover is visibly different, and the waveform stands out on an audio clip.
    func testClipsAreColouredByKind() {
        for m in ThemeMode.allCases {
            let video = T.clipVideoPair.value(m), audio = T.clipAudioPair.value(m), ink = T.whitePair.value(m)
            XCTAssertGreaterThan(abs(Self.hueSat(video).hue - Self.hueSat(audio).hue), 60, "\(m) video and audio differ in hue")
            XCTAssertGreaterThanOrEqual(ink.contrast(video), 4.5, "\(m) clip label on video")
            XCTAssertGreaterThanOrEqual(ink.contrast(audio), 4.5, "\(m) clip label on audio")
            XCTAssertNotEqual(T.clipVideoHoverPair.value(m), video); XCTAssertNotEqual(T.clipAudioHoverPair.value(m), audio)
            XCTAssertGreaterThanOrEqual(T.waveformPair.value(m).contrast(audio), 2, "\(m) waveform on an audio clip")
        }
    }

    /// The editor is dark until the user picks an appearance.
    func testDefaultAppearanceIsDark() {
        XCTAssertEqual(ThemeAppearance.default, .dark)
        XCTAssertEqual(ThemeAppearance(preference: nil).resolve(systemPrefersDark: false), .dark)
    }
}
