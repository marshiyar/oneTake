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

/// Grade › Secondary color › "Sample color from frame": capture the clip's frame,
/// click a colour to key the selection, check the matte. The key re-grades what the preview and the export draw.
extension InspectorRenderAuditTests {
    /// 20x10: the left half red, the right half green.
    static let redGreen: CanvasImage = {
        var px = [UInt8](repeating: 255, count: 20 * 10 * 4)
        for y in 0..<10 { for x in 0..<20 {
            let o = (y * 20 + x) * 4
            (px[o], px[o + 1], px[o + 2]) = x < 10 ? (230, 20, 20) : (20, 200, 20)
        } }
        return CanvasImage(width: 20, height: 10, rgba: px)
    }()

    func clickHit(_ hit: InspectorPanel.Hit, fx: Double = 0.5, fy: Double = 0.5, file: StaticString = #filePath, line: UInt = #line) {
        inspector.draw(AuditCanvas(), in: CanvasRect(x: 0, y: 0, width: 320, height: 4000))
        guard let r = inspector.hits.rect(where: { $0 == hit }) else { return XCTFail("\(hit) is not drawn", file: file, line: line) }
        let p = CanvasPoint(r.x + r.width * fx, r.y + r.height * fy)
        _ = inspector.pointerDown(p); inspector.pointerUp(p)
    }

    /// The clip's grade applied to the red/green frame, as the preview grades its frames and as export grades the clip.
    func gradedRedGreen() -> (preview: [UInt8], export: [UInt8]) {
        let comp = PreviewComposition(document: editor.document, projectDir: URL(fileURLWithPath: projectDir), engine: engine, fileExists: { _ in true })
        var p = Self.redGreen.rgba, e = Self.redGreen.rgba
        comp.layers(at: 0.5).first?.grade?.apply(&p, width: 20, height: 10, time: 0.5)
        if let clip = editor.clip("V")?.clip { exportGradeRenderer(clip, projectDir: projectDir)?.apply(&e, width: 20, height: 10, time: 0.5) }
        return (p, e)
    }
    func chroma(_ px: [UInt8], x: Int) -> Int { let o = (5 * 20 + x) * 4; return Int(px[o]) - max(Int(px[o + 1]), Int(px[o + 2])) }

    /// A secondary keyed on greens that desaturates what it selects.
    func greenSecondary() {
        inspector.openGroupId = "grade"
        clickHit(.custom("sec:placeholder", 0))
        // The qualifier editor is a hue/saturation/luma track, not sliders: nudge the hue window from the
        // default (centre 0, range 30) to green (lo 60, hi 180) with the track's own arrow keys. Each row
        // commits from the secondary it was built with, so the row is re-read before every press.
        for _ in 0..<15 { XCTAssertTrue(qualifierHueKey(1, EditorKey(.right, shift: true))) }
        for _ in 0..<27 { XCTAssertTrue(qualifierHueKey(0, EditorKey(.left, shift: true))) }
        slide("sec:sat", -100)
    }

    /// The hue track's key handler, rebuilt from the live secondary on every press.
    func qualifierHueKey(_ part: Int, _ key: EditorKey) -> Bool {
        for g in inspector.groups { for r in g.addressableRows {
            if case .custom(let c) = r.kind, c.id == "sec:qualifier:hue" { return c.keyPress?(part, key) == true }
        } }
        XCTFail("no hue qualifier track"); return false
    }

    func testEyedropperKeysTheSelectionFromTheFrame() {
        inspector.scopeFrame = { _, _, _ in .ready(Self.redGreen) }
        greenSecondary()
        let before = gradedRedGreen()
        XCTAssertGreaterThan(chroma(before.preview, x: 2), 150, "keyed on green, the reds keep their colour")
        clickHit(.custom("sec:sample", 0))
        XCTAssertEqual(inspector.grade.sampleFrame, Self.redGreen, "the frame is captured")
        clickHit(.custom("sec:frame", 0), fx: 0.25)   // a red pixel
        let after = gradedRedGreen()
        XCTAssertLessThan(chroma(after.preview, x: 2), 40, "keyed on the sampled red, the preview desaturates the reds")
        XCTAssertLessThan(chroma(after.export, x: 2), 40, "and so does the export's grade")
        XCTAssertEqual(after.preview, after.export, "preview and export grade the frame alike")
        XCTAssertTrue(inspector.grade.showMatte, "the matte shows after a sample")
        let mc = PanelMeasureCanvas()
        inspector.draw(mc, in: CanvasRect(x: 0, y: 0, width: 320, height: 4000))
        XCTAssertTrue(mc.drawnStrings.contains("342° – 18°"), "the hue track shows the sampled red centre and range")
        XCTAssertTrue(editor.undo())
        XCTAssertGreaterThan(chroma(gradedRedGreen().preview, x: 2), 150, "the sample is one undo step")
    }

    func testSelectionMatteShowsTheKey() {
        var key = ColorGrading.Secondary()
        XCTAssertTrue(SecondaryColorKey.sample(Self.redGreen, x: 15, y: 5, into: &key), "a green sample")
        XCTAssertEqual(key.hueCenter, 120, accuracy: 2)
        let matte = SecondaryColorKey.matte(Self.redGreen, key)
        XCTAssertEqual(matte.rgba[(5 * 20 + 15) * 4], 255, "greens are selected")
        XCTAssertEqual(matte.rgba[(5 * 20 + 2) * 4], 0, "reds are not")
        var grey = ColorGrading.Secondary()
        let flat = CanvasImage(width: 4, height: 4, rgba: [UInt8](repeating: 128, count: 64))
        XCTAssertTrue(SecondaryColorKey.sample(flat, x: 1, y: 1, into: &grey))
        XCTAssertEqual(grey.hueRange, 180, "a neutral sample selects every hue")
    }

    func testEyedropperSourceAndMatteTabs() {
        inspector.scopeFrame = { _, _, _ in .ready(Self.redGreen) }
        greenSecondary()
        clickHit(.custom("sec:sample", 0))
        clickHit(.custom("sec:view", 1))
        XCTAssertTrue(inspector.grade.showMatte)
        inspector.draw(AuditCanvas(), in: CanvasRect(x: 0, y: 0, width: 320, height: 4000))
        XCTAssertNil(inspector.hits.rect(where: { $0 == .custom("sec:frame", 0) }), "the matte is not a sampling target")
        clickHit(.custom("sec:view", 0))
        XCTAssertFalse(inspector.grade.showMatte)
    }

    func testEyedropperWaitsForARenderingFrameAndReportsAMissingOne() {
        var state = PresetPreviewState.rendering
        inspector.scopeFrame = { _, _, _ in state }
        greenSecondary()
        clickHit(.custom("sec:sample", 0))
        XCTAssertNil(inspector.grade.sampleFrame)
        state = .ready(Self.redGreen)
        inspector.draw(AuditCanvas(), in: CanvasRect(x: 0, y: 0, width: 320, height: 4000))
        XCTAssertEqual(inspector.grade.sampleFrame, Self.redGreen, "the next draw picks the rendered frame up")
        state = .unavailable
        clickHit(.custom("sec:sample", 0))
        XCTAssertTrue(inspector.grade.sampleError)
        XCTAssertNil(inspector.grade.sampleFrame)
    }
}
