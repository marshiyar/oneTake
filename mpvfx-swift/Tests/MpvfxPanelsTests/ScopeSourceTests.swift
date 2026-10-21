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

/// The Grade scopes' Clip / Program switch (issue #80): saved in the panel preferences, Clip by default; Program reads
/// the host's composited program frame; analysis never runs on the drawing thread and keeps only the newest request.
final class ScopeSourceTests: XCTestCase {
    let size = CanvasSize(409, 1900)

    /// The right panel on the demo project with clip:a selected and the Grade group open.
    func panel(_ store: PanelPreferencesStore) throws -> RightPanel {
        let r = RightPanel(layout: PanelLayoutState(store: store, viewportWidth: 1440))
        r.inspector.editor = try TimelineEditor(json: TimelineEditor.demoJSON, engine: try? KeyframeRuntime())
        r.inspector.selection = ["clip:a"]
        if r.inspector.openGroupId != "grade" { r.inspector.toggleGroup("grade") }
        return r
    }

    /// Draws, then clicks the hit `part` of the Scopes row.
    func click(_ r: RightPanel, part: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        r.draw(PanelMeasureCanvas(), size: size)
        let hit = try XCTUnwrap(r.inspector.hits.rect { $0 == .custom("grade:scopes", part) }, "part \(part) drawn", file: file, line: line)
        XCTAssertTrue(r.inspector.pointerDown(CanvasPoint(hit.midX, hit.midY)), file: file, line: line)
        r.inspector.pointerUp(CanvasPoint(hit.midX, hit.midY))
    }

    /// A 64×36 frame: a horizontal grey ramp whose level starts at `offset`.
    static func ramp(_ offset: Int = 0) -> CanvasImage {
        var px = [UInt8](repeating: 255, count: 64 * 36 * 4)
        for i in 0..<(64 * 36) { let v = UInt8(min(255, (i % 64) * 3 + offset)); px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v }
        return CanvasImage(width: 64, height: 36, rgba: px)
    }

    var programPart: Int { InspectorPanel.scopeSourcePart + 1 }

