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
#if os(Linux)
import Foundation
import XCTest
import MpvfxCanvas
import MpvfxDesktopCore
import MpvfxPanels
import MpvfxPlayer
import MpvfxTheme
@testable import MpvfxDesktop

/// Issue #106: Settings > Interface size (100–200 %) enlarges every custom-drawn region by one transform at the shell.
final class InterfaceScaleTests: XCTestCase {
    /// Measures like `PanelMeasureCanvas` and records every transform in order (panes scale their icons too, so
    /// the shell's own transform is the first one).
    final class TransformRecordingCanvas: CanvasContext {
        enum Op: Equatable { case translate(Double, Double), scale(Double, Double) }
        private let measure = PanelMeasureCanvas()
        private(set) var ops: [Op] = []
        func save() {}
        func restore() {}
        func translate(_ dx: Double, _ dy: Double) { ops.append(.translate(dx, dy)) }
        func scale(_ sx: Double, _ sy: Double) { ops.append(.scale(sx, sy)) }
        func rotate(_ radians: Double) {}
        func clip(_ path: CanvasPath) {}
        func fill(_ path: CanvasPath, _ color: CanvasColor) {}
        func stroke(_ path: CanvasPath, _ color: CanvasColor, _ style: StrokeStyle) {}
        func drawText(_ text: String, at origin: CanvasPoint, font: CanvasFont, color: CanvasColor) {}
        func measureText(_ text: String, font: CanvasFont) -> CanvasSize { measure.measureText(text, font: font) }
        func drawImage(_ image: CanvasImage, in rect: CanvasRect) {}
    }

    /// Keeps the context the player hands its frame source (what the decoders size frames from).
    final class ContextRecordingSource: FrameSource {
        private(set) var context: FrameDrawContext?
        func draw(_ c: CanvasContext, in rect: CanvasRect, time: Double, elements: [StageElement]) {}
        func draw(_ c: CanvasContext, in rect: CanvasRect, time: Double, elements: [StageElement], context: FrameDrawContext) {
            self.context = context
        }
    }

    var dirs: [String] = []
    override func setUp() { Theme.setMode(.dark) }
    override func tearDown() { for d in dirs { try? FileManager.default.removeItem(atPath: d) }; Theme.setMode(.dark) }

    func temporaryDirectory() throws -> String {
        let d = NSTemporaryDirectory() + "mpvfx-scale-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        dirs.append(d)
        return (d as NSString).resolvingSymlinksInPath
    }

    func shell(_ userData: String) throws -> (EditorSession, EditorShellRouter) {
        let session = try EditorSession(projectPath: nil, demo: true)
        session.postToUI = { body in DispatchQueue.main.async(execute: body) }
        let router = session.installShell(userData: userData) {}
        addTeardownBlock { session.audio?.stop() }
        return (session, router)
    }

    func testInterfaceSizeRowPersistsAndAppliesAtOnce() throws {
        XCTAssertEqual(SettingsPanel.interfaceSizeChoices, DesktopPreferences.interfaceScaleChoices, "the card offers what is kept")
        let userData = try temporaryDirectory()
        let (session, router) = try shell(userData)
        var redraws = 0
        session.redraw = { redraws += 1 }
        XCTAssertEqual(router.interfaceScale, 1)
        XCTAssertEqual(session.settingsPanel.values.interfaceScalePercent, 100)
        var v = session.settingsPanel.values
        v.interfaceScalePercent = 200
        session.settingsPanel.onChange?(v)
        XCTAssertEqual(router.interfaceScale, 2, "applied at once")
        XCTAssertGreaterThan(redraws, 0, "and redrawn")
        XCTAssertEqual(DesktopPreferences(userData: userData).interfaceScalePercent, 200, "kept in preferences.json")
        XCTAssertNil(session.settingsPanel.saveError)

        let (again, againRouter) = try shell(userData)
        XCTAssertEqual(againRouter.interfaceScale, 2, "a relaunch opens at the stored size")
        again.showSettings()
        XCTAssertEqual(again.settingsPanel.values.interfaceScalePercent, 200)
    }

    func testShellDrawsScaledAndLaysOutInTheWindowDividedByK() throws {
        let (_, router) = try shell(try temporaryDirectory())
        let c = TransformRecordingCanvas()
        router.draw(c, size: CanvasSize(1440, 900))
        if case .scale? = c.ops.first { XCTFail("100 %: the shell adds no transform, \(c.ops.prefix(2))") }
        XCTAssertEqual(router.frames?.size, CanvasSize(1440, 900))

        router.interfaceScale = 2
        let scaled = TransformRecordingCanvas()
        router.draw(scaled, size: CanvasSize(2560, 1600))
        XCTAssertEqual(scaled.ops.first, .scale(2, 2), "scale(k, k) before any pane draws")
        XCTAssertEqual(router.frames?.size, CanvasSize(1280, 800))
        router.resized(CanvasSize(2880, 1800))
        XCTAssertEqual(router.frames?.size, CanvasSize(1440, 900))
        router.interfaceScale = 1.5
        router.resized(CanvasSize(1500, 900))
        XCTAssertEqual(router.frames?.size, CanvasSize(1000, 600))
    }

