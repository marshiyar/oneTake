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
// Audition on the media bin: Space on a selected tile and the play button start it, Space and the stop button end it,
// ← / → move 5 s only while a file plays, Esc stops, a click on the progress bar seeks, and a failure is drawn on the tile.
import Foundation
import XCTest
import MpvfxCanvas
import MpvfxTheme
import MpvfxTimeline
@testable import MpvfxPanels

final class MediaPanelAuditionTests: XCTestCase {
    typealias Hit = LeftSidebarPanel.Hit
    let video = MediaTileRef.media("media/b-roll.mov"), audio = MediaTileRef.media("media/drive.wav")
    let picture = MediaTileRef.media("media/poster.png"), font = MediaTileRef.media("media/Inter.ttf")

    struct Calls: Equatable { var toggled: [String] = [], seeks: [String] = [], steps: [Double] = [], stops = 0 }

    func panel() -> (LeftSidebarPanel, Box) {
        let box = Box()
        let s = MediaPanelFixture.panel()
        s.onAuditionToggle = { box.calls.toggled.append($0) }
        s.onAuditionSeek = { box.calls.seeks.append("\($0)@\($1)") }
        s.onAuditionSeekBy = { box.calls.steps.append($0) }
        s.onAuditionStop = { box.calls.stops += 1 }
        _ = draw(s)
        return (s, box)
    }
    final class Box { var calls = Calls() }

    @discardableResult
    func draw(_ s: LeftSidebarPanel, width: Double = 364) -> PanelMeasureCanvas {
        let c = PanelMeasureCanvas()
        s.draw(c, size: CanvasSize(width, 1500))
        return c
    }

    func center(_ r: CanvasRect) -> CanvasPoint { CanvasPoint(r.midX, r.midY) }

    // A1

    func testA1SpaceOnASelectedAudioOrVideoTileStartsAudition() {
        for ref in [video, audio] {
            let (s, box) = panel()
            s.selected = ref
            XCTAssertTrue(s.keyDown(EditorKey(.space)))
            XCTAssertEqual(box.calls.toggled, [ref.id])
        }
    }

    func testA1SpaceOnAPictureAFontOrNothingSelectedIsNotAudition() {
        for ref in [picture, font] {
            let (s, box) = panel()
            s.selected = ref
            _ = s.keyDown(EditorKey(.space))
            XCTAssertEqual(box.calls.toggled, [], "\(ref)")
        }
        let (s, box) = panel()
        XCTAssertFalse(s.keyDown(EditorKey(.space)))
        XCTAssertEqual(box.calls.toggled, [])
    }

    func testA1SpaceOnAFocusedHeaderControlStillPressesIt() throws {
        let (s, box) = panel()
        s.selected = video
        _ = s.keyDown(EditorKey(.tab))   // focus walks to the first header control
        draw(s)
        if let cur = s.focus.current, !s.isTile(cur) { _ = s.keyDown(EditorKey(.space)) }
        XCTAssertEqual(box.calls.toggled, [])
    }

    func testA1SpaceOnThePlayingTileStopsIt() {
        let (s, box) = panel()
        s.selected = audio
        s.audition = AuditionTileState(assetId: audio.id, position: 3, duration: 92.5)
        XCTAssertTrue(s.keyDown(EditorKey(.space)))
        XCTAssertEqual(box.calls.toggled, [audio.id], "the host decides: the same asset toggles to stop")
    }

    func testA1TheHoverPlayButtonIsOnAudioAndVideoTilesOnly() {
        let (s, _) = panel()
        for (ref, has) in [(video, true), (audio, true), (picture, false), (font, false)] {
            s.hovered = .tile(ref)
            draw(s)
            XCTAssertEqual(s.hits.rect { $0 == .tileAudition(ref) } != nil, has, "\(ref)")
        }
    }

    func testA1APressOnThePlayButtonStartsAndTheStopButtonEnds() throws {
        let (s, box) = panel()
        s.hovered = .tile(video)
        draw(s)
        XCTAssertTrue(s.pointerDown(center(try XCTUnwrap(s.hits.rect { $0 == .tileAudition(video) }))))
        XCTAssertEqual(box.calls.toggled, [video.id])
        s.audition = AuditionTileState(assetId: video.id, position: 1, duration: 11)
        draw(s)
        XCTAssertTrue(s.pointerDown(center(try XCTUnwrap(s.hits.rect { $0 == .tileAudition(video) }))))
        XCTAssertEqual(box.calls.toggled, [video.id, video.id])
    }

    func testA1ArrowsSeekFiveSecondsOnlyWhileAFilePlaysAndEscapeStops() {
        let (s, box) = panel()
        s.selected = audio
        XCTAssertTrue(s.keyDown(EditorKey(.right)), "with no audition the arrow moves the selection")
        XCTAssertEqual(box.calls.steps, [])
        s.selected = audio
        s.audition = AuditionTileState(assetId: audio.id, position: 10, duration: 92.5)
        XCTAssertTrue(s.keyDown(EditorKey(.right)))
        XCTAssertTrue(s.keyDown(EditorKey(.left)))
        XCTAssertEqual(box.calls.steps, [5, -5])
        XCTAssertEqual(s.selected, audio, "the selection stays on the playing tile")
        XCTAssertTrue(s.keyDown(EditorKey(.escape)))
        XCTAssertEqual(box.calls.stops, 1)
    }

