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
#if canImport(CoreGraphics)
import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import MpvfxTimeline
import MpvfxCanvas
import MpvfxTheme

/// Native timeline fixture captures; these render the actual toolbar/ruler/lanes without launching the shell.
final class TimelineControlsSnapshotTests: XCTestCase {
    func testNativeDarkAndLightControlsAtBothWindowSizes() throws {
        defer { Theme.setMode(.dark) }
        for (w, h) in [(1440, 900), (1280, 800)] {
            for mode in [ThemeMode.dark, .light] {
                Theme.setMode(mode)
                var clip = TimelineClipModel(name: "Interview.mp4", start: 0, duration: 41)
                clip.effectCount = 2
                clip.effects = [.init(id: "color", label: "Color Grading"), .init(id: "blur", label: "Blur")]
                let view = TimelineView(tracks: [.init(name: "Video 1", clips: [clip]), .init(name: "Audio 1", kind: "audio", clips: [.init(name: "Music.wav", start: 0, duration: 41, kind: .audio)])], duration: 41)
                let controller = TimelineController(view: view, playback: PlaybackState(duration: 41))
                let region = TimelineRegion(controller: controller)
                region.resized(CanvasSize(Double(w), Double(h)))
                controller.setTrackHeight(48)
                let canvas = try XCTUnwrap(CoreGraphicsCanvas.offscreen(width: w, height: h))
                region.draw(canvas, size: CanvasSize(Double(w), Double(h)))
                XCTAssertEqual(view.x(for: view.rulerEnd), Double(w) - 2, accuracy: 1e-6)
                let recording = RecordingCanvas()
                region.draw(recording, size: CanvasSize(Double(w), Double(h)))
                XCTAssertTrue(recording.texts.contains("fx 2"))
                XCTAssertTrue(recording.texts.contains(region.toolbar.tickReadout))
                if let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] {
                    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    let url = URL(fileURLWithPath: dir).appendingPathComponent("timeline-controls-\(mode.rawValue)-\(w)x\(h).png")
                    let image = try XCTUnwrap(canvas.ctx.makeImage())
                    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
                    CGImageDestinationAddImage(destination, image, nil)
                    XCTAssertTrue(CGImageDestinationFinalize(destination))
                }
            }
        }
    }
}
#endif
