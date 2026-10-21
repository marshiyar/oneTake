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

/// The Media group (issue #188): Media start as timecode, one "Sound" switch for every clip kind, Rate's 1x detent
/// and double-click reset, and one "Edit crop" entry point.
final class InspectorMediaGroupTests: XCTestCase {
    static func json(numerator: Int = 30, denominator: Int = 1, sourceIn: Int = 95) -> String {
        """
        {"schemaVersion":1,"id":"project:media","revision":1,"frameRate":{"numerator":\(numerator),"denominator":\(denominator)},
         "canvas":{"width":1920,"height":1080,"background":"#111111"},
         "assets":[{"id":"asset:v","kind":"video","name":"v.mp4","source":"media/v.mp4","durationFrames":200000},
                   {"id":"asset:m","kind":"audio","name":"m.wav","source":"media/m.wav","durationFrames":200000}],
         "sequence":{"id":"sequence:main","name":"Main","tracks":[
          {"id":"track:v1","kind":"video","lane":{"authoredTrack":1,"displayTrack":0},"clips":[
           {"id":"clip:v","assetId":"asset:v","startFrame":0,"durationFrames":180,"sourceInFrame":\(sourceIn),"muted":false,"effects":[],"parameterTracks":[]}]},
          {"id":"track:a1","kind":"audio","lane":{"authoredTrack":1,"displayTrack":1},"clips":[
           {"id":"clip:m","assetId":"asset:m","startFrame":0,"durationFrames":180,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
        """
    }

    static let frame = CanvasRect(x: 0, y: 0, width: 360, height: 1400)

    func make(_ json: String = json(), select id: String = "clip:v") throws -> (InspectorPanel, TimelineEditor) {
        let editor = try TimelineEditor(json: json)
        let p = InspectorPanel(); p.editor = editor; p.selection = [id]; p.openGroupId = "media"
        p.draw(PanelMeasureCanvas(), in: Self.frame)
        return (p, editor)
    }

    func redraw(_ p: InspectorPanel) { p.draw(PanelMeasureCanvas(), in: Self.frame) }

    func centre(_ p: InspectorPanel, _ h: InspectorPanel.Hit, file: StaticString = #filePath, line: UInt = #line) throws -> CanvasPoint {
        let r = try XCTUnwrap(p.hits.rect { $0 == h }, "no hit \(h)", file: file, line: line)
        return CanvasPoint(r.midX, r.midY)
    }

    // MARK: A1 Media start reads timecode

    func testA1MediaStartIsTimecodeOfTheIntegerSourceInFrame() throws {
        let (p, _) = try make()
        let n = try XCTUnwrap(p.number("mediaStart"))
        XCTAssertEqual(n.text, "00:03:05", "frame 95 at 30 fps is 3 s and 5 frames")
        XCTAssertTrue(n.readOnly); XCTAssertFalse(n.disabled, "read in the normal ink, not greyed out")
        XCTAssertEqual(n.tier, .explicitCustom)
    }

    func testA1MediaStartFollowsTheNtscTimebase() throws {
        XCTAssertEqual(try make(Self.json(numerator: 30000, denominator: 1001)).0.number("mediaStart")?.text, "00:03:05",
                       "frames count at the nominal 30 a second")
        XCTAssertEqual(try make(Self.json(numerator: 30000, denominator: 1001, sourceIn: 107_892)).0.number("mediaStart")?.text, "59:56:12",
                       "107 892 frames are 3 599.96 s of real time: still under an hour")
        XCTAssertEqual(try make(Self.json(numerator: 30000, denominator: 1001, sourceIn: 108_000)).0.number("mediaStart")?.text, "01:00:00:00",
                       "an hour of real time adds the hours field")
        XCTAssertEqual(TimelineRuler.timecode(frame: 0, numerator: 0, denominator: 1), "00:00:00", "no rate reads zero")
        XCTAssertEqual(TimelineRuler.timecode(frame: -5, numerator: 25, denominator: 1), "00:00:00", "a negative count clamps to zero")
        XCTAssertEqual(TimelineRuler.timecode(frame: 90_000, numerator: 25, denominator: 1), "01:00:00:00")
    }

