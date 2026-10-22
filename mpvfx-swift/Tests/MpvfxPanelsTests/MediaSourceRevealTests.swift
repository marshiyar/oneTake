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
import MpvfxCanvas
@testable import MpvfxPanels

final class MediaSourceRevealTests: XCTestCase {
    func testRevealClearsFiltersAndScrollsTheSelectedTileIntoView() throws {
        let p = MediaPanelFixture.panel()
        p.searchQuery = "hidden"
        p.filter.kind = .audio
        p.revealMedia("media/Inter.ttf")
        let size = CanvasSize(300, 260)
        p.draw(PanelMeasureCanvas(), size: size)
        p.draw(PanelMeasureCanvas(), size: size)
        XCTAssertEqual(p.selected, .media("media/Inter.ttf"))
        XCTAssertEqual(p.searchQuery, "")
        XCTAssertTrue(p.filter.isDefault)
        let frame = try XCTUnwrap(p.tileFrames.first { $0.0 == .media("media/Inter.ttf") }?.1)
        XCTAssertLessThanOrEqual(frame.maxY, p.binScroll + p.binRect.height)
        XCTAssertGreaterThanOrEqual(frame.y, p.binScroll)
        XCTAssertNil(p.pendingReveal)
    }

    func testRevealWaitsForAnAsynchronousMediaList() {
        let p = MediaPanelFixture.panel()
        let items = p.items
        p.items = []
        p.revealMedia("media/Inter.ttf")
        p.draw(PanelMeasureCanvas(), size: CanvasSize(300, 260))
        XCTAssertNotNil(p.pendingReveal)
        p.items = items
        p.draw(PanelMeasureCanvas(), size: CanvasSize(300, 260))
        XCTAssertNil(p.pendingReveal)
    }
}
