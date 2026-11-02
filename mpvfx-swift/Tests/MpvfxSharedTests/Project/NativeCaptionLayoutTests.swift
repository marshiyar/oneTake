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
@testable import MpvfxShared

/// `nativeCaptionLayout` (NativeCaptionLayout.swift): the default look, wrapping, the safe area, the plate, the reach of
/// outlines and shadow, a cue's own position, unsupported looks and degenerate frames. The measure is a fixed advance of
/// half a font size per character, so every expected number is worked out by hand in the comment above its test.
///
/// Constants used throughout: a 1920x1080 frame has short edge 1080, so fontSize = 0.06 * 1080 = 64.8, lineHeight =
/// 64.8 * 1.2 = 77.76, safe margin = 0.05 * 1080 = 54. A character is 64.8 * 0.5 = 32.4 px wide.
final class NativeCaptionLayoutTests: XCTestCase {
    /// Half a font size per character.
    let fixedAdvance: (String, Double) -> Double = { text, size in Double(text.count) * size * 0.5 }

    func layout(_ text: String, look: NativeCaptionLook? = nil, position: NativeCaptionPosition? = nil,
                width: Double = 1920, height: Double = 1080) -> NativeCaptionLayout {
        nativeCaptionLayout(text: text, look: look, position: position, frameWidth: width, frameHeight: height,
                            measure: fixedAdvance)
    }

    /// `count` words of 10 characters, joined by single spaces.
    func words(_ count: Int) -> String { Array(repeating: "abcdefghij", count: count).joined(separator: " ") }

    /// A word of `count` x's, with no spaces.
    func xs(_ count: Int) -> String { String(repeating: "x", count: count) }

