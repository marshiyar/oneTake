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
import MpvfxShared
import MpvfxTheme
import MpvfxTimeline
import OneTakeKeyframes
@testable import MpvfxPanels

/// The Grade curve graph keeps its line inside its box: the user's screenshot (R curve with a point at the bottom
/// ~60% across and one at about (0.6, 0.65)) drew a spline that overshot far above 1 and ran up through the colour
/// wheels above the graph. The evaluator is the renderer's monotone cubic, and the drawing is clipped to the graph.
final class CurveGraphTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark) }

    /// The screenshot's R curve: bottom-left, on the floor ~60% across, a steep rise to about (0.6, 0.65), top-right.
    static let screenshotCurve: [[Double]] = [[0, 0], [0.58, 0], [0.62, 0.65], [1, 1]]

    /// RGB point sets that used to draw (or could draw) outside the graph.
    static let rgbExtremes: [[[Double]]] = [
        screenshotCurve,
        [[0, 0], [0.5, 0], [0.5001, 1], [1, 1]],                       // a nearly vertical segment
        [[0, 1], [1, 0]],                                              // inverted, points on the corners
        [[0, 0], [0.1, 1], [0.2, 0], [0.3, 1], [0.4, 0], [1, 1]],     // zigzag
        [[0, 0], [0.02, 1], [1, 1]], [[0, 0], [0.98, 0], [1, 1]],     // steep at an edge
        [[-0.3, 1.4], [0.5, -0.2], [1.4, 0.5]],                        // stored points outside the range
        [[0.7, 0.2], [0.3, 0.9], [0.5, 0.5]],                          // unsorted, no end points
        [[0.2, 0.9], [0.8, 0.1]],                                      // endpoints dragged inward
    ]

    /// Hue curves (degrees, delta) with the hue tabs' ranges.
    static let hueExtremes: [(points: [[Double]], limit: ClosedRange<Double>)] = [
        ([[0, 180], [10, -180], [20, 180], [359, -180]], -180...180),
        ([[30, 1], [31, -1], [200, 1]], -1...1),
        ([[0, 0.9], [120, -0.9], [240, 0.9]], -1...1),
        ([[-20, 2], [400, -3], [180, 0.5]], -1...1),                   // stored outside the range: wrapped and clamped
        ([[90, 1]], -1...1), ([[90, 1], [100, -1]], -1...1),           // too few points: the renderer applies nothing
    ]

    // MARK: Numbers

    /// The evaluated curve stays in 0…1 everywhere, and between two neighbouring points it is monotone and stays
    /// between their values (no overshoot). The old graph spline reached about 1.21 on the screenshot curve.
    func testRgbCurveStaysInRangeAndMonotoneBetweenPoints() {
        Self.rgbExtremes.forEach { assertBoundedAndMonotone($0) }
        let ends = (0...1000).map { ColorCurveMath.sample(Self.screenshotCurve, at: Double($0) / 1000) }
        XCTAssertEqual(ends, ends.sorted(), "monotone points give a monotone curve end to end")
        XCTAssertEqual(ColorCurveMath.sample(Self.screenshotCurve, at: 0.3), 0, accuracy: 1e-12, "flat on the floor before the rise")
    }

    func testHueCurveStaysInRange() {
        Self.hueExtremes.forEach { c in
            let out = (0...3600).map { Double($0) / 10 }.filter { !c.limit.contains(ColorCurveMath.sampleHue(c.points, at: $0, limit: c.limit)) }
            XCTAssertEqual(out, [], "\(c.points): out of \(c.limit) at these hues")
        }
        XCTAssertEqual(ColorCurveMath.sampleHue([[90, 1], [100, -1]], at: 95, limit: -1...1), 0, "two points: flat, as rendered")
    }

    func assertBoundedAndMonotone(_ raw: [[Double]], file: StaticString = #filePath, line: UInt = #line) {
        let outside = (0...4000).map { Double($0) / 4000 }.filter { !(0...1).contains(ColorCurveMath.sample(raw, at: $0)) }
        XCTAssertEqual(outside, [], "\(raw): out of 0…1 at these inputs", file: file, line: line)
        let pts = GradeCurve.normalizedRGB(raw)
        for (a, b) in zip(pts, pts.dropFirst()) {
            let v = (0...200).map { ColorCurveMath.sample(raw, at: a[0] + (b[0] - a[0]) * Double($0) / 200) }
            let lo = min(a[1], b[1]) - 1e-9, hi = max(a[1], b[1]) + 1e-9
            XCTAssertTrue(v.allSatisfy { $0 >= lo && $0 <= hi }, "\(raw): overshoots between \(a) and \(b)", file: file, line: line)
            XCTAssertTrue(zip(v, v.dropFirst()).allSatisfy { b[1] >= a[1] ? $1 >= $0 - 1e-12 : $1 <= $0 + 1e-12 },
                          "\(raw): not monotone between \(a) and \(b)", file: file, line: line)
        }
    }

    // MARK: Drawing (any canvas)

    /// Every vertex of the drawn curve line lies inside the graph's plot box and the line and the point markers are
    /// drawn under a clip inside the graph, for every curve tab and every extreme point set, in both modes.
    func testCurveLineAndPointsStayInsideTheGraph() throws {
        let problems = try ThemeMode.allCases.flatMap { mode in
            Theme.setMode(mode)
            return try InspectorPanel.curveTabs.flatMap { tab in
                try (tab.hue ? Self.hueExtremes.map(\.points) : Self.rgbExtremes).flatMap { try geometryProblems(tab, $0) }
            }
        }
        XCTAssertEqual(problems, [])
    }

    /// What is wrong with the drawn curve for `pts` on `tab` (empty: nothing).
    func geometryProblems(_ tab: (key: String, label: String, color: ThemePair, hue: Bool, min: Double, max: Double), _ pts: [[Double]]) throws -> [String] {
        let r = try Self.panel(tab: tab.key, points: pts)
        let rec = RecordingCanvas()
        r.draw(rec, size: CanvasSize(409, 1900))
        let box = r.inspector.grade.curveBox, u = box.width / 144, frame = Self.graphFrame(box)
        let color = CanvasColor(tab.color.now), outline = CanvasColor(ThemeTokens.curvePointOutlinePair.now)
        let line = rec.ops.filter { $0.isStroke && $0.color == color && abs($0.width - 1.5 * u) < 1e-9 }
        let markers = zip(rec.ops, rec.ops.dropFirst()).filter { !$0.0.isStroke && $0.1.isStroke && $0.1.color == outline && abs($0.1.width - u) < 1e-9 }.map(\.0)
        let what = "\(Theme.mode) \(tab.key) \(pts)"
        var problems: [String] = []
        if line.count != 1 { problems.append("\(what): \(line.count) curve lines, want 1") }
        // One marker per point the renderer reads (the end points it adds included, none for a hue curve too short to
        // render), so every bend of the line has a handle and no handle sits off the line.
        let rendered = tab.hue ? GradeCurve.normalizedHue(pts, limit: tab.min...tab.max).count : GradeCurve.normalizedRGB(pts).count
        if markers.count != rendered { problems.append("\(what): \(markers.count) point markers, want \(rendered)") }
        let stray = line.flatMap(\.points).filter { !(Self.contains(box, $0)) }
        if !stray.isEmpty { problems.append("\(what): line vertices outside the graph \(box): \(stray.prefix(3))") }
        let clips = (line + markers).map(\.clip)
        if !clips.allSatisfy({ $0.map { Self.contains(frame, CanvasPoint($0.x, $0.y)) && Self.contains(frame, CanvasPoint($0.maxX, $0.maxY)) } ?? false }) {
            problems.append("\(what): curve drawing not clipped inside the graph \(frame): \(clips)")
        }
        return problems
    }

    /// The bordered graph (view box 0…160 around the 8…152 plot box, plus its 1px border).
    static func graphFrame(_ box: CanvasRect) -> CanvasRect {
        let u = box.width / 144
        return CanvasRect(x: box.x - 8 * u - 1, y: box.y - 8 * u - 1, width: box.width + 16 * u + 2, height: box.height + 16 * u + 2)
    }
    static func contains(_ r: CanvasRect, _ p: CanvasPoint) -> Bool {
        p.x >= r.x - 1e-9 && p.x <= r.maxX + 1e-9 && p.y >= r.y - 1e-9 && p.y <= r.maxY + 1e-9
    }

    #if os(Linux)   // Cairo pixels
    /// Pixels: with the screenshot curve and the steepest sets on every tab, everything outside the graph's frame is
    /// exactly what the panel shows with the default curve, so no part of the line lands on the rows around it.
    /// MPVFX_SNAPSHOT_DIR writes `curve-graph-<tab>-<mode>.png` (the screenshot curve / first hue set) for review.
    func testCurveDrawingChangesNoPixelOutsideTheGraph() throws {
        let problems = try ThemeMode.allCases.flatMap { mode in
            Theme.setMode(mode)
            return try InspectorPanel.curveTabs.flatMap { try pixelProblems($0) }
        }
        XCTAssertEqual(problems, [])
    }

    func pixelProblems(_ tab: (key: String, label: String, color: ThemePair, hue: Bool, min: Double, max: Double)) throws -> [String] {
        // The steepest sets (the geometry test covers the rest on any canvas).
        let sets: [[[Double]]] = tab.hue ? Self.hueExtremes.prefix(3).map(\.points) : Array(Self.rgbExtremes.prefix(4))
        let plain = try Self.panel(tab: tab.key, points: tab.hue ? [] : GradeCurve.identity)
        let base = render(plain).straightRGBA(), frame = Self.graphFrame(plain.inspector.grade.curveBox)
        var problems: [String] = []
        for (k, pts) in sets.enumerated() {
            let edited = try Self.panel(tab: tab.key, points: pts)
            let t = render(edited)
            // Besides the graph, an edited curve changes only its own controls (issue #177): the tab's "edited" mark
            // and the footer buttons that now have something to reset.
            let controls = edited.inspector.hits.regions.filter {
                if case .custom(let id, _) = $0.action { return id == "grade:curvetabs" || id == "grade:curvefoot" }
                return false
            }.map(\.rect)
            if k == 0, let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                _ = t.writePNG("\(dir)/curve-graph-\(tab.key)-\(Theme.mode.rawValue).png")
            }
            let px = t.straightRGBA()
            let changedOffsets: [Int] = stride(from: 0, to: px.count, by: 4).filter { (i: Int) -> Bool in
                px[i] != base[i] || px[i + 1] != base[i + 1] || px[i + 2] != base[i + 2]
            }
            let changed: [CanvasPoint] = changedOffsets.map { (i: Int) -> CanvasPoint in
                let pixel = i / 4
                return CanvasPoint(Double(pixel % 409) + 0.5, Double(pixel / 409) + 0.5)
            }
            let outside = changed.filter { p in !Self.contains(frame, p) && !controls.contains { Self.contains($0.insetBy(-1), p) } }
            if !outside.isEmpty { problems.append("\(Theme.mode) \(tab.key) \(pts): \(outside.count) pixels changed outside the graph \(frame), e.g. \(outside.prefix(3))") }
            if changed.isEmpty { problems.append("\(Theme.mode) \(tab.key) \(pts): the curve did not change the graph") }
        }
        return problems
    }

    func render(_ r: RightPanel) -> CairoImageTarget {
        let t = CairoImageTarget(width: 409, height: 1900)
        t.canvas.fillRect(CanvasRect(x: 0, y: 0, width: 409, height: 1900), PanelTheme.studioBg)
        r.draw(t.canvas, size: CanvasSize(409, 1900))
        return t
    }
    #endif

    /// Dragging a point past its neighbour keeps the order (no two points on one input, which the renderer rejects).
    func testDraggedPointStaysBetweenNeighbours() {
        let pts: [[Double]] = [[0, 0], [0.4, 0.2], [0.6, 0.8], [1, 1]]
        XCTAssertEqual(InspectorPanel.draggedCurvePoint([0.9, 0.5], index: 1, in: pts, hue: false), [0.59, 0.5])
        XCTAssertEqual(InspectorPanel.draggedCurvePoint([0.1, 0.5], index: 2, in: pts, hue: false), [0.41, 0.5])
        XCTAssertEqual(InspectorPanel.draggedCurvePoint([0.5, 1], index: 0, in: pts, hue: false), [0.39, 1])
        XCTAssertEqual(InspectorPanel.draggedCurvePoint([200, 0.5], index: 1, in: [[0, 0], [90, 0], [180, 0]], hue: true), [179, 0.5])
    }

    static func panel(tab: String, points: [[Double]]) throws -> RightPanel {
        let r = RightPanel(layout: PanelLayoutState(store: MemoryPanelPreferencesStore(), viewportWidth: 1440))
        r.inspector.editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try? KeyframeRuntime())
        r.inspector.selection = ["clip:a"]
        r.inspector.toggleGroup("grade")
        var g = ColorGrading()
        // A curve on another tab too, so every case (the default curve included) is an authored grade and the
        // group header reads the same; only the graph differs between cases.
        if tab == "hueVsLuma" { g.curves["master"] = [[0, 0], [0.5, 0.6], [1, 1]] } else { g.hueCurves["hueVsLuma"] = [[0, 0.1], [120, 0.1], [240, 0.1]] }
        if InspectorPanel.curveTabs.first(where: { $0.key == tab })?.hue == true { g.hueCurves[tab] = points } else { g.curves[tab] = points }
        XCTAssertTrue(r.inspector.editor?.setColorGrading(clipId: "clip:a", g) ?? false)
        r.inspector.grade.curveTab = tab
        return r
    }
}