    func testA1MediaStartIsSelectableButNeverEdited() throws {
        let (p, editor) = try make()
        XCTAssertTrue(p.pointerDown(try centre(p, .field("mediaStart"))))
        XCTAssertEqual(p.field?.key, "mediaStart", "a click focuses the value so it can be read and selected")
        XCTAssertTrue(p.keyDown(EditorKey(.char("7"))))
        XCTAssertEqual(p.field?.draft, "00:03:05", "typing does not change it")
        XCTAssertTrue(p.keyDown(EditorKey(.escape)))
        XCTAssertNil(p.field)
        XCTAssertEqual(editor.clip("clip:v")?.clip.sourceInFrame, 95)
        XCTAssertFalse(editor.canUndo, "nothing was edited")
    }

    // MARK: A2 One Sound switch

    func soundRow(_ p: InspectorPanel) -> InspectorRow.Toggle? { p.toggle("muted") }

    func testA2VideoAndAudioShareOneSoundSwitchOnMeansHeard() throws {
        for id in ["clip:v", "clip:m"] {
            let (p, editor) = try make(select: id)
            let row = try XCTUnwrap(soundRow(p), id)
            XCTAssertEqual(row.label, "Sound", id); XCTAssertTrue(row.on, "\(id): unmuted reads on")
            XCTAssertTrue(p.pointerDown(try centre(p, .toggle("muted"))))
            XCTAssertEqual(editor.clip(id)?.clip.muted, true, "\(id): switching Sound off mutes")
            redraw(p)
            XCTAssertEqual(soundRow(p)?.on, false, id)
            XCTAssertTrue(p.pointerDown(try centre(p, .toggle("muted"))))
            XCTAssertEqual(editor.clip(id)?.clip.muted, false, "\(id): switching Sound on unmutes")
            XCTAssertTrue(editor.undo())
            XCTAssertEqual(editor.clip(id)?.clip.muted, true, "\(id): one undo step per switch")
            XCTAssertTrue(editor.undo())
            XCTAssertEqual(editor.clip(id)?.clip.muted, false, id)
        }
    }

    // MARK: A3 Rate

    func rateTrack(_ p: InspectorPanel) throws -> CanvasRect { try XCTUnwrap(p.hits.rect { $0 == .slider("rate") }) }

    /// Rate runs 25 % to 300 % along the track, so a point there stands for one speed.
    func x(_ track: CanvasRect, rate: Double) -> Double { track.x + (rate * 100 - 25) / 275 * track.width }

    func drag(_ p: InspectorPanel, to rate: Double, time: Double) throws {
        let t = try rateTrack(p)
        XCTAssertTrue(p.pointerDown(CanvasPoint(x(t, rate: 2), t.midY), time: time))
        _ = p.pointerMove(CanvasPoint(x(t, rate: rate), t.midY))
        p.pointerUp(CanvasPoint(x(t, rate: rate), t.midY))
        redraw(p)
    }

    func testA3RateSnapsToNormalSpeedWithin3PercentOfTheTrack() throws {
        let (p, editor) = try make()
        XCTAssertTrue(editor.setPlaybackRate(clipId: "clip:v", 1.5)); redraw(p)
        try drag(p, to: 1.02, time: 0)
        XCTAssertEqual(editor.playbackRate(clipId: "clip:v"), 1, accuracy: 1e-9, "a drag ending at 1.02 commits 1.0")
        try drag(p, to: 1.15, time: 10)
        XCTAssertEqual(editor.playbackRate(clipId: "clip:v"), 1.15, accuracy: 1e-9, "outside the detent the value is free")
        try drag(p, to: 0.95, time: 20)
        XCTAssertEqual(editor.playbackRate(clipId: "clip:v"), 1, accuracy: 1e-9, "the detent holds from below too")
    }

    func testA3RateShowsTheDetentWhileDragging() throws {
        let (p, _) = try make()
        let t = try rateTrack(p)
        XCTAssertTrue(p.pointerDown(CanvasPoint(x(t, rate: 1.04), t.midY), time: 0))
        XCTAssertEqual(p.sliderDrag?.current, 100, "the knob sits on 1x while the pointer is near it")
        _ = p.pointerMove(CanvasPoint(x(t, rate: 2), t.midY))
        XCTAssertEqual(try XCTUnwrap(p.sliderDrag?.current), 200, accuracy: 1e-6)
        p.pointerUp(CanvasPoint(x(t, rate: 2), t.midY))
    }

