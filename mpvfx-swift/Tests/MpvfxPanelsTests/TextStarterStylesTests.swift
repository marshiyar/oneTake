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
import MpvfxCanvas
import MpvfxShared
import MpvfxTimeline
import OneTakeKeyframes
import XCTest

@testable import MpvfxPanels

/// Issue #284: the eight starter text styles.
internal final class TextStarterStylesTests: XCTestCase {
    /// WCAG relative luminance and contrast of sRGB colours given as 0…255.
    private func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
        func lin(_ v: Double) -> Double { let s = v / 255; return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }
    private func contrast(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
    private func rgba(_ hex: String) -> (r: Double, g: Double, b: Double, a: Double) {
        let c = CanvasColor.documentColor(hex)
        return (c.r * 255, c.g * 255, c.b * 255, c.a)
    }
    private func over(_ top: String, _ frame: Double) -> (r: Double, g: Double, b: Double) {
        let c = rgba(top)
        return (c.r * c.a + frame * (1 - c.a), c.g * c.a + frame * (1 - c.a), c.b * c.a + frame * (1 - c.a))
    }

    internal func testTheSetHasEightPlainlyNamedStylesOfTheRightKind() {
        let styles = TextStarterStyles.styles
        XCTAssertEqual(styles.map(\.name), ["Lower third", "Bold title", "Subtitle plate", "Quote", "Label", "Outline title", "Soft shadow", "Mono caption"])
        XCTAssertEqual(Set(styles.map(\.id)).count, 8)
        XCTAssertTrue(styles.allSatisfy { $0.isSupported && $0.id.hasPrefix("starter:") && $0.text?.content == "" })
        XCTAssertTrue(styles.allSatisfy { $0.text?.look?.isSupported == true && $0.text?.look?.isEmpty == false })
    }

    internal func testA1EveryStyleReadsOnWhiteBlackAndMidGreyFrames() throws {
        for style in TextStarterStyles.styles {
            let text = try XCTUnwrap(style.text, style.name)
            let fill = rgba(text.resolvedColor)
            let look = try XCTUnwrap(text.look, style.name)
            for frame in [255.0, 0.0, 128.0] {
                let surround: (r: Double, g: Double, b: Double)
                if let plate = look.plate { surround = over(plate.color, frame) }
                else if let outline = look.outlines?.first { surround = over(outline.color, frame) }
                else { XCTFail("\(style.name) has nothing between its text and the frame"); continue }
                XCTAssertGreaterThanOrEqual(contrast((fill.r, fill.g, fill.b), surround), 4.5, "\(style.name) on a \(Int(frame)) frame")
            }
        }
    }

    internal func testA2TheJSONCarriesTheCopyrightBlockAndNoFontIsAdded() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(TextStarterStyles.json.utf8)) as? [String: Any])
        let lines = try XCTUnwrap(object["copyright"] as? [String])
        XCTAssertTrue(lines.first?.hasPrefix("Copyright (c) 2026 Arshiya Rahgozar") == true)
        XCTAssertTrue(lines.contains("SPDX-License-Identifier: MIT OR Apache-2.0"))
        let families = Set(TextStarterStyles.styles.compactMap { $0.text?.fontFamily })
        XCTAssertEqual(families, ["Sans", "Monospace"], "only the generic families every platform maps to a system font")
    }

    internal func testEveryStyleAppliesToATextLayerThroughTheValidator() throws {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try KeyframeRuntime())
        let id = try XCTUnwrap(editor.addTextClip(at: 0, content: "Title", seconds: 4))
        for style in TextStarterStyles.styles {
            XCTAssertTrue(editor.applyLibraryTextStyle(style, clipIds: [id]), style.name)
            XCTAssertEqual(editor.clipText(clipId: id)?.look, style.text?.look, style.name)
            XCTAssertEqual(editor.clipText(clipId: id)?.content, "Title", "a style never carries words")
        }
        XCTAssertEqual(editor.document.textStyles?.count, 8)
    }

    internal func testTheMenuOffersTheStartersToANewUserAndNumbersThemFromOne() throws {
        let editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try KeyframeRuntime())
        let id = try XCTUnwrap(editor.addTextClip(at: 0, content: "Title", seconds: 4))
        let panel = InspectorPanel()
        panel.editor = editor
        panel.selection = [id]
        panel.openGroupId = "text"
        XCTAssertEqual(panel.textStyleChoices(editor).map(\.name).first, "Lower third")
        XCTAssertTrue(panel.applyTextStyle(number: 2))
        XCTAssertEqual(editor.clip(id)?.1.textStyle?.styleId, "starter:bold-title")
        XCTAssertEqual(editor.clipText(clipId: id)?.resolvedFontSize, 84)
    }
}