    func testEscapeWithNothingPlayingKeepsItsOldMeaning() {
        let (s, box) = panel()
        s.selected = video
        XCTAssertTrue(s.keyDown(EditorKey(.escape)))
        XCTAssertNil(s.selected, "Esc still clears the selection")
        XCTAssertEqual(box.calls.stops, 0)
    }

    func testAClickOnTheProgressBarSeeksToThatFractionOfTheFile() throws {
        for ref in [video, audio] {
            let (s, box) = panel()
            s.selected = ref
            s.audition = AuditionTileState(assetId: ref.id, position: 0, duration: 100)
            draw(s)
            let strip = try XCTUnwrap(s.hits.rect { $0 == .auditionBar(ref) })
            let bar = try XCTUnwrap(s.auditionBars[ref])
            XCTAssertGreaterThanOrEqual(min(strip.width, strip.height), 24, "the click target is a full-size target, not the 3 pt bar")
            let x = bar.x + bar.width * 0.75
            XCTAssertTrue(s.pointerDown(CanvasPoint(x, strip.midY)))
            XCTAssertEqual(box.calls.seeks, ["\(ref.id)@75.0"], "\(ref)")
        }
    }

    func testOnlyTheAuditionedTileShowsAProgressBar() {
        let (s, _) = panel()
        s.audition = AuditionTileState(assetId: audio.id, position: 5, duration: 10)
        s.hovered = .tile(video)
        draw(s)
        XCTAssertNotNil(s.hits.rect { $0 == .auditionBar(audio) })
        XCTAssertNil(s.hits.rect { $0 == .auditionBar(video) })
        XCTAssertNotNil(s.hits.rect { $0 == .tileAudition(audio) }, "the playing tile keeps its stop button without hover")
    }

    // A4

    func testA4AFailureIsDrawnOnTheTileAndClearsOnTheNextTry() {
        let (s, box) = panel()
        let message = "Can't play \"b-roll.mov\": the file is missing"
        s.auditionErrors[video.id] = message
        let c = draw(s)
        XCTAssertTrue(c.drawnStrings.contains { message.hasPrefix($0) || $0.contains("Can't play") }, "\(c.drawnStrings)")
        s.selected = video
        _ = s.keyDown(EditorKey(.space))
        XCTAssertNil(s.auditionErrors[video.id], "a new try clears it")
        XCTAssertEqual(box.calls.toggled, [video.id])
    }

    func testAnAudioRowShowsItsFailureInPlaceOfTheDetailLine() {
        let (s, _) = panel()
        s.auditionErrors[audio.id] = "Can't play \"drive.wav\": the file is missing"
        let c = draw(s)
        XCTAssertTrue(c.drawnStrings.contains("Can't play \"drive.wav\": the file is missing"), "\(c.drawnStrings)")
    }

    func testEscapeClearsShownFailures() {
        let (s, _) = panel()
        s.auditionErrors[video.id] = "Can't play \"b-roll.mov\": the file is missing"
        XCTAssertTrue(s.keyDown(EditorKey(.escape)))
        XCTAssertTrue(s.auditionErrors.isEmpty)
    }
}

#if os(Linux)
/// A5: the tile while it plays, in both themes, at the panel's three widths.
final class MediaPanelAuditionSnapshotTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark) }

    func testATileAuditioningDarkAndLight() throws {
        for mode in [ThemeMode.dark, .light] { for width in [280.0, 364.0, 409.0] {
            Theme.setMode(mode)
            let s = MediaPanelSnapshotTests.panel()
            let video = MediaTileRef.media("media/b-roll.mov")
            s.audition = AuditionTileState(assetId: video.id, position: 8, duration: 21)
            s.auditionErrors["media/room-tone.wav"] = "Can't play \"room-tone.wav\": the file is missing"
            s.selected = video
            let scale = 2.0, h = 900.0
            s.draw(PanelMeasureCanvas(), size: CanvasSize(width, h))
            let target = CairoImageTarget(width: Int(width * scale), height: Int(h * scale))
            target.canvas.scale(scale, scale)
            s.draw(target.canvas, size: CanvasSize(width, h))
            let bar = try XCTUnwrap(s.auditionBars[video])
            // The filled part of the bar is the accent colour and the rest the dark track: sample either side of the position.
            let filled = target.pixel(Int((bar.x + bar.width * 0.2) * scale), Int(bar.midY * scale))
            let track = target.pixel(Int((bar.x + bar.width * 0.9) * scale), Int(bar.midY * scale))
            XCTAssertNotEqual([filled.r, filled.g, filled.b], [track.r, track.g, track.b], "\(mode) \(width): the bar shows progress")
            if let dir = ProcessInfo.processInfo.environment["MPVFX_CAPTURE_DIR"] {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                XCTAssertEqual(target.writePNG("\(dir)/media-audition-\(mode.rawValue)-\(Int(width)).png"), 0)
            }
        } }
    }
}
#endif