    /// The same layout at 100 % in a 1440 × 900 window and at 200 % in a 2880 × 1800 one: a press at twice the
    /// point grabs the same dock splitter and focuses the same inspector field.
    func testClickOnASeamAndAnInspectorFieldAt200PercentHitsTheSameControl() throws {
        var fields: [String?] = []
        for k in [1.0, 2.0] {
            let (session, router) = try shell(try temporaryDirectory())
            router.interfaceScale = k
            session.timeline.view.selection = ["clip:a"]
            router.draw(PanelMeasureCanvas(), size: CanvasSize(1440 * k, 900 * k))
            let f = try XCTUnwrap(router.frames)
            XCTAssertEqual(f.size, CanvasSize(1440, 900))

            let splitter = try XCTUnwrap(router.dock.geometry.splitters.first { $0.axis == .row })
            let seam = splitter.seam
            let seamMid = CanvasPoint(seam.x + seam.width / 2, seam.y + seam.height / 2)
            XCTAssertEqual(router.cursor(at: seamMid.x * k, seamMid.y * k), .columnResize, "at \(k)")
            router.pointerDown(x: seamMid.x * k, y: seamMid.y * k, button: PointerButton.primary, modifiers: [])
            XCTAssertEqual(router.dock.splitterDrag?.splitter, splitter, "at \(k)")
            router.pointerUp(x: seamMid.x * k, y: seamMid.y * k, button: PointerButton.primary)

            let inspector = try XCTUnwrap(session.panels?.right.inspector)
            let entry = try XCTUnwrap(inspector.hits.regions.first { if case .field = $0.action { return true }; return false })
            guard case .field(let key) = entry.action else { return XCTFail("not a field") }
            let p = CanvasPoint(f.right.x + entry.rect.x + entry.rect.width / 2, f.right.y + entry.rect.y + entry.rect.height / 2)
            router.pointerDown(x: p.x * k, y: p.y * k, button: PointerButton.primary, modifiers: [])
            router.pointerUp(x: p.x * k, y: p.y * k, button: PointerButton.primary)
            XCTAssertEqual(inspector.field?.key, key, "at \(k)")
            fields.append(inspector.field?.key)
        }
        XCTAssertEqual(fields.count, 2)
        XCTAssertNotNil(fields.first ?? nil)
        XCTAssertEqual(fields.first ?? nil, fields.last ?? nil)
    }

    /// The preview decodes at k times the display's pixel density, so the picture stays sharp when enlarged.
    func testPreviewDecodesAtKTimesTheBackingScale() throws {
        var backing: [Double] = []
        for k in [1.0, 2.0] {
            let (session, router) = try shell(try temporaryDirectory())
            router.interfaceScale = k
            let source = ContextRecordingSource()
            session.player.view.frameSource = source
            let target = CairoImageTarget(width: Int(1280 * k), height: Int(800 * k))
            router.draw(target.canvas, size: CanvasSize(1280 * k, 800 * k))
            backing.append(try XCTUnwrap(source.context).backingScale)
        }
        XCTAssertEqual(backing, [1, 2])
        let l = PreviewLayer(clipId: "clip:a", source: "/media/a.mp4", kind: .video, start: 0, end: 4, sourceIn: 0,
                             box: CanvasRect(x: 0, y: 0, width: 1920, height: 1080))
        let at100 = PreviewPainter.screenPixels(l, viewScale: 0.5, backingScale: backing[0])
        let at200 = PreviewPainter.screenPixels(l, viewScale: 0.5, backingScale: backing[1])
        XCTAssertEqual(at200.width, 2 * at100.width, accuracy: 1e-9)
        XCTAssertEqual(at200.height, 2 * at100.height, accuracy: 1e-9)
    }

    /// At 200 % a 1280 × 800 window lays out in 640 × 400: every active dock pane keeps a size
    /// and the status line's own hints fit unclipped (Pango measures them).
    func testEveryPaneStaysReachableAt200PercentIn1280By800() throws {
        let (_, router) = try shell(try temporaryDirectory())
        router.interfaceScale = 2
        let target = CairoImageTarget(width: 1280, height: 800)
        router.draw(target.canvas, size: CanvasSize(1280, 800))
        let f = try XCTUnwrap(router.frames)
        for region in [EditorShellRouter.Region.left, .previewTopBar, .player, .right, .timeline] {
            let r = router.rect(region, f)
            XCTAssertGreaterThan(r.width, 0, "\(region)")
            XCTAssertGreaterThan(r.height, 0, "\(region)")
            XCTAssertLessThanOrEqual(r.maxX, 640, "\(region)")
            XCTAssertLessThanOrEqual(r.maxY, 400, "\(region)")
        }
        XCTAssertEqual(router.dock.layout.openPanels, ["media", "preview", "inspector", "renders", "timeline"])
        XCTAssertEqual(f.statusLine.height, ShellStatusLine.height, accuracy: 1e-9)
        let hints = Array(EditorShellRouter.regionHints.values)
        for hint in hints {
            let w = target.canvas.measureText(hint, font: PanelTheme.font(11)).width
            XCTAssertLessThanOrEqual(w, f.statusLine.width - 16, hint)
        }
    }
}
#endif
