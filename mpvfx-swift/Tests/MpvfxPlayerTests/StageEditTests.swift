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
import MpvfxTimeline
@testable import MpvfxPlayer

final class StageEditTests: XCTestCase {
    func testTransformWriteBackAndUndo() throws {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON)
        guard let id = e.tracks.flatMap(\.clips).first?.id else { return XCTFail("no clip") }
        let base = CanvasRect(x: 10, y: 20, width: 100, height: 50)
        let start = StageElement(id: id, name: "a", rect: base, kind: .element)
        var end = start; end.rect.x += 30; end.rect.width = 140; end.rotation = 45
        let t = StageGeometry.transform(base: base, start: start, end: end)
        XCTAssertEqual(t, ClipTransform(x: 30, y: 0, width: 140, rotation: 45))
        let before = e.transform(clipId: id, time: 0)
        XCTAssertTrue(e.applyTransform(clipId: id, time: 0, t), "\(String(describing: e.lastPropertyFailure))")
        let after = e.transform(clipId: id, time: 0)
        XCTAssertEqual(after.x, 30); XCTAssertEqual(after.width, 140); XCTAssertEqual(after.rotation, 45)
        XCTAssertEqual(StageGeometry.rect(base: base, after), CanvasRect(x: 40, y: 20, width: 140, height: 50))
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.transform(clipId: id, time: 0), before)
        XCTAssertTrue(e.redo()); XCTAssertEqual(e.transform(clipId: id, time: 0).rotation, 45)
    }

    func testCropInsetsScaleWithBox() {
        let c = CropInsets(top: 10, right: 20, bottom: 10, left: 20)
        XCTAssertEqual(c.scaled(from: .init(100, 100), to: .init(200, 50)), CropInsets(top: 5, right: 40, bottom: 5, left: 40))
    }

    func testRotateAboutCentre() {
        let p = PlayerView.rotate(.init(10, 0), about: .init(0, 0), 90)
        XCTAssertEqual(p.x, 0, accuracy: 1e-9); XCTAssertEqual(p.y, 10, accuracy: 1e-9)
    }
}