    func testTheScopesRowHasAClipProgramSwitchSavedInPreferencesDefaultingToClip() throws {
        let store = MemoryPanelPreferencesStore()
        let r = try panel(store)
        XCTAssertEqual(r.inspector.scopeSource, .clip, "Clip by default, as before")
        try click(r, part: 0)   // open the scopes
        let c = PanelMeasureCanvas()
        r.draw(c, size: size)
        XCTAssertTrue(c.drawnStrings.contains("Clip")); XCTAssertTrue(c.drawnStrings.contains("Program"))
        XCTAssertNil(store.value.scopeSource, "nothing saved until the user switches")

        try click(r, part: programPart)
        XCTAssertEqual(r.inspector.scopeSource, .program)
        XCTAssertEqual(store.value.scopeSource, .program, "saved in the panel preferences")
        XCTAssertEqual(try panel(store).inspector.scopeSource, .program, "the next launch reads Program")

        try click(r, part: InspectorPanel.scopeSourcePart)
        XCTAssertEqual(store.value.scopeSource, .clip)
        let json = String(decoding: try JSONEncoder().encode(store.value), as: UTF8.self)
        XCTAssertTrue(json.contains(#""scopeSource":"clip""#), json)
        let old = try JSONDecoder().decode(PanelPreferences.self, from: Data(#"{"openInspectorGroup":"grade"}"#.utf8))
        XCTAssertNil(old.scopeSource, "a file written before the switch existed loads as Clip")
    }

    func testProgramModeAnalysesTheHostsProgramFrameNotTheClip() throws {
        let r = try panel(MemoryPanelPreferencesStore())
        var clipAsks = 0, programAsks: [[Int]] = []
        r.inspector.scopeFrame = { _, _, _ in clipAsks += 1; return .ready(Self.ramp()) }
        r.inspector.programScopeFrame = { w, h in programAsks.append([w, h]); return .ready(Self.ramp(40)) }
        try click(r, part: 0)
        try click(r, part: programPart)
        clipAsks = 0; programAsks = []
        r.draw(PanelMeasureCanvas(), size: size)
        XCTAssertEqual(clipAsks, 0, "Program mode does not read the clip")
        XCTAssertEqual(programAsks, [[320, 320]], "the program frame, fitted in 320 px")
        r.inspector.scopeAnalyzer.wait()
        XCTAssertNotNil(r.inspector.scopeAnalyzer.bitmap(.waveform, of: Self.ramp(40)), "the scope shows the program frame")
    }

    /// Draws with a ready frame while the analysis queue is held: every draw returns, nothing is analysed on the
    /// drawing thread, and once the queue runs only the newest frame is analysed, on the background queue.
    func testAScopeUpdateNeverBlocksADrawAndOnlyTheNewestRequestIsKept() throws {
        let r = try panel(MemoryPanelPreferencesStore())
        var frame = Self.ramp()
        r.inspector.programScopeFrame = { _, _ in .ready(frame) }
        r.inspector.scopeSource = .program
        try click(r, part: 0)
        let analyzer = r.inspector.scopeAnalyzer
        analyzer.wait(); analyzer.reset()
        let base = analyzer.analysed
        var onMain: [Bool] = []
        let ready = expectation(description: "analysed"); ready.assertForOverFulfill = false
        analyzer.onReady = { onMain.append(Thread.isMainThread); ready.fulfill() }
        analyzer.queue.suspend()
        [10, 20, 30].forEach { offset in
            frame = Self.ramp(offset)
            r.draw(PanelMeasureCanvas(), size: size)   // returns although the analysis cannot run
        }
        XCTAssertEqual(analyzer.analysed, base, "nothing was analysed while drawing")
        analyzer.queue.resume()
        wait(for: [ready], timeout: 10)
        analyzer.wait()
        XCTAssertEqual(analyzer.analysed, base + 1, "the two older frames were replaced before they ran")
        XCTAssertEqual(onMain, [false])
        XCTAssertNotNil(analyzer.bitmap(.waveform, of: Self.ramp(30)), "the newest frame is the analysed one")
    }

    /// A refresh (or closing the scopes) while a frame is being analysed: that analysis is dropped, not shown after
    /// the reset, and the same frame is analysed again on the next request.
    func testAResetDropsTheAnalysisInFlight() {
        let analyzer = ScopeAnalyzer()
        analyzer.beforePublish = { [unowned analyzer] in analyzer.reset() }   // the reset lands mid-analysis
        XCTAssertNil(analyzer.bitmap(.waveform, of: Self.ramp()))
        analyzer.wait()
        XCTAssertNil(analyzer.last(.waveform), "the bitmap analysed before the reset is not published")
        XCTAssertEqual(analyzer.analysed, 0)
        analyzer.beforePublish = nil
        XCTAssertNil(analyzer.bitmap(.waveform, of: Self.ramp()), "the same frame is queued again")
        analyzer.wait()
        XCTAssertNotNil(analyzer.bitmap(.waveform, of: Self.ramp()))
        XCTAssertEqual(analyzer.analysed, 1)
    }

    #if os(Linux)   // Cairo pixels
    override func tearDown() { Theme.setMode(.dark) }

    /// Program mode, dark and light: the Program segment carries the accent wash and the Clip one does not, and the
    /// scope of the program frame is drawn on black in both appearances. `MPVFX_SNAPSHOT_DIR` writes the PNGs.
    func testProgramModeSnapshotInDarkAndLight() throws {
        let scales = try [(ThemeMode.dark, "dark"), (ThemeMode.light, "light")].map { try snapshotProgramMode($0.0, $0.1) }
        XCTAssertEqual(scales, [[1, 2], [1, 2]], "both appearances at 1x and 2x")
    }

    /// Program mode in `mode` at 1x and 2x, after the program frame's scope was analysed; returns the scales checked.
    func snapshotProgramMode(_ mode: ThemeMode, _ name: String) throws -> [Int] {
        Theme.setMode(mode)
        let r = try panel(MemoryPanelPreferencesStore())
        r.inspector.programScopeFrame = { _, _ in .ready(Self.ramp()) }
        r.inspector.scopeSource = .program
        try click(r, part: 0)
        r.draw(PanelMeasureCanvas(), size: size)   // the open scopes ask for the analysis
        r.inspector.scopeAnalyzer.wait()
        var checked: [Int] = []
        for scale in [1.0, 2.0] {
            let t = CairoImageTarget(width: Int(409 * scale), height: Int(700 * scale))
            t.canvas.scale(scale, scale)
            t.canvas.fillRect(CanvasRect(x: 0, y: 0, width: 409, height: 700), PanelTheme.studioBg)
            r.draw(t.canvas, size: CanvasSize(409, 700))
            if let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                XCTAssertEqual(t.writePNG("\(dir)/inspector-grade-scopes-program-\(name)-\(Int(scale))x.png"), 0)
            }
            try assertProgramSnapshot(r, t, scale: scale, name)
            checked.append(Int(scale))
        }
        return checked
    }

    func assertProgramSnapshot(_ r: RightPanel, _ t: CairoImageTarget, scale: Double, _ name: String) throws {
        func px(_ x: Double, _ y: Double) -> [Int] { let p = t.pixel(Int(x * scale), Int(y * scale)); return [Int(p.r), Int(p.g), Int(p.b)] }
        let clip = try XCTUnwrap(r.inspector.hits.rect { $0 == .custom("grade:scopes", InspectorPanel.scopeSourcePart) })
        let program = try XCTUnwrap(r.inspector.hits.rect { $0 == .custom("grade:scopes", self.programPart) })
        XCTAssertGreaterThan(program.x, clip.x, "Clip, then Program")
        XCTAssertNotEqual(px(program.x + 2, program.midY), px(clip.x + 2, clip.midY), "\(name): the chosen segment is washed")
        let head = try XCTUnwrap(r.inspector.hits.rect { $0 == .custom("grade:scopes", 0) })
        let box = CanvasRect(x: head.x + 1, y: head.y + 28 + 23.5 + 6 + 1, width: head.width + 26 - 2, height: 100)
        var lit = 0
        for y in stride(from: box.y + 1, to: box.maxY, by: 2) { for x in stride(from: box.x + 1, to: box.maxX, by: 2) {
            if px(x, y).max() ?? 0 > 60 { lit += 1 }
        } }
        // The empty grid lights no sample (its lines are white at 8 % on #090b0e); the ramp's thin diagonal about 90.
        XCTAssertGreaterThan(lit, 40, "\(name): the waveform of the program frame is drawn")
        XCTAssertLessThan(px(box.x + 2, box.y + 2).max() ?? 255, 40, "\(name): scopes draw on black")
    }
    #endif
}
