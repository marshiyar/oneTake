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
import MpvfxCanvas
import MpvfxShared
import XCTest

@testable import MpvfxPlayer

internal final class StageShapeDraftTests: XCTestCase {
    private func make(_ kind: String, _ a: (Double, Double), _ b: (Double, Double), shift: Bool = false, alt: Bool = false)
        -> StageShapeDraft
    {
        StageShapeDraft.make(
            kind: kind, from: CanvasPoint(a.0, a.1), to: CanvasPoint(b.0, b.1), shift: shift, alt: alt, click: false)
    }

    internal func testAClickMakesTheDefaultSizeCentredOnIt() {
        for kind in StageShapeDraft.kinds {
            let draft = StageShapeDraft.make(
                kind: kind, from: CanvasPoint(500, 400), to: CanvasPoint(500, 400), shift: false, alt: false, click: true)
            XCTAssertEqual(draft.box, CanvasRect(x: 400, y: 340, width: 200, height: 120), kind)
            XCTAssertEqual(draft.shape.kind, kind)
        }
        let line = StageShapeDraft.make(
            kind: "line", from: CanvasPoint(0, 0), to: CanvasPoint(0, 0), shift: false, alt: false, click: true)
        XCTAssertEqual(line.shape.number("endX", default: 1), 1)
        XCTAssertEqual(line.shape.number("startX"), 0, "corner to corner of the default box")
    }

    internal func testADragIsCornerToCornerInAnyDirection() {
        XCTAssertEqual(make("rectangle", (100, 100), (300, 250)).box, CanvasRect(x: 100, y: 100, width: 200, height: 150))
        XCTAssertEqual(make("ellipse", (300, 250), (100, 100)).box, CanvasRect(x: 100, y: 100, width: 200, height: 150))
        XCTAssertNil(make("rectangle", (100, 100), (300, 250)).shape.raw["strokeWidth"], "a new rectangle is a filled one")
    }

    internal func testShiftMakesASquareAlongTheLongerSideKeepingDirection() {
        XCTAssertEqual(make("rectangle", (100, 100), (300, 160), shift: true).box, CanvasRect(x: 100, y: 100, width: 200, height: 200))
        XCTAssertEqual(make("ellipse", (300, 300), (260, 100), shift: true).box, CanvasRect(x: 100, y: 100, width: 200, height: 200))
    }

    internal func testOptionDrawsFromTheCentre() {
        XCTAssertEqual(make("rectangle", (500, 400), (560, 430), alt: true).box, CanvasRect(x: 440, y: 370, width: 120, height: 60))
        XCTAssertEqual(
            make("ellipse", (500, 400), (560, 430), shift: true, alt: true).box, CanvasRect(x: 440, y: 340, width: 120, height: 120))
    }

    internal func testALineRunsFromThePressToThePointerAndShiftSnapsTo45Degrees() {
        let drag = make("line", (100, 100), (300, 200))
        XCTAssertEqual(drag.box, CanvasRect(x: 100, y: 100, width: 200, height: 100))
        XCTAssertEqual(drag.shape.number("endX", default: 1), 1)
        XCTAssertEqual(drag.shape.number("endY", default: 1), 1)
        XCTAssertEqual(drag.shape.number("startX"), 0)
        let steep = make("arrow", (100, 100), (300, 130), shift: true)
        XCTAssertEqual(steep.box.height, StageShapeDraft.minimumBox, "snapped flat: a thin box")
        XCTAssertEqual(steep.shape.number("startY"), 0.5, accuracy: 1e-9)
        XCTAssertEqual(steep.shape.number("endY", default: 1), 0.5, accuracy: 1e-9)
        XCTAssertEqual(steep.box.width, (hypot(200, 30)).rounded(), accuracy: 1)
        let diagonal = make("line", (100, 100), (260, 120), shift: true)
        XCTAssertEqual(diagonal.box.height, 20, "7 degrees rounds to flat")
        let rising = make("line", (100, 100), (200, 170), shift: true)
        XCTAssertEqual(rising.box.width, rising.box.height, accuracy: 1, "35 degrees rounds to 45")
    }

    internal func testOptionDrawsALineFromItsMiddle() {
        let line = make("line", (500, 400), (600, 400), alt: true)
        XCTAssertEqual(line.box.x, 400)
        XCTAssertEqual(line.box.width, 200)
        XCTAssertEqual(line.shape.number("endX", default: 1), 1)
        XCTAssertEqual(line.shape.number("startX"), 0)
    }

    internal func testEveryDraftIsAValidDocumentShape() throws {
        for kind in StageShapeDraft.kinds {
            for (shift, alt) in [(false, false), (true, false), (false, true), (true, true)] {
                let draft = make(kind, (100, 100), (180, 140), shift: shift, alt: alt)
                var project = try PreviewCompositorTests.document()
                project.assets[0].kind = .element
                project.assets[0].source = nil
                var clip = project.sequence.tracks[2].clips[0]
                clip.shape = draft.shape
                clip.staticParameters = [
                    "layout.left": .number(draft.box.x), "layout.top": .number(draft.box.y),
                    "layout.width": .number(draft.box.width), "layout.height": .number(draft.box.height),
                ]
                project.sequence.tracks = [.init(id: "shapes", kind: .video, clips: [clip])]
                XCTAssertNoThrow(try parseNativeProjectDocument(project), "\(kind) shift \(shift) alt \(alt)")
            }
        }
    }

    internal func testThePickerHasOneChipPerKindAndHitTestsThem() {
        let viewport = CanvasRect(x: 0, y: 40, width: 800, height: 500)
        let chips = StageShapePicker.rects(in: viewport)
        XCTAssertEqual(chips.map(\.kind), ["rectangle", "ellipse", "line", "arrow"])
        for (kind, rect) in chips { XCTAssertEqual(StageShapePicker.kind(at: CanvasPoint(rect.midX, rect.midY), in: viewport), kind) }
        XCTAssertNil(StageShapePicker.kind(at: CanvasPoint(400, 300), in: viewport))
        XCTAssertGreaterThanOrEqual(StageShapePicker.chipHeight, 24, "a target of at least 24 points")
    }
}