    func assertRect(_ r: NativeCaptionRect, _ x: Double, _ y: Double, _ w: Double, _ h: Double,
                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.x, x, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(r.y, y, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(r.width, w, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(r.height, h, accuracy: 1e-6, file: file, line: line)
    }

    // (1) Default look on 1920x1080.
    // fontSize = 0.06 * 1080 = 64.8; lineHeight = 64.8 * 1.2 = 77.76; no plate, no reach, so no padding.
    // safeRect = (54, 54, 1920 - 108, 1080 - 108) = (54, 54, 1812, 972).
    // Wrap limit = min(0.8 * 1920 = 1536, usable width 1812) = 1536. "Hello" = 5 * 32.4 = 162 px, one line.
    // Centred: x = 960 - 162 / 2 = 879. Bottom: y = (54 + 972) - 77.76 = 948.24, so the bottom edge is 948.24 + 77.76
    // = 1026 = 1080 - 54.
    func testDefaultLookOnALandscapeFrame() {
        let l = layout("Hello")
        XCTAssertEqual(l.fontSize, 64.8, accuracy: 1e-9)
        XCTAssertEqual(l.lineHeight, 77.76, accuracy: 1e-9)
        XCTAssertEqual(l.lines, ["Hello"])
        XCTAssertFalse(l.overflowsLines)
        XCTAssertNil(l.plateRect)
        XCTAssertEqual(l.reach, 0, accuracy: 1e-9)
        assertRect(l.safeRect, 54, 54, 1812, 972)
        assertRect(l.textRect, 879, 948.24, 162, 77.76)
        XCTAssertEqual(l.textRect.x + l.textRect.width / 2, 960, accuracy: 1e-9)
        XCTAssertEqual(l.textRect.maxY, 1026, accuracy: 1e-9)
        XCTAssertTrue(l.safeRect.contains(l.textRect))
    }

    func testAnEmptyLookIsTheDefaultLook() {
        XCTAssertEqual(layout("Hello", look: NativeCaptionLook()), layout("Hello"))
    }

    // (2) Wrap limit = 1536 px with no plate. A character is 32.4 px: 47 characters are 1522.8 px and fit, 48 are
    // 1555.2 px and do not. A 47-character word stays whole; a 48-character word splits into 47 and 1.
    func testWidthLimitIsTheFrameMaxWidthWithNoPlate() {
        XCTAssertEqual(layout(xs(47)).lines, [xs(47)])
        XCTAssertEqual(layout(xs(48)).lines, [xs(47), "x"])
    }

    // Words of 10 characters. Four with spaces are 4 * 10 + 3 = 43 characters = 1393.2 px; five would be 54 characters
    // = 1749.6 px, over 1536. So 8 words make two lines of 4 words each.
    // Height = 2 * 77.76 = 155.52, so the block starts at 1026 - 155.52 = 870.48.
    func testWordsThatNeedTwoLinesGiveTwoLinesAndNoOverflow() {
        let l = layout(words(8))
        XCTAssertEqual(l.lines, [words(4), words(4)])
        XCTAssertFalse(l.overflowsLines)
        XCTAssertEqual(l.fontSize, 64.8, accuracy: 1e-9)
        XCTAssertEqual(l.textRect.width, 1393.2, accuracy: 1e-6)
        XCTAssertEqual(l.textRect.y, 870.48, accuracy: 1e-6)
        XCTAssertTrue(l.safeRect.contains(l.textRect))
    }

    // 9 words make lines of 4, 4 and 1 words. Three lines is over maxLines (2), so overflowsLines is true, but every line
    // is laid out and the font stays 64.8 (never shrunk).
    // Height = 3 * 77.76 = 233.28, so the block starts at 1026 - 233.28 = 792.72.
    func testThreeLinesKeepEveryLineAndTheFontSize() {
        let l = layout(words(9))
        XCTAssertEqual(l.lines, [words(4), words(4), "abcdefghij"])
        XCTAssertEqual(l.lines.joined(separator: " "), words(9), "nothing is cut")
        XCTAssertTrue(l.overflowsLines)
        XCTAssertEqual(l.fontSize, 64.8, accuracy: 1e-9)
        XCTAssertEqual(l.textRect.height, 233.28, accuracy: 1e-6)
        XCTAssertEqual(l.textRect.y, 792.72, accuracy: 1e-6)
        XCTAssertTrue(l.safeRect.contains(l.textRect))
        XCTAssertTrue(l.safeRect.contains(l.paintedRect))
    }

    // Explicit newlines start new lines. "a\n\nb" has an empty middle paragraph, which is kept as an empty line.
    func testExplicitNewlinesAreHonoured() {
        XCTAssertEqual(layout("Hi\nthere").lines, ["Hi", "there"])
        XCTAssertEqual(layout("a\n\nb").lines, ["a", "", "b"])
        XCTAssertFalse(layout("Hi\nthere").overflowsLines)
    }

    // 60 x's and no spaces: the word is wider than 1536 px, so it splits between characters. The first piece is the
    // longest that fits, 47 characters (1522.8 px); the rest is 13 characters.
    func testAWordWiderThanTheLimitIsSplitBetweenCharacters() {
        let l = layout(xs(60))
        XCTAssertEqual(l.lines, [xs(47), xs(13)])
        XCTAssertEqual(l.lines.joined(), xs(60))
    }

    // (3) Every cue stays inside the safe area in both orientations. The frames share the short edge 1080, so the font
    // stays 64.8 in both; the width limit is 0.8 * width.
    let cues: [String] = [
        "Hi",
        "Hello",
        "Hello there, this is a short cue",
        words(8),
        words(9),
        xs(200),
        "Line one\nLine two\nLine three",
        "",
    ]
    let positions: [NativeCaptionPosition] = [.bottom, .top, .custom(x: 0.9, y: 0.95), .custom(x: 0.0, y: 0.0)]
    let frames: [(width: Double, height: Double)] = [(1920, 1080), (1080, 1920)]

    func testEveryCueStaysInsideTheSafeAreaInBothOrientations() {
        for cue in cues {
            for position in positions {
                for frame in frames {
                    let l = layout(cue, position: position, width: frame.width, height: frame.height)
                    let label = "\(cue.debugDescription) at \(position) in \(frame.width)x\(frame.height)"
                    XCTAssertTrue(l.safeRect.contains(l.paintedRect), "\(label): \(l.paintedRect) outside \(l.safeRect)")
                    XCTAssertEqual(l.fontSize, 64.8, accuracy: 1e-9, label)
                    for line in l.lines {
                        XCTAssertLessThanOrEqual(fixedAdvance(line, l.fontSize), 0.8 * frame.width + 1e-6, label)
                    }
                }
            }
        }
    }

    // The same, with an outline (reach 20) and a plate, so the painted box is larger than the text.
    // Outline 20 px at short edge 1080: reach = max(20, shadow 0) = 20.
    func testOutlinedPlatedLookStaysInsideTheSafeAreaInBothOrientations() {
        let look = NativeCaptionLook(outlines: [NativeTextLook.Outline(width: 20, color: "#000000")],
                                     plate: NativeCaptionLook.Plate(color: "#00000080"))
        for cue in cues {
            for position in positions {
                for frame in frames {
                    let l = layout(cue, look: look, position: position, width: frame.width, height: frame.height)
                    XCTAssertEqual(l.reach, 20, accuracy: 1e-9)
                    XCTAssertTrue(l.safeRect.contains(l.paintedRect), "\(cue.debugDescription) at \(position) in \(frame.width)x\(frame.height)")
                }
            }
        }
    }

    // Portrait 1080x1920: fontSize = 0.06 * 1080 = 64.8 (the short edge is still 1080). Width limit = 0.8 * 1080 = 864.
    // A character is 32.4 px: 26 characters (842.4) fit and 27 (874.8) do not. 60 x's split into 26 + 26 + 8.
    // Width of the block 842.4; centred at 540: x = 540 - 421.2 = 118.8.
    // Bottom: 3 lines, height 233.28, y = (54 + 1812 = 1866) - 233.28 = 1632.72.
    func testPortraitFrameKeepsTheFontAndNarrowsTheWidthLimit() {
        let l = layout(xs(60), width: 1080, height: 1920)
        XCTAssertEqual(l.fontSize, 64.8, accuracy: 1e-9)
        XCTAssertEqual(l.lines, [xs(26), xs(26), xs(8)])
        XCTAssertTrue(l.overflowsLines)
        assertRect(l.textRect, 118.8, 1632.72, 842.4, 233.28)
        XCTAssertEqual(l.textRect.x + l.textRect.width / 2, 540, accuracy: 1e-9)
        XCTAssertTrue(l.safeRect.contains(l.paintedRect))
    }

    // Custom positions: x 0.9, y 0.95 of "x" * 47 (width 1522.8, height 77.76) would put the block at x 1728 - 761.4 = 966.6
    // and y 1026 - 38.88 = 987.12. Pushed back: x = 1866 - 1522.8 = 343.2, y = 1026 - 77.76 = 948.24.
    // x 0.0, y 0.0 of "Hello" (162 x 77.76): x = 0 - 81 pushed to the safe left edge 54; y = 0 - 38.88 pushed to 54.
    func testCustomPositionsArePushedBackInsideTheSafeArea() {
        let far = layout(xs(47), position: .custom(x: 0.9, y: 0.95))
        assertRect(far.textRect, 343.2, 948.24, 1522.8, 77.76)
        XCTAssertEqual(far.textRect.maxX, 1866, accuracy: 1e-6)
        XCTAssertEqual(far.textRect.maxY, 1026, accuracy: 1e-6)

        let origin = layout("Hello", position: .custom(x: 0.0, y: 0.0))
        assertRect(origin.textRect, 54, 54, 162, 77.76)
        assertRect(origin.paintedRect, 54, 54, 162, 77.76)
    }

    // (4) Plate padding 0.5: pad = 0.5 * 64.8 = 32.4 on every side. The wrap limit shrinks by 2 * 32.4 = 64.8 to
    // 1536 - 64.8 = 1471.2 px. A character is 32.4 px: 45 characters (1458) fit, 46 (1490.4) do not. Without the plate,
    // 46 characters fit on one line (limit 1536).
    // For "Hello": outer width = 162 + 64.8 = 226.8, outer height = 77.76 + 64.8 = 142.56. Centred: x = 960 - 113.4 = 846.6.
    // Bottom: y = 1026 - 142.56 = 883.44. Text sits 32.4 inside: (879, 915.84, 162, 77.76).
    func testPlateShrinksTheWrapLimitAndSurroundsTheText() {
        let look = NativeCaptionLook(plate: NativeCaptionLook.Plate(color: "#00000080", padding: 0.5))
        XCTAssertEqual(layout(xs(46), look: look).lines, [xs(45), "x"])
        XCTAssertEqual(layout(xs(46)).lines, [xs(46)])

        let l = layout("Hello", look: look)
        guard let plate = l.plateRect else { XCTFail("a plated look has a plate rect"); return }
        assertRect(plate, 846.6, 883.44, 226.8, 142.56)
        assertRect(l.textRect, 879, 915.84, 162, 77.76)
        XCTAssertEqual(l.textRect.x - plate.x, 32.4, accuracy: 1e-6)
        XCTAssertEqual(l.textRect.y - plate.y, 32.4, accuracy: 1e-6)
        XCTAssertEqual(plate.maxX - l.textRect.maxX, 32.4, accuracy: 1e-6)
        XCTAssertEqual(plate.maxY - l.textRect.maxY, 32.4, accuracy: 1e-6)
        XCTAssertEqual(l.paintedRect, plate, "the painted box is the plate when there is one")
    }

    // (5) Reach. An outline of 108 px at a 1080 short edge (unit 1) gives reach 108.
    // The usable box is the safe box inset by 108: y 54 + 108 = 162, height 972 - 216 = 756, so its bottom is 918.
    // Bottom text: y = 918 - 77.76 = 840.24 (not 948.24 without reach). Painted box = text grown by 108 on each side:
    // (879 - 108, 840.24 - 108, 162 + 216, 77.76 + 216) = (771, 732.24, 378, 293.76), bottom edge 1026.
    func testOutlineReachIsKeptInsideTheSafeArea() {
        let look = NativeCaptionLook(outlines: [NativeTextLook.Outline(width: 108, color: "#000000")])
        let l = layout("Hello", look: look)
        XCTAssertEqual(l.reach, 108, accuracy: 1e-9)
        assertRect(l.textRect, 879, 840.24, 162, 77.76)
        assertRect(l.paintedRect, 771, 732.24, 378, 293.76)
        XCTAssertTrue(l.safeRect.contains(l.paintedRect))
    }

    // Shadow x 20, y -30, blur 10: reach = max(|20|, |-30|) + 10 = 40. Usable bottom = 1026 - 40 = 986,
    // so y = 986 - 77.76 = 908.24. Painted box = (879 - 40, 908.24 - 40, 162 + 80, 77.76 + 80) = (839, 868.24, 242, 157.76),
    // bottom edge 1026.
    func testShadowReachIsTheLargerOffsetPlusBlur() {
        let look = NativeCaptionLook(shadow: NativeTextLook.Shadow(x: 20, y: -30, blur: 10, color: "#000000"))
        let l = layout("Hello", look: look)
        XCTAssertEqual(l.reach, 40, accuracy: 1e-9)
        assertRect(l.textRect, 879, 908.24, 162, 77.76)
        assertRect(l.paintedRect, 839, 868.24, 242, 157.76)
        XCTAssertTrue(l.safeRect.contains(l.paintedRect))
    }

    // (6) A cue's position wins over the look's. The look says bottom (y 948.24). The cue says top: usable.y = 54 with no
    // reach, so textRect.y = 54 and paintedRect.y = 54.
    func testCuePositionTopWinsOverLookPositionBottom() {
        let look = NativeCaptionLook(position: NativeCaptionPosition.bottom)
        let top = layout("Hello", look: look, position: NativeCaptionPosition.top)
        XCTAssertEqual(top.textRect.y, 54, accuracy: 1e-6)
        XCTAssertEqual(top.paintedRect.y, 54, accuracy: 1e-6)

        let lookOnly = layout("Hello", look: look)
        XCTAssertEqual(lookOnly.textRect.y, 948.24, accuracy: 1e-6, "the look alone puts the text at the bottom")
    }

    // (7) A look with v 2 is kept but not read: it lays out exactly as the default look.
    func testUnsupportedLookLaysOutAsTheDefaultLook() throws {
        let look = try JSONDecoder().decode(NativeCaptionLook.self, from: Data(#"{"v":2}"#.utf8))
        XCTAssertFalse(look.isSupported)
        XCTAssertEqual(layout("Hello", look: look), layout("Hello"))
        XCTAssertEqual(layout("Hello", look: look).fontSize, 64.8, accuracy: 1e-9)
    }

    // (8) Empty text is one empty line. It has no width and does not crash.
    func testEmptyTextGivesOneEmptyLine() {
        let l = layout("")
        XCTAssertEqual(l.lines, [""])
        XCTAssertEqual(l.textRect.width, 0, accuracy: 1e-9)
        XCTAssertFalse(l.overflowsLines)
    }

    // A 0x0 frame clamps to 1x1: short edge 1, fontSize = max(1, 0.06 * 1) = 1, lineHeight 1.2. The safe box is
    // max(1, 1 - 0.1) = 1 wide. The wrap limit is max(fontSize 1, min(0.8, 1)) = 1 px, and a character is 0.5 px, so
    // "Hello" splits into "He", "ll" and "o". Nothing is lost and nothing crashes.
    func testZeroSizedFrameDoesNotCrash() {
        let l = layout("Hello", width: 0, height: 0)
        XCTAssertEqual(l.fontSize, 1, accuracy: 1e-9)
        XCTAssertEqual(l.lines, ["He", "ll", "o"])
        XCTAssertEqual(l.lines.joined(), "Hello")
        _ = l.paintedRect
    }
}