/// Records fills and strokes with their vertices in canvas coordinates (translate and scale applied), the stroke
/// width and the bounds of the active clip, so geometry checks run without a pixel backend.
final class RecordingCanvas: CanvasContext {
    struct Op { var color: CanvasColor; var isStroke: Bool; var width: Double; var points: [CanvasPoint]; var clip: CanvasRect? }
    private struct State { var tx = 0.0, ty = 0.0, sx = 1.0, sy = 1.0; var clip: CanvasRect? }
    private(set) var ops: [Op] = []
    private var state = State()
    private var stack: [State] = []
    func save() { stack.append(state) }
    func restore() { if let s = stack.popLast() { state = s } }
    func translate(_ dx: Double, _ dy: Double) { state.tx += dx * state.sx; state.ty += dy * state.sy }
    func scale(_ sx: Double, _ sy: Double) { state.sx *= sx; state.sy *= sy }
    func rotate(_ radians: Double) {}
    private func vertices(_ path: CanvasPath) -> [CanvasPoint] {
        var pts: [CanvasPoint] = []
        for e in path.elements {
            switch e {
            case .move(let p), .line(let p): pts.append(p)
            case .curve(let a, let b, let p): pts += [a, b, p]
            case .close: break
            }
        }
        return pts.map { CanvasPoint(state.tx + $0.x * state.sx, state.ty + $0.y * state.sy) }
    }
    func clip(_ path: CanvasPath) {
        let v = vertices(path)
        guard let x0 = v.map(\.x).min(), let x1 = v.map(\.x).max(), let y0 = v.map(\.y).min(), let y1 = v.map(\.y).max() else { return }
        var r = CanvasRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        if let c = state.clip {   // intersect with the clip already active
            let nx = max(r.x, c.x), ny = max(r.y, c.y)
            r = CanvasRect(x: nx, y: ny, width: max(0, min(r.maxX, c.maxX) - nx), height: max(0, min(r.maxY, c.maxY) - ny))
        }
        state.clip = r
    }
    func fill(_ path: CanvasPath, _ color: CanvasColor) {
        ops.append(Op(color: color, isStroke: false, width: 0, points: vertices(path), clip: state.clip))
    }
    func stroke(_ path: CanvasPath, _ color: CanvasColor, _ style: StrokeStyle) {
        ops.append(Op(color: color, isStroke: true, width: style.width * state.sx, points: vertices(path), clip: state.clip))
    }
    func drawText(_ text: String, at origin: CanvasPoint, font: CanvasFont, color: CanvasColor) {}
    func measureText(_ text: String, font: CanvasFont) -> CanvasSize { CanvasSize(Double(text.count) * font.size * 0.55, font.size) }
    func drawImage(_ image: CanvasImage, in rect: CanvasRect) {}
}
