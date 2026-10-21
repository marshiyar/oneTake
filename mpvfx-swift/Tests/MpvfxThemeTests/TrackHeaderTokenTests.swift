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

/// The compact track header's tokens (docs/DESIGN.md step 4) on the header surface, in both modes: WCAG 2.2 AA,
/// 4.5:1 for text and 3:1 for a control's glyph.
final class TrackHeaderTokenTests: XCTestCase {
    typealias T = ThemeTokens

    func check(_ name: String, _ ink: ThemePair, on surface: ThemePair, atLeast ratio: Double) {
        for mode in [ThemeMode.dark, .light] {
            let got = ink.value(mode).contrast(surface.value(mode))
            XCTAssertGreaterThanOrEqual(got, ratio, "\(name) \(mode): \(got)")
        }
    }

    func testHeaderInksMeetAAOnTheGutter() {
        check("idle control", T.trackControlIdlePair, on: T.timelineGutterPair, atLeast: 3)
        check("idle control under the pointer", T.trackControlIdlePair, on: T.trackControlHoverPair, atLeast: 3)
        check("control that is on", T.mintPair, on: T.timelineGutterPair, atLeast: 3)
        check("control that is on, under the pointer", T.mintPair, on: T.trackControlHoverPair, atLeast: 3)
        check("untargeted tag text", T.trackTagTextPair, on: T.timelineGutterPair, atLeast: 4.5)
        check("targeted tag text", T.onAccentMintPair, on: T.mintPair, atLeast: 4.5)
        check("targeted tag against the gutter", T.mintPair, on: T.timelineGutterPair, atLeast: 3)
    }

    /// The outline's and the text's contrast on the gutter in `mode`.
    func tagContrast(_ mode: ThemeMode) -> (outline: Double, text: Double) {
        let gutter = T.timelineGutterPair.value(mode)
        return (T.trackTagOutlinePair.value(mode).contrast(gutter), T.trackTagTextPair.value(mode).contrast(gutter))
    }

    func testUntargetedTagOutlineIsVisibleButQuieterThanItsText() {
        let dark = tagContrast(.dark), light = tagContrast(.light)
        XCTAssertGreaterThan(dark.outline, 1.3, "dark outline \(dark.outline)")
        XCTAssertGreaterThan(light.outline, 1.3, "light outline \(light.outline)")
        XCTAssertLessThan(dark.outline, dark.text)
        XCTAssertLessThan(light.outline, light.text)
    }
}
