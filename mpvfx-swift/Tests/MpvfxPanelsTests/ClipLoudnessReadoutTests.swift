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
@testable import MpvfxTimeline
@testable import MpvfxPanels

/// The clip Loudness readout: its label text, and the Loudness row of the Media group.
final class ClipLoudnessReadoutTests: XCTestCase {
    func testLabelReadsTheSourceAtTheClipGain() {
        XCTAssertEqual(ClipLoudnessReading.label(reading: .lufs(-18.4), volume: 1, keyframed: false), "-18.4 LUFS")
        XCTAssertEqual(ClipLoudnessReading.label(reading: .lufs(-20), volume: 2, keyframed: false), "-14.0 LUFS", "+6.02 dB")
        XCTAssertEqual(ClipLoudnessReading.label(reading: .lufs(-20), volume: 0.5, keyframed: false), "-26.0 LUFS", "-6.02 dB")
    }

    func testLabelMarksAKeyframedVolume() {
        XCTAssertEqual(ClipLoudnessReading.label(reading: .lufs(-18.4), volume: 1, keyframed: true), "-18.4 LUFS + keys")
    }

    func testLabelForEveryOtherReading() {
        XCTAssertEqual(ClipLoudnessReading.label(reading: .measuring, volume: 1, keyframed: false), "Measuring\u{2026}")
        XCTAssertEqual(ClipLoudnessReading.label(reading: .silent, volume: 1, keyframed: false), "Silent")
        XCTAssertEqual(ClipLoudnessReading.label(reading: .tooShort, volume: 1, keyframed: false), "Too short to measure")
        XCTAssertEqual(ClipLoudnessReading.label(reading: .unavailable, volume: 1, keyframed: false), "Not available")
    }

    func testZeroVolumeReadsSilentWhateverTheSourceIs() {
        XCTAssertEqual(ClipLoudnessReading.label(reading: .lufs(-18.4), volume: 0, keyframed: false), "Silent")
        XCTAssertEqual(ClipLoudnessReading.label(reading: .measuring, volume: 0, keyframed: false), "Silent")
    }

    // MARK: The Media group row

    /// A video clip (sound), an audio clip (sound) and an image clip (no sound), on their own tracks.
    static let json = """
    {"schemaVersion":1,"id":"project:media","revision":1,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":1920,"height":1080,"background":"#111111"},
     "assets":[{"id":"asset:v","kind":"video","name":"v.mp4","source":"media/v.mp4","durationFrames":200000},
               {"id":"asset:m","kind":"audio","name":"m.wav","source":"media/m.wav","durationFrames":200000},
               {"id":"asset:i","kind":"image","name":"i.png","source":"media/i.png","durationFrames":200000}],
     "sequence":{"id":"sequence:main","name":"Main","tracks":[
      {"id":"track:v1","kind":"video","lane":{"authoredTrack":1,"displayTrack":0},"clips":[
       {"id":"clip:v","assetId":"asset:v","startFrame":0,"durationFrames":180,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]},
       {"id":"clip:i","assetId":"asset:i","startFrame":200,"durationFrames":60,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]},
      {"id":"track:a1","kind":"audio","lane":{"authoredTrack":1,"displayTrack":1},"clips":[
       {"id":"clip:m","assetId":"asset:m","startFrame":0,"durationFrames":180,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
    """

    static let frame = CanvasRect(x: 0, y: 0, width: 360, height: 1400)

    func make(select id: String = "clip:m") throws -> (InspectorPanel, TimelineEditor) {
        let editor = try TimelineEditor(json: Self.json)
        let p = InspectorPanel(); p.editor = editor; p.selection = [id]; p.openGroupId = "media"
        p.draw(PanelMeasureCanvas(), in: Self.frame)
        return (p, editor)
    }

    func redraw(_ p: InspectorPanel) { p.draw(PanelMeasureCanvas(), in: Self.frame) }

    func testNoRowWithoutAReadingSource() throws {
        let (p, _) = try make()
        XCTAssertNil(p.clipLoudness)
        XCTAssertNil(p.number("loudness"), "the row is hidden until the host supplies readings")
    }

    func testRowShowsTheMeasuredLoudnessAsReadOnlyText() throws {
        let (p, _) = try make()
        var asked: [String] = []
        p.clipLoudness = { asked.append($0); return .lufs(-20) }
        redraw(p)
        let row = try XCTUnwrap(p.number("loudness"))
        XCTAssertEqual(row.label, "Loudness")
        XCTAssertEqual(row.text, "-20.0 LUFS")
        XCTAssertTrue(row.readOnly)
        XCTAssertEqual(Set(asked), ["media/m.wav"], "the row asks for the clip's source")
    }

    func testRowReadsMeasuringThenTheValueOnceMeasured() throws {
        let (p, _) = try make()
        p.clipLoudness = { _ in .measuring }
        redraw(p)
        XCTAssertEqual(try XCTUnwrap(p.number("loudness")).text, "Measuring\u{2026}")
        p.clipLoudness = { _ in .lufs(-23) }
        redraw(p)
        XCTAssertEqual(try XCTUnwrap(p.number("loudness")).text, "-23.0 LUFS")
    }

    func testRowFollowsAVolumeChange() throws {
        let (p, editor) = try make()
        p.clipLoudness = { _ in .lufs(-20) }
        redraw(p)
        XCTAssertEqual(try XCTUnwrap(p.number("loudness")).text, "-20.0 LUFS")
        XCTAssertTrue(editor.setClipVolume(clipId: "clip:m", 2.0))
        redraw(p)
        XCTAssertEqual(try XCTUnwrap(p.number("loudness")).text, "-14.0 LUFS", "2.0 linear is +6.02 dB")
    }

    func testRowIsOnlyForClipsWithSound() throws {
        let (image, _) = try make(select: "clip:i")
        image.clipLoudness = { _ in .lufs(-20) }
        redraw(image)
        XCTAssertNil(image.number("loudness"), "an image clip has no sound to measure")
        let (video, _) = try make(select: "clip:v")
        video.clipLoudness = { _ in .lufs(-20) }
        redraw(video)
        XCTAssertNotNil(video.number("loudness"), "a video clip has sound")
    }
}
