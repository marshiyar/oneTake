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
import MpvfxCanvas
import MpvfxTimeline
@testable import MpvfxPanels

final class DockedScopesPanelTests: XCTestCase {
    func testRegisteredScopesCanDockBesidePreviewWithoutChangingTheDefaultWorkspace() throws {
        let registry = DockRegistry.editor
        XCTAssertEqual(registry.spec(DockPanels.scopes)?.title, "Scopes")
        XCTAssertEqual(registry.spec(DockPanels.scopes)?.startsClosed, true)
        var layout = DockDefaults.layout(registry)
        XCTAssertFalse(layout.isOpen(DockPanels.scopes))
        try layout.open(DockPanels.scopes, registry: registry)
        let preview = try XCTUnwrap(layout.root.group(containing: DockPanels.preview))
        try layout.move(DockPanels.scopes, to: .split(group: preview.id, edge: .right))
        XCTAssertTrue(layout.isOpen(DockPanels.scopes))
        XCTAssertNotEqual(layout.root.group(containing: DockPanels.scopes)?.id, layout.root.group(containing: DockPanels.preview)?.id)
    }

    func testEveryScopeChoicePersistsWithTheLayoutWithoutChangingOtherPreferences() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scopes-layout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("panel-layout.json")
        for mode in ScopesPanel.modes {
            let layout = PanelLayoutState(store: FilePanelPreferencesStore(url: url))
            layout.update { $0.leftWidth = 321 }
            let panel = ScopesPanel(layout: layout)
            _ = panel.select(mode)
            let reopened = PanelLayoutState(store: FilePanelPreferencesStore(url: url))
            XCTAssertEqual(ScopesPanel(layout: reopened).mode, mode)
            XCTAssertEqual(reopened.prefs.leftWidth, 321)
        }
    }

    func testUnknownStoredScopeKeepsTheLayoutAndUsesWaveform() throws {
        let data = Data(#"{"leftWidth":321,"scopePanelKind":"future-scope"}"#.utf8)
        let prefs = try JSONDecoder().decode(PanelPreferences.self, from: data)
        let layout = PanelLayoutState(store: MemoryPanelPreferencesStore(prefs))
        XCTAssertEqual(ScopesPanel(layout: layout).mode, .waveform)
        XCTAssertEqual(layout.prefs.leftWidth, 321)
    }

    func testKeyboardAndPointerChooseAllFourScopes() {
        let panel = ScopesPanel(layout: PanelLayoutState(store: MemoryPanelPreferencesStore()))
        panel.draw(PanelMeasureCanvas(), size: CanvasSize(300, 260))
        XCTAssertTrue(panel.keyDown(EditorKey(.right)))
        XCTAssertEqual(panel.mode, .parade)
        XCTAssertTrue(panel.keyDown(EditorKey(.end)))
        XCTAssertEqual(panel.mode, .histogram)
        XCTAssertTrue(panel.keyDown(EditorKey(.home)))
        XCTAssertEqual(panel.mode, .waveform)
        XCTAssertTrue(panel.keyDown(EditorKey(.tab)))
        XCTAssertTrue(panel.keyDown(EditorKey(.enter)))
        XCTAssertEqual(panel.mode, .parade)
        let choice = panel.choices[2]
        XCTAssertTrue(panel.pointerDown(CanvasPoint(choice.x + 2, choice.y + 2), shift: false))
        XCTAssertEqual(panel.mode, .vectorscope)
        XCTAssertFalse(panel.keyDown(EditorKey(.char("s"), ctrl: true)))
    }

    func testEachScopeAnalysesTheKnownProgramFrameWithoutAClipSelection() throws {
        let panel = ScopesPanel(layout: PanelLayoutState(store: MemoryPanelPreferencesStore()))
        let frame = CanvasImage(width: 16, height: 9, rgba: (0..<(16 * 9)).flatMap { _ in [UInt8(255), 0, 0, 255] })
        var requests = 0
        panel.programFrame = { w, h in
            XCTAssertEqual(w, InspectorPanel.scopeFrameSide); XCTAssertEqual(h, InspectorPanel.scopeFrameSide)
            requests += 1
            return .ready(frame)
        }
        for mode in ScopesPanel.modes {
            _ = panel.select(mode)
            panel.draw(PanelMeasureCanvas(), size: CanvasSize(400, 300))
            panel.worker.wait()
            panel.draw(PanelMeasureCanvas(), size: CanvasSize(400, 300))
            XCTAssertEqual(panel.status, "ready")
            let result = try XCTUnwrap(panel.worker.finished?.result)
            XCTAssertEqual(result.request.settings.kinds, [panel.scopeKind])
            XCTAssertEqual(result.analysis.histogram(.red, level: 255), 16 * 9)
            XCTAssertEqual(result.analysis.histogram(.green, level: 0), 16 * 9)
            if mode != .histogram { XCTAssertNotNil(result.traces[panel.scopeKind]) }
        }
        XCTAssertEqual(requests, ScopesPanel.modes.count * 2)
    }

    #if os(Linux)
    func testShrinkingAReadyPanelDoesNotKeepItsPreviousFrameStatus() {
        let panel = ScopesPanel(layout: PanelLayoutState(store: MemoryPanelPreferencesStore()))
        panel.programFrame = { _, _ in .ready(CanvasImage(width: 1, height: 1, rgba: [255, 0, 0, 255])) }
        panel.draw(PanelMeasureCanvas(), size: CanvasSize(400, 300))
        panel.worker.wait()
        panel.draw(PanelMeasureCanvas(), size: CanvasSize(400, 300))
        XCTAssertEqual(panel.status, "ready")
        panel.draw(PanelMeasureCanvas(), size: CanvasSize(60, 70))
        XCTAssertEqual(panel.status, "enlarge panel")
    }

    func testKnownFrameChangesThePaintedScopePixels() {
        let panel = ScopesPanel(layout: PanelLayoutState(store: MemoryPanelPreferencesStore()))
        let size = CanvasSize(400, 300)
        let empty = CairoImageTarget(width: 400, height: 300)
        panel.draw(empty.canvas, size: size)
        panel.programFrame = { _, _ in .ready(CanvasImage(width: 16, height: 9, rgba: [UInt8](repeating: 255, count: 16 * 9 * 4))) }
        panel.draw(PanelMeasureCanvas(), size: size)
        panel.worker.wait()
        let ready = CairoImageTarget(width: 400, height: 300)
        panel.draw(ready.canvas, size: size)
        XCTAssertEqual(panel.status, "ready")
        let before = empty.straightRGBA(), after = ready.straightRGBA()
        let changedPlotPixels = (100..<290).reduce(0) { count, y in
            count + (40..<390).filter { x in
                let i = (y * 400 + x) * 4
                return before[i] != after[i] || before[i + 1] != after[i + 1] || before[i + 2] != after[i + 2]
            }.count
        }
        XCTAssertGreaterThan(changedPlotPixels, 100)
    }
    #endif
}
