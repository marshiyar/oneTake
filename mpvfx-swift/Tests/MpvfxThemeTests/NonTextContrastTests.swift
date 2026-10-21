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

/// WCAG 2.2 SC 1.4.11 Non-text Contrast (Level AA): "visual information required to identify user interface
/// components and states" has a contrast ratio of at least 3:1 against adjacent colours
/// (https://www.w3.org/TR/WCAG22/#non-text-contrast; docs/DESIGN.md "Accessibility floors"). Checked here on the tokens, beside the text
/// checks of `ThemeTokensTests.testLightTextContrastIsAA` and `VisualSpecTests.testDarkTextContrast`.
///
/// Each role names the token that carries a state or a control's shape and the surfaces it is drawn on or next to
/// (docs/DESIGN.md "Colour tokens" and "Checking a change"). A pair below 3:1 fails unless it is listed in
/// `knownBelow`, the ratchet of today's findings: an entry is removed when the pair is fixed (the test fails while a
/// listed pair passes, so the list only shrinks) and is never added to make a change pass.
final class NonTextContrastTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark) }

    static let minimum = 3.0

    /// Every surface a control sits on: panel bodies, grouped rows, fields, raised controls, the hover wash, popovers
    /// and the timeline.
    static let surfaces: [(String, ThemePair)] = [
        ("panelBg", T.panelBgPair), ("panelBgInset", T.panelBgInsetPair), ("panelInput", T.panelInputPair),
        ("panelSurface", T.panelSurfacePair), ("panelHover", T.panelHoverPair), ("popover", T.popoverPair),
        ("timelineSurface", T.timelineSurfacePair), ("timelineRow", T.timelineRowPair), ("timelineGutter", T.timelineGutterPair),
    ]
    static func on(_ names: [String]) -> [(String, ThemePair)] { surfaces.filter { names.contains($0.0) } }

    /// (role, the token that draws it, the surfaces next to it).
    static let roles: [(role: String, token: ThemePair, against: [(String, ThemePair)])] = [
        // The 2 px keyboard focus ring (`PanelDraw.focusRing`): drawn just outside any focused control, on any surface.
        ("focusRing", T.studioAccentPair, surfaces),
        // Selection and the active state: the active tab's underline, a selected row, a changed value, an on toggle.
        ("selected", T.studioAccentPair, surfaces),
        // The accent's line form: the playhead, drop slots and timeline highlights.
        ("playhead", T.mintPair, on(["timelineSurface", "timelineRow", "timelineGutter", "panelBg"])),
        // Filled accent controls: the slider fill's edge and active toggles, on their tracks and rows.
        ("accentEdge", T.accentEdgePair, on(["panelBg", "panelBgInset", "panelInput", "panelSurface", "panelHover", "popover"])),
        // Signals with a fixed meaning (docs/DESIGN.md principle 2): errors, recording and cutting, beat markers.
        ("danger", T.dangerPair, surfaces),
        ("record", T.red400Pair, surfaces),
        ("beatMarker", T.green500Pair, on(["timelineSurface", "timelineRow", "timelineGutter"])),
        // A field's outline (`panelBorderInput`) between the field and the panel around it: an empty field with no
        // placeholder is found only by its boundary.
        ("fieldOutline", T.panelBorderInputPair, on(["panelInput", "panelBg", "panelBgInset", "popover"])),
    ]

    /// Pairs below 3:1 at this revision (measured from the tokens; ratio in the comment). The field outline is the
    /// design's quiet `#333333` / `#B4B4BC` line; raising it is a visible palette change for its own pull request.
    static let knownBelow: Set<String> = [
        "accentEdge on panelHover (dark)",       // 2.85
        "fieldOutline on panelInput (dark)",     // 1.53
        "fieldOutline on panelBg (dark)",        // 1.33
        "fieldOutline on panelBgInset (dark)",   // 1.39
        "fieldOutline on popover (dark)",        // 1.21
        "fieldOutline on panelInput (light)",    // 2.06
        "fieldOutline on panelBg (light)",       // 1.97
        "fieldOutline on panelBgInset (light)",  // 1.87
        "fieldOutline on popover (light)",       // 2.06
    ]

    /// Every (role, surface, mode) pair below the minimum, as "role on surface (mode)" with its ratio.
    static func belowMinimum() -> [(key: String, ratio: Double)] {
        var out: [(key: String, ratio: Double)] = []
        for r in roles { for (name, surface) in r.against { for m in ThemeMode.allCases {
            let ratio = r.token.value(m).contrast(surface.value(m))
            if ratio < minimum { out.append(("\(r.role) on \(name) (\(m.rawValue))", ratio)) }
        } } }
        return out
    }

    func testStatesAndControlBoundariesReachThreeToOne() {
        let found = Self.belowMinimum()
        let keys = Set(found.map { $0.key })
        let new = found.filter { !Self.knownBelow.contains($0.key) }
            .map { "\($0.key): \((($0.ratio * 100).rounded() / 100))" }.sorted()
        XCTAssertEqual(new, [], "below 3:1 (WCAG 2.2 SC 1.4.11); fix the token, do not list it:\n" + new.joined(separator: "\n"))
        let fixed = Self.knownBelow.subtracting(keys).sorted()
        XCTAssertEqual(fixed, [], "these pairs now reach 3:1; remove them from knownBelow:\n" + fixed.joined(separator: "\n"))
    }

    /// The check itself: every role names at least one surface, the ratio is WCAG's, and a pair the eye cannot tell
    /// apart is caught while black on white is not.
    func testTheCheckMeasuresWhatItClaims() {
        XCTAssertTrue(Self.roles.allSatisfy { !$0.against.isEmpty })
        XCTAssertEqual(Self.roles.count, Set(Self.roles.map { $0.role }).count, "role names are unique")
        XCTAssertLessThan(ThemeColor(0x333333).contrast(ThemeColor(0x1D1D1D)), Self.minimum)
        XCTAssertGreaterThanOrEqual(ThemeColor(0x000000).contrast(ThemeColor(0xFFFFFF)), Self.minimum)
        XCTAssertEqual(ThemeColor(0x767676).contrast(ThemeColor(0xFFFFFF)), 4.54, accuracy: 0.01)   // WCAG's 4.5:1 grey
    }
}
