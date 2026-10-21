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

final class DockGeometryTests: XCTestCase {
    let registry = DockRegistry.editor

    func geometry(_ w: Double, _ h: Double, _ layout: DockLayout? = nil) -> DockGeometry {
        DockGeometry.compute(layout ?? DockDefaults.layout(registry), registry: registry, in: CanvasRect(x: 0, y: 0, width: w, height: h))
    }

    func frame(_ g: DockGeometry, _ panel: DockPanelID) throws -> CanvasRect { try XCTUnwrap(g.frame(containing: panel)?.frame, panel) }

    /// Groups tile the rect edge to edge with 1 pt seams: no overlap, no gap, whole points.
    func assertTiles(_ g: DockGeometry, file: StaticString = #filePath, line: UInt = #line) {
        let area = g.groups.map { $0.frame.width * $0.frame.height }.reduce(0, +)
        let seams = g.splitters.map { $0.seam.width * $0.seam.height }.reduce(0, +)
        XCTAssertEqual(area + seams, g.bounds.width * g.bounds.height, accuracy: 1e-6, "groups and seams cover the dock", file: file, line: line)
        for (i, a) in g.groups.enumerated() {
            for v in [a.frame.x, a.frame.y, a.frame.width, a.frame.height] { XCTAssertEqual(v, v.rounded(), file: file, line: line) }
            XCTAssertGreaterThanOrEqual(a.frame.width, 0, file: file, line: line)
            for b in g.groups[(i + 1)...] {
                let overlapW = min(a.frame.maxX, b.frame.maxX) - max(a.frame.x, b.frame.x)
                let overlapH = min(a.frame.maxY, b.frame.maxY) - max(a.frame.y, b.frame.y)
                XCTAssertFalse(overlapW > 0 && overlapH > 0, "\(a.group.id) overlaps \(b.group.id)", file: file, line: line)
            }
        }
    }

    func testTheDefaultLayoutAt1440x900KeepsTheShellProportions() throws {
        let g = geometry(1440, 877)
        assertTiles(g)
        XCTAssertEqual(try frame(g, "media").width, 369)
        XCTAssertEqual(try frame(g, "inspector").width, 408)
        XCTAssertEqual(try frame(g, "timeline").height, 360 + PanelTabStrip.height, accuracy: 1)
        XCTAssertEqual(try frame(g, "preview").x, 370, "1 pt seam after the media group")
        let preview = try XCTUnwrap(g.frame(containing: "preview"))
        XCTAssertEqual(preview.strip.height, PanelTabStrip.height)
        XCTAssertEqual(preview.content.y, preview.frame.y + PanelTabStrip.height)
        XCTAssertEqual(g.splitters.count, 3)
    }

    func testMinimumSizesHoldWhileTheyFit() throws {
        for (w, h) in [(1280.0, 777.0), (1000, 700), (845, 600)] {
            let g = geometry(w, h)
            assertTiles(g)
            XCTAssertGreaterThanOrEqual(try frame(g, "media").width, PanelFit.minLeft, "\(w)")
            XCTAssertGreaterThanOrEqual(try frame(g, "preview").width, PanelFit.minPreviewWidth, "\(w)")
            XCTAssertGreaterThanOrEqual(try frame(g, "inspector").width, PanelFit.minRight, "\(w)")
            XCTAssertGreaterThanOrEqual(try frame(g, "timeline").height, PanelFit.minTimelineHeight + PanelTabStrip.height, "\(h)")
        }
    }

    func testAWindowSmallerThanTheMinimumsShrinksEveryoneInProportion() throws {
        let g = geometry(500, 300)
        assertTiles(g)
        let widths = try ["media", "preview", "inspector"].map { try frame(g, $0).width }
        XCTAssertEqual(widths.reduce(0, +) + 2, 500)
        XCTAssertTrue(widths.allSatisfy { $0 > 0 })
        XCTAssertGreaterThan(widths[1], widths[0], "the preview's larger minimum keeps the larger share")
        let tiny = geometry(3, 2)
        assertTiles(tiny)
        XCTAssertTrue(tiny.groups.allSatisfy { $0.frame.width >= 0 && $0.frame.height >= 0 })
        assertTiles(geometry(0, 0))
    }

    func testDistributeSharesByWeightAndFixesChildrenAtTheirMinimum() {
        XCTAssertEqual(DockGeometry.distribute([0.5, 0.5], total: 100, minimums: [0, 0]), [50, 50])
        XCTAssertEqual(DockGeometry.distribute([0.1, 0.9], total: 100, minimums: [30, 0]), [30, 70])
        XCTAssertEqual(DockGeometry.distribute([1, 1, 1], total: 100, minimums: [0, 0, 0]), [33, 34, 33])
        XCTAssertEqual(DockGeometry.distribute([1, 1], total: 50, minimums: [60, 40]), [30, 20])
    }

    func testDraggingASplitterStopsAtBothSidesMinimums() throws {
        let g = geometry(1440, 877)
        let left = try XCTUnwrap(g.splitters.first { $0.axis == .row && $0.index == 0 })
        var l = DockDefaults.layout(registry)
        try l.setWeights(at: left.path, DockGeometry.weights(dragging: left, by: -10_000))
        XCTAssertEqual(try frame(geometry(1440, 877, l), "media").width, PanelFit.minLeft, accuracy: 1)
        try l.setWeights(at: left.path, DockGeometry.weights(dragging: left, by: 10_000))
        XCTAssertEqual(try frame(geometry(1440, 877, l), "preview").width, PanelFit.minPreviewWidth, accuracy: 1)
        XCTAssertEqual(try frame(geometry(1440, 877, l), "inspector").width, 408, "the other side of the row keeps its width")
        let row = DockGeometry.weights(dragging: left, by: .nan)
        XCTAssertEqual(row.count, 3)
        XCTAssertTrue(row.allSatisfy { $0.isFinite && $0 > 0 })
    }

    func testResettingASplitterRestoresThePreferredSize() throws {
        var l = DockDefaults.layout(registry)
        let left = try XCTUnwrap(geometry(1440, 877).splitters.first { $0.axis == .row && $0.index == 0 })
        try l.setWeights(at: left.path, DockGeometry.weights(dragging: left, by: 200))
        let moved = try XCTUnwrap(geometry(1440, 877, l).splitters.first { $0.axis == .row && $0.index == 0 })
        try l.setWeights(at: moved.path, DockGeometry.weights(resetting: moved))
        XCTAssertEqual(try frame(geometry(1440, 877, l), "media").width, 370, accuracy: 1, "media's preferred 370 pt")
        let bottom = try XCTUnwrap(geometry(1440, 877, l).splitters.first { $0.axis == .column })
        try l.setWeights(at: bottom.path, DockGeometry.weights(resetting: bottom))
        XCTAssertEqual(try frame(geometry(1440, 877, l), "timeline").height, 360 + PanelTabStrip.height, accuracy: 1)
    }

    func testSplitterBandsAreTheShellsSeamHitWidth() {
        for s in geometry(1440, 877).splitters {
            let across = s.axis == .row ? s.hit.width : s.hit.height
            XCTAssertEqual(across, PanelTheme.seamHitWidth)
            XCTAssertEqual(s.axis == .row ? s.hit.midX : s.hit.midY, s.axis == .row ? s.seam.midX : s.seam.midY, accuracy: 1e-9)
        }
    }
}
