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
import Foundation
import MpvfxCanvas
import MpvfxShared
import OneTakeKeyframes
import MpvfxTimeline
import MpvfxPanels
@testable import MpvfxPlayer
@testable import MpvfxRuntime

/// The Transform group's 3D transform (with the orientation cube): every control re-draws the
/// preview frame and re-warps the export, through the one NativeTransform3D projection.
extension InspectorRenderAuditTests {
    func static3D(_ pid: String) -> Double? {
        if case .number(let v)? = editor.clip("V")?.clip.staticParameters?[pid] { return v }
        return nil
    }
    func open3D() { inspector.openGroupId = "layout"; inspector.transform3DOpen = true }
    static let meshImages = 2 * PreviewPainter.meshCells * PreviewPainter.meshCells

    func testThreeDSectionIsCollapsedByDefault() {
        for g in inspector.groups { for r in g.rows { if case .number(let n) = r.kind { XCTAssertNotEqual(n.key, "tiltX") } } }
        inspector.openGroupId = "layout"
        let c = AuditCanvas()
        inspector.draw(c, in: CanvasRect(x: 0, y: 0, width: 300, height: 1600))
        guard let toggle = inspector.hits.rect(where: { $0 == .custom("3d:toggle", 0) }) else { return XCTFail("no 3D transform header") }
        _ = inspector.pointerDown(CanvasPoint(toggle.x + 4, toggle.y + 4)); inspector.pointerUp(CanvasPoint(toggle.x + 4, toggle.y + 4))
        XCTAssertTrue(inspector.transform3DOpen)
        guard case .number? = find("tiltX") else { return XCTFail("the open section has no Tilt X") }
    }

    func testTiltXUnderALensForeshortens() {
        open3D(); type("perspective", "300")
        assertVisualEdit("Tilt X", { type("tiltX", "30") }) { c in
            XCTAssertEqual(c.images.count, Self.meshImages, "a tilted plane under a lens is drawn as a projected mesh")
        }
        XCTAssertEqual(static3D(NativeTransform3D.rotationXId), 30)
        let tilted = exportRender()
        XCTAssertTrue([tilted.pixel(100, 1), tilted.pixel(100, 98)].contains([128, 128, 128, 255]),
                      "export tilts the clip through the projection: its far edge leaves the frame edge")
    }

    func testTiltYWithoutALensIsOneAffineDraw() {
        open3D()
        assertVisualEdit("Tilt Y", { type("tiltY", "60") }) { c in
            XCTAssertEqual(c.images.count, 1, "no lens: an orthographic tilt, one affine draw")
        }
        XCTAssertEqual(static3D(NativeTransform3D.rotationYId), 60)
    }

    func testDepthBringsTheCompLensAndScales() {
        open3D()
        // A box smaller than the frame, so drawing it twice as large changes what the export frame covers (a uniform
        // full-frame picture looks the same at any scale).
        type("w", "60"); type("h", "30")
        assertVisualEdit("Depth", { type("depth", "50") }) { c in
            XCTAssertTrue(c.ops.contains(.scale(2, 2)), "z 50 under the 100 px comp lens draws twice as large")
        }
        XCTAssertEqual(static3D(NativeTransform3D.zId), 50)
        XCTAssertEqual(static3D(NativeTransform3D.perspectiveId), 100, "the comp height becomes the lens the first time depth is set")
        type("depth", "500")
        XCTAssertEqual(static3D(NativeTransform3D.zId), 85, "depth stays in front of the lens (0.85 of it)")
    }

    func testRollIsTheRotation() {
        open3D()
        assertVisualEdit("Roll", { type("roll", "20") }) { c in XCTAssertTrue(c.ops.contains(.rotate(20 * .pi / 180))) }
        guard case .number(let rot)? = find("rotation") else { return XCTFail("no Rotation row") }
        XCTAssertEqual(rot.text, "20°", "Roll and Rotation edit one value")
    }

