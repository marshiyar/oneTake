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
import MpvfxPanels
import MpvfxPlayer
import MpvfxTheme
@testable import MpvfxDesktop

/// Record motion in the whole editor at 1440×900: one take is one "Record motion" undo step, and the armed and
/// recording states show on the Record control and round the stage in dark and light. Set `MPVFX_SNAPSHOT_DIR`
/// to also write `record-<state>-<mode>.png`.
final class RecordMotionShellTests: XCTestCase {
    static let size = CanvasSize(1440, 900)
    var dirs: [String] = []
    var sessions: [EditorSession] = []

    override func setUp() { Theme.setMode(.dark) }
    override func tearDown() {
        sessions.removeAll()
        for d in dirs { try? FileManager.default.removeItem(atPath: d) }
        Theme.setMode(.dark)
    }

    func makeSession() throws -> EditorSession {
        let d = NSTemporaryDirectory() + "mpvfx-record-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        dirs.append(d)
        let s = try EditorSession(backend: nil, projectPath: nil, demo: true)
        _ = s.installShell(userData: d) {}
        sessions.append(s)
        return s
    }

    @discardableResult
    func render(_ s: EditorSession, _ name: String) throws -> CairoImageTarget {
        let t = CairoImageTarget(width: Int(Self.size.width), height: Int(Self.size.height))
        let shell = try XCTUnwrap(s.shell)
        shell.draw(t.canvas, size: Self.size)
        if let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            XCTAssertEqual(t.writePNG("\(dir)/\(name).png"), 0)
        }
        return t
    }

    /// Selects the demo's top visual layer on the timeline and returns its on-screen centre (player-local).
    func selectLayer(_ s: EditorSession) throws -> CanvasPoint {
        let e = try XCTUnwrap(s.player.view.elements.last, "the demo has a visual layer at the playhead")
        s.timeline.view.selection = [e.id]
        s.syncStage()
        XCTAssertEqual(s.player.view.selectedIds, [e.id])
        return s.player.view.chromeElement(e, in: s.player.size).centre
    }

    /// Presses on the layer and drags it for `frames` transport frames, drawing the window each frame (the draw
    /// samples the take, as on screen).
    func drag(_ s: EditorSession, from p: CanvasPoint, frames: Int) throws {
        let shell = try XCTUnwrap(s.shell), frame = CairoImageTarget(width: Int(Self.size.width), height: Int(Self.size.height))
        s.player.pointerDown(x: p.x, y: p.y)
        for i in 1...frames {
            s.player.pointerMove(x: p.x + Double(i) * 6, y: p.y + Double(i) * 2)
            s.playback.tick(1 / max(s.playback.fps, 1))
            shell.draw(frame.canvas, size: Self.size)
        }
    }

    func testATakeIsOneRecordMotionUndoStep() throws {
        let s = try makeSession()
        try render(s, "record-setup")
        let p = try selectLayer(s)
        let before = s.editor.document
        let undoDepth = s.editor.undoStack.count
        s.player.toggleRecording()
        try drag(s, from: p, frames: 12)
        s.player.pointerUp(x: p.x + 72, y: p.y + 24)
        XCTAssertFalse(s.player.isRecording)
        XCTAssertNotEqual(s.editor.document, before, "the take wrote keyframes")
        XCTAssertEqual(s.editor.undoStack.count, undoDepth + 1, "the whole take is one undo step")
        XCTAssertEqual(s.editor.undoLabel, "Record motion")
        XCTAssertTrue(s.editor.undo())
        XCTAssertEqual(s.editor.document, before, "undo puts every key back")
    }

    func testArmedAndRecordingStatesInDarkAndLight() throws {
        for mode in [ThemeMode.dark, .light] {
            Theme.setMode(mode)
            let s = try makeSession()
            try render(s, "record-setup-\(mode.rawValue)")
            let p = try selectLayer(s)
            s.player.toggleRecording()
            let armed = try render(s, "record-armed-\(mode.rawValue)")
            try assertRecordChrome(s, armed, recording: false, mode: mode)
            try drag(s, from: p, frames: 6)
            let recording = try render(s, "record-recording-\(mode.rawValue)")
            try assertRecordChrome(s, recording, recording: true, mode: mode)
            s.player.pointerUp(x: p.x + 36, y: p.y + 12)
        }
    }

    /// The red outline left of the stage frame and the Record control's fill, in window pixels.
    func assertRecordChrome(_ s: EditorSession, _ t: CairoImageTarget, recording: Bool, mode: ThemeMode,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let origin = try XCTUnwrap(s.shell?.frames?.player, file: file, line: line)
        let v = s.player.view, frame = v.frameRect(in: s.player.size)
        let outline = t.pixel(Int(origin.x + frame.x - 1), Int(origin.y + frame.y + frame.height / 2))
        XCTAssertGreaterThan(Int(outline.r) - Int(outline.g), 80, "\(mode) red stage outline: \(outline)", file: file, line: line)
        let control = try XCTUnwrap(v.toolbar.layout(width: s.player.size.width, cropAvailable: v.cropAvailable, cropActive: false, s.player.measure)
            .first { $0.0 == .record }?.1, file: file, line: line)
        let fill = t.pixel(Int(origin.x + control.x + control.width - 4), Int(origin.y + control.y + control.height / 2))
        let redness = Int(fill.r) - Int(fill.g)
        if recording {
            XCTAssertGreaterThan(redness, 120, "\(mode) the control is solid red while recording: \(fill)", file: file, line: line)
        } else {
            XCTAssertGreaterThan(redness, 15, "\(mode) the armed control is red-tinted: \(fill)", file: file, line: line)
        }
        XCTAssertEqual(v.recordOverlay?.state, recording ? .recording : .ready, file: file, line: line)
    }
}
#endif
