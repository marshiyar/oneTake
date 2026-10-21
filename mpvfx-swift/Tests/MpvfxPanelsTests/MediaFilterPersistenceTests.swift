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

final class MediaFilterPersistenceTests: XCTestCase {
    func panel(_ store: PanelPreferencesStore) -> LeftSidebarPanel {
        let p = LeftSidebarPanel(layout: PanelLayoutState(store: store, viewportWidth: 1440))
        p.items = MediaPanelFixture.items()
        return p
    }

    func testFilterAndSortSurviveAFileStoreRelaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("panel-layout.json")
        let p = panel(FilePanelPreferencesStore(url: url))
        p.applyFilterOption("kind:video")
        p.applyFilterOption("usage:notInTimeline")
        p.applyFilterOption("sort:duration")

        let reopened = panel(FilePanelPreferencesStore(url: url))
        XCTAssertEqual(reopened.filter, MediaFilter(kind: .video, usage: .notInTimeline, sort: .duration))
        XCTAssertEqual(reopened.sections, p.sections)
        XCTAssertEqual(reopened.sections.flatMap(\.tiles), [.media("media/b-roll.mov")])
    }

    func testKeyboardSortAndClearPersistAcrossPanelRecreation() throws {
        let store = MemoryPanelPreferencesStore()
        let p = panel(store)
        p.draw(PanelMeasureCanvas(), size: CanvasSize(364, 900))
        p.focus.current = .filter
        p.focus.visible = true
        XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        let index = try XCTUnwrap(p.dropdown.options.firstIndex { $0.value == "sort:name" })
        for _ in 0...index { XCTAssertTrue(p.keyDown(EditorKey(.down))) }
        XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        XCTAssertEqual(panel(store).filter.sort, .name)
        XCTAssertEqual(panel(store).sections.first?.tiles.first, .media("media/b-roll.mov"))

        p.draw(PanelMeasureCanvas(), size: CanvasSize(364, 900))
        p.focus.current = .clearFilters
        p.focus.visible = true
        XCTAssertTrue(p.keyDown(EditorKey(.enter)))
        XCTAssertNil(store.value.mediaFilter)
        XCTAssertTrue(panel(store).filter.isDefault)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.value)) as? [String: Any]
        XCTAssertNil(json?["mediaFilter"], "clearing omits the saved choices")
    }

    func testOlderPreferencesDefaultWithoutChangingOtherSettings() throws {
        let data = Data(#"{"leftWidth":320,"sidebarTab":"assets"}"#.utf8)
        let old = try JSONDecoder().decode(PanelPreferences.self, from: data)
        let store = MemoryPanelPreferencesStore(old)
        XCTAssertTrue(panel(store).filter.isDefault)
        XCTAssertEqual(store.value, old, "opening does not write preferences")
        XCTAssertEqual(store.value.leftWidth, 320)
    }

    func testUnknownAndMissingChoicesFallBackIndependently() throws {
        let data = Data(#"{"leftWidth":320,"mediaFilter":{"kind":"futureKind","usage":"notInTimeline","sort":"futureSort"}}"#.utf8)
        let prefs = try JSONDecoder().decode(PanelPreferences.self, from: data)
        let p = panel(MemoryPanelPreferencesStore(prefs))
        XCTAssertEqual(p.filter, MediaFilter(usage: .notInTimeline))
        XCTAssertEqual(p.layout.prefs.leftWidth, 320)
        XCTAssertEqual(try JSONDecoder().decode(MediaFilter.self, from: Data("{}".utf8)), MediaFilter())
    }
}