    func testPerspectiveChangesATiltedLayer() {
        open3D(); type("tiltX", "30")
        assertVisualEdit("Perspective", { type("perspective", "250") }) { c in XCTAssertEqual(c.images.count, Self.meshImages) }
        type("perspective", "-5")
        XCTAssertEqual(static3D(NativeTransform3D.perspectiveId), 0, "the lens is never negative")
    }

    func testCubeDragTiltsInOneStep() {
        open3D()
        let c = AuditCanvas()
        inspector.draw(c, in: CanvasRect(x: 0, y: 0, width: 300, height: 1600))
        guard let cube = inspector.hits.rect(where: { $0 == .custom("3d:cube", 0) }) else { return XCTFail("the cube is not drawn") }
        let start = CanvasPoint(cube.x + cube.width / 2, cube.y + cube.height / 2)
        assertVisualEdit("Cube drag", {
            _ = inspector.pointerDown(start)
            _ = inspector.pointerMove(CanvasPoint(start.x + 50, start.y + 20))
            XCTAssertEqual(inspector.cubeDrag?.y, 30, "the live pose follows the drag (0.6° per px)")
            inspector.pointerUp(CanvasPoint(start.x + 50, start.y + 20))
        })
        XCTAssertEqual(static3D(NativeTransform3D.rotationYId), 30)
        XCTAssertEqual(static3D(NativeTransform3D.rotationXId), 12)
        XCTAssertNil(inspector.cubeDrag)
        XCTAssertTrue(editor.undo())
        XCTAssertNil(static3D(NativeTransform3D.rotationXId), "one undo takes back the whole pose")
        XCTAssertNil(static3D(NativeTransform3D.rotationYId))
    }

    func testCubeResetFlattens() {
        open3D(); type("tiltX", "20"); type("depth", "30")
        let flat = previewFrame().ops
        inspector.draw(AuditCanvas(), in: CanvasRect(x: 0, y: 0, width: 300, height: 1600))
        guard let reset = inspector.hits.rect(where: { $0 == .custom("3d:cube", 1) }) else { return XCTFail("no cube reset") }
        assertVisualEdit("Reset 3D", {
            _ = inspector.pointerDown(CanvasPoint(reset.x + reset.width / 2, reset.y + reset.height / 2))
            inspector.pointerUp(CanvasPoint(reset.x + reset.width / 2, reset.y + reset.height / 2))
        })
        for pid in NativeTransform3D.parameterIds { XCTAssertNil(static3D(pid), pid) }
        XCTAssertNotEqual(previewFrame().ops, flat)
        XCTAssertEqual(previewFrame().images.count, 1)
    }

    func testKeyframedTiltExportsAndEases() {
        open3D()
        guard case .number(let tx)? = find("tiltX"), let kf = tx.keyframe else { return XCTFail("Tilt X has no keyframe button") }
        kf.toggle()
        select("V", time: 2); type("tiltX", "40"); select("V", time: 0)
        type("perspective", "300")
        let mid = previewFrame(at: 1)
        XCTAssertEqual(mid.images.count, Self.meshImages, "halfway the clip is tilted")
        XCTAssertNotEqual(exportRender(at: 1).frame, exportRender(at: 0).frame, "export animates the tilt")
        guard case .segmented? = find("easing") else { return XCTFail("a keyed tilt gets the easing rows") }
        assertVisualEdit("Tilt easing", at: 1, { pick("easing", "hold") }) { c in
            XCTAssertEqual(c.images.count, 1, "held at the flat first key until 2 s")
        }
    }

    /// The shared projection: a positive Tilt X under a lens draws the top edge narrower than the bottom.
    func testProjectionForeshortensTheFarEdge() {
        let t = NativeTransform3D(rotationX: 30, perspective: 300)
        let top = t.project(50, -50), bottom = t.project(50, 50)
        XCTAssertLessThan(abs(top.x), 50); XCTAssertGreaterThan(abs(bottom.x), 50)
        XCTAssertTrue(NativeTransform3D(rotationX: 30).isAffine)
        XCTAssertEqual(NativeTransform3D(z: 50, perspective: 100).project(10, 0).x, 20, accuracy: 1e-9)
    }
}
