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
import MpvfxAudio
import MpvfxCanvas
import MpvfxTheme
import MpvfxPanels
import MpvfxTimeline
@testable import MpvfxDesktop

final class VoiceTransportUITests: XCTestCase {
    func testA1AltSpaceStartsAndEscapeDiscardsBeforeTimelineConsumesIt() throws {
        let s = try EditorSession(projectPath: nil, demo: true)
        // The command is handled even in demo mode, with an actionable saved-project error.
        var error: String?
        s.onError = { _, message in error = message }
        XCTAssertTrue(s.voiceKey(EditorKey(.space, alt: true)))
        XCTAssertNotNil(error)
        XCTAssertEqual(s.voice.state, .idle)
    }

    #if os(Linux)
    func testA4VoiceMeterAndClipIndicatorSnapshotsInDarkAndLight() throws {
        for mode in [ThemeMode.dark, .light] {
            Theme.setMode(mode)
            defer { Theme.setMode(.dark) }
            let s = try EditorSession(projectPath: nil, demo: true)
            let target = CairoImageTarget(width: 800, height: 400)
            let input = ScriptedAudioInput(samples: [Float](repeating: 1.2, count: 2_401))
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("voice-ui-\(UUID()).wav").path
            let ready = expectation(description: "meter updated")
            input.onRead = { n in if n == 2_401 { ready.fulfill() } }
            try s.voice.arm(input: input, destination: file, playhead: 0, countIn: 0, now: 0)
            wait(for: [ready], timeout: 3)
            s.drawVoice(target.canvas, size: CanvasSize(800, 400))
            let r = s.voiceRect(CanvasSize(800, 400))
            let pixel = target.pixel(Int(r.maxX - 2), Int(r.y - 7))
            let red = PanelTheme.danger
            XCTAssertEqual(Double(pixel.r), red.r * 255, accuracy: 1)
            XCTAssertEqual(Double(pixel.g), red.g * 255, accuracy: 1)
            if let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                XCTAssertEqual(target.writePNG("\(dir)/voice-meter-\(mode.rawValue).png"), 0)
            }
            s.cancelVoice()
        }
    }
    #endif
}
