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
import MpvfxShared
@testable import MpvfxPanels

final class ClipInfoPanelTests: XCTestCase {
    private let fixture = ClipInfo(path: "/media/interview.mp4", container: "mp4", videoCodec: "h264", width: 1920, height: 1080,
                                   frameRate: 29.97, duration: 75.5, audioCodec: "aac", channels: 2, sampleRate: 48000,
                                   hdr: false, fileSize: 12_345_678)

    func testIsRegisteredUnderItsSavedId() {
        XCTAssertEqual(DockPanels.info, "info")
        XCTAssertEqual(DockRegistry.editor.title("info"), "Info")
    }

    func testAFixtureClipShowsEveryFact() {
        let rows = ClipInfoPanel.rows(for: fixture)
        XCTAssertEqual(rows.map(\.label), ["Path", "Container", "Video codec", "Resolution", "Frame rate", "Duration",
                                          "Audio codec", "Audio channels", "Sample rate", "Colour space", "File size", "Status"])
        let v = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0.value) })
        XCTAssertEqual(v["Path"], "/media/interview.mp4")
        XCTAssertEqual(v["Resolution"], "1920 × 1080")
        XCTAssertEqual(v["Frame rate"], "29.97 fps")
        XCTAssertEqual(v["Duration"], "1:15.500")
        XCTAssertEqual(v["Audio channels"], "Stereo")
        XCTAssertEqual(v["Sample rate"], "48 kHz")
        XCTAssertEqual(v["Colour space"], "SDR")
        XCTAssertEqual(v["File size"], "12.3 MB")
        XCTAssertEqual(v["Status"], "Online")
    }

    func testAnImageOrSilentClipLeavesOutWhatItDoesNotHave() {
        let still = ClipInfo(path: "/a/logo.png", container: "png", videoCodec: "png", width: 512, height: 512, hdr: false, fileSize: 900)
        let labels = ClipInfoPanel.rows(for: still).map(\.label)
        XCTAssertFalse(labels.contains("Audio codec"))
        XCTAssertFalse(labels.contains("Frame rate"))
        XCTAssertEqual(ClipInfoPanel.rows(for: still).first { $0.label == "File size" }?.value, "900 bytes")
    }

    func testAnOfflineClipShowsItsPathAndTheOfflineStatusOnly() {
        let rows = ClipInfoPanel.rows(for: .missing(path: "/gone/clip.mov"))
        XCTAssertEqual(rows, [.init(label: "Path", value: "/gone/clip.mov"), .init(label: "Status", value: "Offline: the file is missing")])
        let p = ClipInfoPanel()
        p.content = .info(name: "clip.mov", .missing(path: "/gone/clip.mov"))
        let c = PanelMeasureCanvas()
        p.draw(c, size: CanvasSize(320, 300))
        XCTAssertTrue(c.drawnStrings.contains("Offline: the file is missing"))
    }

    func testClickingARowCopiesItsValueAndCopyAllCopiesEveryRow() {
        let p = ClipInfoPanel()
        p.content = .info(name: "interview.mp4", fixture)
        var copied: [String] = []
        p.onCopy = { copied.append($0) }
        let c = PanelMeasureCanvas()
        p.draw(c, size: CanvasSize(320, 400))
        XCTAssertTrue(p.pointerDown(CanvasPoint(100, 34 + 26 * 3 + 5), shift: false), "the fourth row is Resolution")
        XCTAssertEqual(copied, ["1920 × 1080"])
        XCTAssertTrue(p.pointerDown(CanvasPoint(320 - 20, 15), shift: false), "Copy all")
        XCTAssertTrue(copied[1].hasPrefix("Path: /media/interview.mp4\nContainer: mp4\n"))
        XCTAssertEqual(copied[1].split(separator: "\n").count, 12)
        XCTAssertFalse(p.pointerDown(CanvasPoint(100, 390), shift: false), "below the last row")
    }

    func testNothingSelectedLoadingAndFailureStates() {
        let p = ClipInfoPanel()
        let c = PanelMeasureCanvas()
        p.draw(c, size: CanvasSize(320, 300))
        XCTAssertTrue(c.drawnStrings.contains("No clip selected"))
        XCTAssertFalse(p.pointerDown(CanvasPoint(50, 50), shift: false))
        p.content = .failed(name: "x.mp4", message: "Media changed while reading")
        c.reset(); p.draw(c, size: CanvasSize(320, 300))
        XCTAssertTrue(c.drawnStrings.contains("Media changed while reading"))
    }

    func testSizesAndDurationsFormatAtTheirEdges() {
        XCTAssertEqual(ClipInfoPanel.fileSize(0), "0 bytes")
        XCTAssertEqual(ClipInfoPanel.fileSize(1_500), "1.5 KB")
        XCTAssertEqual(ClipInfoPanel.fileSize(3_000_000_000), "3 GB")
        XCTAssertEqual(ClipInfoPanel.duration(3661.25), "1:01:01.250")
        XCTAssertEqual(ClipInfoPanel.duration(.nan), "0:00.000")
        XCTAssertEqual(ClipInfoPanel.sampleRate(44100), "44.1 kHz")
        XCTAssertEqual(ClipInfoPanel.channels(6), "6 channels")
    }
}
