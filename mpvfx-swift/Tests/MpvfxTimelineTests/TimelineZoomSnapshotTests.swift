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
#if os(Linux)   // CairoImageTarget is the Linux canvas backend
import XCTest
import OneTakeKeyframes
@testable import MpvfxTimeline
import MpvfxCanvas
import MpvfxTheme

/// The timeline region (toolbar, ruler, lanes) of the owner's project at the 1440 × 900 and 1280 × 800 window widths,
/// in dark and light (docs/TIMELINE.md "Captures"). Set `MPVFX_SNAPSHOT_DIR` to write the PNGs
/// (`timeline-zoom-<mode>-<w>.png`) and look at them.
final class TimelineZoomSnapshotTests: XCTestCase {
    /// Two clips on one video track, 0–4.13 s and 6–41.43 s, in a sequence still 60 s long.
    static let ownerJSON = #"""
    {"schemaVersion":1,"id":"project:owner","revision":1,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":1920,"height":1080,"background":"#111111"},
     "assets":[{"id":"asset:su57","kind":"video","name":"Su-57 edit - Brushed down.mp4","durationFrames":1800}],
     "sequence":{"id":"sequence:main","name":"Main","durationFrames":1800,"tracks":[
      {"id":"track:v1","kind":"video","lane":{"authoredTrack":1,"displayTrack":0},"clips":[
       {"id":"clip:a","assetId":"asset:su57","startFrame":0,"durationFrames":124,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]},
       {"id":"clip:b","assetId":"asset:su57","startFrame":180,"durationFrames":1063,"sourceInFrame":124,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
    """#
    /// Timeline heights in the default layout of each window (the region under the preview).
    static let sizes: [(window: String, width: Double, height: Double)] = [("1440x900", 1440, 360), ("1280x800", 1280, 320)]

    override func tearDown() { Theme.setMode(.dark) }

    func render(width: Double, height: Double, mode: ThemeMode) throws -> (CairoImageTarget, TimelineController) {
        Theme.setMode(mode)
        let e = try TimelineEditor(json: Self.ownerJSON, engine: KeyframeRuntime())
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        let region = TimelineRegion(controller: c)
        c.playback.seek(1.5); c.syncFromPlayback()
        let t = CairoImageTarget(width: Int(width), height: Int(height))
        region.draw(t.canvas, size: CanvasSize(width, height))
        if let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            XCTAssertEqual(t.writePNG("\(dir)/timeline-zoom-\(mode == .dark ? "dark" : "light")-\(Int(width)).png"), 0)
        }
        return (t, c)
    }

    func testTheSequenceEndIsMarkedAtEveryWindowSizeAndMode() throws {
        for s in Self.sizes {
            for mode in [ThemeMode.dark, .light] {
                let (t, c) = try render(width: s.width, height: s.height, mode: mode)
                let marker = CanvasColor(ThemeTokens.timelineEndMarkerPair.value(mode))
                let lx = try XCTUnwrap(c.view.sequenceEndLineLeft)
                XCTAssertEqual(c.view.duration, 60, "the stored 60 s sequence")
                XCTAssertEqual(c.view.x(for: c.view.rulerEnd), s.width - 2, accuracy: 1e-6, "\(s.window) \(mode): fit spans end + margin")
                let p = t.pixel(Int(lx), Int(TimelineToolbar.height + TimelineLayout.rulerHeight + 4))
                XCTAssertEqual([p.r, p.g, p.b], [UInt8((marker.r * 255).rounded()), UInt8((marker.g * 255).rounded()), UInt8((marker.b * 255).rounded())],
                               "\(s.window) \(mode): end marker on the line")
            }
        }
    }
}
#endif
