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

internal final class NativeTextLookParameterTests: XCTestCase {
    private func look() -> NativeTextLook {
        NativeTextLook(outlines: [.init(width: 4, color: "#ff0000"), .init(width: 9, color: "#00ff00")],
                       shadow: .init(x: 3, y: -2, blur: 5, color: "#000000"))
    }

    internal func testValuesAreReadFromAndStoredInTheLookHeldToTheirRange() {
        let l = look()
        XCTAssertEqual(NativeTextLookParameter.value(of: "text.look.outline.0.width", in: l), 4)
        XCTAssertEqual(NativeTextLookParameter.value(of: "text.look.outline.1.width", in: l), 9)
        XCTAssertEqual(NativeTextLookParameter.value(of: NativeTextLookParameter.shadowXId, in: l), 3)
        XCTAssertEqual(NativeTextLookParameter.value(of: NativeTextLookParameter.shadowYId, in: l), -2)
        XCTAssertEqual(NativeTextLookParameter.value(of: NativeTextLookParameter.shadowBlurId, in: l), 5)
        XCTAssertNil(NativeTextLookParameter.value(of: "text.look.glow.radius", in: l))
        let wide = NativeTextLookParameter.setting(500, id: "text.look.outline.0.width", in: l)
        XCTAssertEqual(wide?.outlines?[0].width, 100, "held to the document range, never stored outside it")
        XCTAssertEqual(NativeTextLookParameter.setting(-900, id: NativeTextLookParameter.shadowXId, in: l)?.shadow?.x, -500)
        XCTAssertEqual(NativeTextLookParameter.setting(999, id: NativeTextLookParameter.shadowBlurId, in: l)?.shadow?.blur, 200)
        XCTAssertNil(NativeTextLookParameter.setting(.nan, id: NativeTextLookParameter.shadowBlurId, in: l))
    }

    internal func testAPartTheLookLacksIsIgnored() {
        let oneOutline = NativeTextLook(outlines: [.init(width: 4, color: "#ff0000")])
        XCTAssertNil(NativeTextLookParameter.value(of: "text.look.outline.1.width", in: oneOutline))
        XCTAssertNil(NativeTextLookParameter.setting(5, id: "text.look.outline.1.width", in: oneOutline))
        XCTAssertNil(NativeTextLookParameter.setting(5, id: NativeTextLookParameter.shadowXId, in: oneOutline))
        let text = NativeClipText(content: "Hi", look: oneOutline)
        let values: [String: NativeParameterValue] = ["text.look.outline.1.width": .number(7), NativeTextLookParameter.shadowXId: .number(2)]
        XCTAssertEqual(NativeTextLookParameter.applying(values, to: text), text)
    }

    internal func testShadowDefaultsStayAbsentKeys() {
        let l = NativeTextLook(shadow: .init(x: 3, y: 3, blur: 4, color: "#000000"))
        let cleared = NativeTextLookParameter.setting(0, id: NativeTextLookParameter.shadowXId, in: l)
        XCTAssertNil(cleared?.shadow?.x)
        XCTAssertEqual(cleared?.shadow?.y, 3)
    }

    internal func testApplyingReplacesOnlyAnimatedValuesAndLeavesTheRestOfTheTextAlone() {
        let text = NativeClipText(content: "Title", fontSize: 40, color: "#ffffff", look: look())
        let values: [String: NativeParameterValue] = [
            "text.look.outline.0.width": .number(12), NativeTextLookParameter.shadowBlurId: .number(20),
            "transform.opacity": .number(0.5),
        ]
        let drawn = NativeTextLookParameter.applying(values, to: text)
        XCTAssertEqual(drawn.look?.outlines?[0].width, 12)
        XCTAssertEqual(drawn.look?.outlines?[1].width, 9)
        XCTAssertEqual(drawn.look?.shadow?.blur, 20)
        XCTAssertEqual(drawn.look?.shadow?.x, 3)
        XCTAssertEqual(drawn.look?.outlines?[0].color, "#ff0000")
        var same = drawn
        same.look = text.look
        XCTAssertEqual(same, text)
        XCTAssertEqual(NativeTextLookParameter.applying([:], to: text), text, "nothing animated: the stored text is drawn")
    }

    internal func testEveryAnimatableIdHasARangeAndNoOtherIdDoes() {
        for id in NativeTextLookParameter.all {
            XCTAssertTrue(NativeTextLookParameter.isTextLookParameter(id))
            XCTAssertNotNil(NativeTextLookParameter.range(of: id), id)
        }
        XCTAssertEqual(NativeTextLookParameter.all.count, 5)
        XCTAssertFalse(NativeTextLookParameter.isTextLookParameter("text.look.outline.2.width"))
        XCTAssertNil(NativeTextLookParameter.range(of: "visual.opacity"))
    }
}
