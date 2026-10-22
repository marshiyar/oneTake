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
// Offline clips on the timeline (issue #102): a clip whose asset is offline draws a hatched fill and the label
// "Media offline". On Linux the clip is also rendered with Cairo in both themes; set `MPVFX_SNAPSHOT_DIR` to write the
// PNGs (`timeline-offline-<theme>.png`).
import Foundation
import XCTest
import MpvfxCanvas
import MpvfxTheme
@testable import MpvfxTimeline

final class OfflineClipDrawTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark); super.tearDown() }

    private func view(offline: Bool) -> TimelineView {
        var clip = TimelineClipModel(id: "c", name: "gone.mp4", start: 0.5, duration: 3, kind: .video)
        clip.assetId = "gone"
        let v = TimelineView(tracks: [TimelineTrackModel(id: "t", name: "Video", clips: [clip])], duration: 5)
        if offline { v.offlineAssetIds = ["gone"] }
        v.trackHeight = 44   // the timecode row (and the offline label in its place) only fits above compact rows
        return v
    }

    func testAnOfflineClipDrawsHatchingAndTheMediaOfflineLabel() {
        let online = RecordingCanvas()
        view(offline: false).draw(online, size: CanvasSize(900, 200))
        XCTAssertFalse(online.texts.contains("Media offline"))
        let offline = RecordingCanvas()
        view(offline: true).draw(offline, size: CanvasSize(900, 200))
        XCTAssertTrue(offline.texts.contains("Media offline"), "\(offline.texts)")
        XCTAssertTrue(offline.texts.contains("gone.mp4"), "the clip keeps its name")
    }

    #if os(Linux)   // Cairo is the Linux canvas; these draw real pixels.
    func testOfflineClipSnapshotsInBothThemes() throws {
        var bases: [ThemeMode: (r: UInt8, g: UInt8, b: UInt8)] = [:]
        for mode in [ThemeMode.dark, .light] {
            Theme.setMode(mode)
            let v = view(offline: true)
            let target = CairoImageTarget(width: 900, height: 200)
            v.draw(target.canvas, size: CanvasSize(900, 200))
            if let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                XCTAssertEqual(target.writePNG("\(dir)/timeline-offline-\(mode == .dark ? "dark" : "light").png"), 0)
            }
            // The middle row of the clip, clear of the name (top) and the label (bottom), crosses the hatch stripes.
            let r = v.clipRect(track: 0, v.tracks[0].clips[0])
            let y = Int(r.y + r.height / 2)
            let row = stride(from: Int(r.x) + 24, to: Int(r.maxX) - 24, by: 1).map { target.pixel($0, y) }
            let lum = row.map { Int($0.r) + Int($0.g) + Int($0.b) }
            XCTAssertGreaterThan((lum.max() ?? 0) - (lum.min() ?? 0), 30, "\(mode): hatched, not a flat fill")
            bases[mode] = row.min { Int($0.r) + Int($0.g) + Int($0.b) < Int($1.r) + Int($1.g) + Int($1.b) }.map { ($0.r, $0.g, $0.b) }
            // Not the clip's ordinary video fill.
            let video = CanvasColor(ThemeTokens.clipVideoPair.now)
            let px = target.pixel(Int(r.x) + 30, y)
            let same = abs(Int(px.r) - Int(video.r * 255)) < 4 && abs(Int(px.g) - Int(video.g * 255)) < 4 && abs(Int(px.b) - Int(video.b * 255)) < 4
            XCTAssertFalse(same, "\(mode): offline fill differs from the video clip fill")
        }
        let d = try XCTUnwrap(bases[.dark]), l = try XCTUnwrap(bases[.light])
        XCTAssertNotEqual(Int(d.r) + Int(d.g) + Int(d.b), Int(l.r) + Int(l.g) + Int(l.b), "the fill follows the theme")
    }
    #endif
}