    func testA3DoubleClickResetsRateToNormalSpeed() throws {
        let (p, editor) = try make()
        XCTAssertTrue(editor.setPlaybackRate(clipId: "clip:v", 2.5)); redraw(p)
        let t = try rateTrack(p), at = CanvasPoint(x(t, rate: 2.5), t.midY)
        XCTAssertTrue(p.pointerDown(at, time: 100)); p.pointerUp(at); redraw(p)
        XCTAssertEqual(editor.playbackRate(clipId: "clip:v"), 2.5, accuracy: 0.011, "the first click lands where it was")
        XCTAssertTrue(p.pointerDown(at, time: 100.25)); p.pointerUp(at); redraw(p)
        XCTAssertEqual(editor.playbackRate(clipId: "clip:v"), 1, accuracy: 1e-9, "a double-click resets to 1x")
        XCTAssertTrue(editor.setPlaybackRate(clipId: "clip:v", 2.5)); redraw(p)
        XCTAssertTrue(p.pointerDown(at, time: 200)); p.pointerUp(at); redraw(p)
        XCTAssertTrue(p.pointerDown(at, time: 201)); p.pointerUp(at); redraw(p)
        XCTAssertEqual(editor.playbackRate(clipId: "clip:v"), 2.5, accuracy: 0.011, "two slow clicks are two clicks")
    }

    func testA3RateReadsTwoDecimalsAndATimesSign() throws {
        let (p, editor) = try make()
        XCTAssertEqual(p.slider("rate")?.display, "1.00×")
        XCTAssertTrue(editor.setPlaybackRate(clipId: "clip:v", 1.5)); redraw(p)
        XCTAssertEqual(p.slider("rate")?.display, "1.50×")
        XCTAssertEqual(p.slider("rate")?.format(25), "0.25×")
    }

    // MARK: A4 One crop entry point

    func testA4CropHasOneEditCropButtonInTheStandardStyle() throws {
        let (p, _) = try make()
        let b = try XCTUnwrap(p.button("crop:start"))
        XCTAssertEqual(b.label, "Edit crop"); XCTAssertEqual(b.style, .chip)
        let subheaders = p.groups.flatMap(\.rows).compactMap { r -> String? in if case .subheader(let t, _) = r.kind { return t }; return nil }
        XCTAssertFalse(subheaders.contains("Crop"), "no Crop subheader before the session starts")
        let r = try XCTUnwrap(p.hits.rect { $0 == .button("crop:start") })
        XCTAssertGreaterThanOrEqual(r.height, 24); XCTAssertGreaterThanOrEqual(r.width, 24)
    }

    func testA4EditCropDrivesTheLinkedStageSession() throws {
        let (p, editor) = try make()
        var active: String?, draft = NativeClipCrop(), commands: [InspectorCropCommand] = []
        p.cropLink = InspectorCropLink(activeClip: { active }, insets: { active == nil ? nil : draft },
                                       run: { cmd in commands.append(cmd); active = cmd == .start ? "clip:v" : nil },
                                       setInsets: { draft = $0 })
        redraw(p)
        XCTAssertTrue(p.pointerDown(try centre(p, .button("crop:start"))))
        XCTAssertEqual(commands, [.start]); redraw(p)
        XCTAssertNotNil(p.button("crop:apply"), "the inspector shows the linked session")
        p.number("crop:left")?.commit("20")
        XCTAssertEqual(draft.left, 20, "edge fields write the session's draft")
        XCTAssertNil(editor.crop(clipId: "clip:v"), "nothing reaches the document before Apply")
        XCTAssertFalse(editor.canUndo)
        p.button("crop:apply")?.action()
        XCTAssertEqual(commands, [.start, .apply]); redraw(p)
        XCTAssertNotNil(p.button("crop:start"))
        active = "clip:v"; redraw(p)   // the stage toolbar started it
        XCTAssertNotNil(p.button("crop:cancel"), "a session started on the stage shows here too")
    }
}
