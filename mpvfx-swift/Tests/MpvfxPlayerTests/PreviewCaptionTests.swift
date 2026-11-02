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
@testable import MpvfxPlayer
import MpvfxCanvas
import MpvfxShared

/// The caption track as the preview draws it: the cue on screen at a time, its layout as a plate and a text layer, and
/// the rule that captions never enter the picture's layer list (export burns them in on its own).
final class PreviewCaptionTests: XCTestCase {
    /// Half an em per character: a fixed advance, so the layout is the same on every machine.
    static let measure: (String, CanvasFont) -> Double = { text, font in Double(text.count) * font.size * 0.5 }

    static let cues = [
        NativeCaptionCue(id: "cue:1", startMs: 0, endMs: 1000, text: "one"),
        NativeCaptionCue(id: "cue:2", startMs: 2000, endMs: 3000, text: "two"),
    ]
    static let look = NativeCaptionLook(outlines: [NativeTextLook.Outline(width: 6, color: "#000000")],
                                        plate: NativeCaptionLook.Plate(color: "#000000B3"))

    /// A project at 30 fps with one image clip over the whole sequence, so the picture has layers too.
    func document(captions: NativeCaptionTrack?, width: Int = 1920, height: Int = 1080) throws -> NativeProjectDocument {
        let json = #"""
        {"schemaVersion":1,"id":"project:captions","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":\#(width),"height":\#(height),"background":"#000000"},
         "assets":[{"id":"image","kind":"image","name":"image.png","source":"image.png","durationFrames":300}],
         "sequence":{"id":"seq","name":"Sequence","tracks":[{"id":"v","kind":"video","clips":[
          {"id":"pic","assetId":"image","startFrame":0,"durationFrames":300,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
        """#
        var d = try parseNativeProjectDocument(try NativeJSONValue.parse(json))
        d.sequence.captions = captions
        return try parseNativeProjectDocument(d)
    }

    func track(_ cues: [NativeCaptionCue] = PreviewCaptionTests.cues, look: NativeCaptionLook? = PreviewCaptionTests.look) -> NativeCaptionTrack {
        NativeCaptionTrack(id: NATIVE_CAPTION_TRACK_DEFAULT_ID, cues: cues, look: look)
    }

    func composition(_ d: NativeProjectDocument) -> PreviewComposition {
        PreviewComposition(document: d, projectDir: nil, engine: nil, fileExists: { _ in true })
    }

    func testTheCueOnScreenIsTheOneCoveringTheTime() throws {
        let comp = composition(try document(captions: track()))
        XCTAssertEqual(comp.captionCue(at: 0.5)?.id, "cue:1")
        XCTAssertNil(comp.captionCue(at: 1.5), "a gap between cues shows no caption")
        XCTAssertEqual(comp.captionCue(at: 2.0)?.id, "cue:2", "a cue starts at its startMs")
        XCTAssertNil(comp.captionCue(at: 3.0), "endMs is exclusive")
    }

    func testTheLayersAreThePlateThenTheTextOfTheCueAtThatTime() throws {
        let comp = composition(try document(captions: track()))
        let layers = comp.captionLayers(at: 0.5, measure: Self.measure)
        XCTAssertEqual(layers.map(\.clipId), ["caption-plate:cue:1", "caption:cue:1"])
        XCTAssertEqual(layers.map(\.kind), [PreviewLayer.Kind.generator, PreviewLayer.Kind.text])

        let layout = try XCTUnwrap(comp.captionLayout(at: 0.5, measure: Self.measure))
        let text = try XCTUnwrap(layers[1].text)
        XCTAssertEqual(text.content, layout.lines.joined(separator: "\n"))
        XCTAssertEqual(text.align, "center")
        XCTAssertEqual(text.fontSize, layout.fontSize)

        let plate = try XCTUnwrap(layout.plateRect)
        XCTAssertEqual(layers[0].box, CanvasRect(x: plate.x, y: plate.y, width: plate.width, height: plate.height))
        XCTAssertEqual(layers[0].generator?.kind, "color")
        XCTAssertEqual(layers[0].generator?.color, "#000000B3")
        XCTAssertEqual(layers[0].start, 0)
        XCTAssertEqual(layers[0].end, 1)
    }

    func testTheTextLayerCarriesTheOutlineAtTheFrameScale() throws {
        let comp = composition(try document(captions: track()))
        let text = try XCTUnwrap(comp.captionLayers(at: 0.5, measure: Self.measure).last?.text)
        let outline = try XCTUnwrap(text.look?.outlines?.first)
        XCTAssertEqual(outline.width, 6 * 1080.0 / 1080.0, accuracy: 1e-9, "6 px at a 1080 px short edge, scaled by short / 1080")
        XCTAssertEqual(outline.color, "#000000")
        XCTAssertNil(text.look?.shadow)
    }

    func testOutlineShadowAndSizeScaleWithTheShortEdge() throws {
        let look = NativeCaptionLook(outlines: [NativeTextLook.Outline(width: 6, color: "#000000")],
                                     shadow: NativeTextLook.Shadow(x: 4, y: 4, blur: 8, color: "#000000"))
        let comp = composition(try document(captions: track(look: look), width: 3840, height: 2160))
        let text = try XCTUnwrap(comp.captionLayers(at: 0.5, measure: Self.measure).last?.text)
        XCTAssertEqual(text.look?.outlines?.first?.width, 12, "6 px at 1080 becomes 12 px at 2160")
        XCTAssertEqual(text.look?.shadow?.x, 8)
        XCTAssertEqual(text.look?.shadow?.y, 8)
        XCTAssertEqual(text.look?.shadow?.blur, 16)
        XCTAssertEqual(text.fontSize ?? 0, 0.06 * 2160, accuracy: 1e-9, "the default size is a fraction of the short edge")
    }

    func testWithoutAPlateOnlyTheTextLayerIsDrawn() throws {
        let look = NativeCaptionLook(outlines: [NativeTextLook.Outline(width: 6, color: "#000000")])
        let layers = composition(try document(captions: track(look: look))).captionLayers(at: 0.5, measure: Self.measure)
        XCTAssertEqual(layers.map(\.clipId), ["caption:cue:1"])
        XCTAssertEqual(layers.first?.kind, PreviewLayer.Kind.text)
    }

    func testAnUnsupportedLookDrawsWithTheDefaultLook() throws {
        let future = try JSONDecoder().decode(NativeCaptionLook.self, from: Data(#"{"v":2,"size":0.2,"plate":{"color":"#ff0000"}}"#.utf8))
        XCTAssertFalse(future.isSupported)
        let layers = composition(try document(captions: track(look: future))).captionLayers(at: 0.5, measure: Self.measure)
        XCTAssertEqual(layers.map(\.clipId), ["caption:cue:1"], "the default look has no plate")
        let text = try XCTUnwrap(layers.first?.text)
        XCTAssertEqual(text.fontSize ?? 0, 0.06 * 1080, accuracy: 1e-9, "the default size of the 1080 px short edge")
        XCTAssertNil(text.look, "the default look has no outline or shadow")
    }

    func testNoCaptionsOrAGapGivesNoCaptionLayers() throws {
        let gap = composition(try document(captions: track()))
        XCTAssertTrue(gap.captionLayers(at: 1.5, measure: Self.measure).isEmpty)
        XCTAssertTrue(gap.captionLayers(at: 3.5, measure: Self.measure).isEmpty)
        let none = composition(try document(captions: nil))
        XCTAssertTrue(none.captionLayers(at: 0.5, measure: Self.measure).isEmpty)
        let empty = composition(try document(captions: track([])))
        XCTAssertTrue(empty.captionLayers(at: 0.5, measure: Self.measure).isEmpty)
    }

    func testTheCaptionsNeverJoinThePicturesLayers() throws {
        let comp = composition(try document(captions: track()))
        for time in [0.5, 1.5, 2.0, 3.5] {
            let layers = comp.layers(at: time)
            XCTAssertFalse(layers.isEmpty, "the picture clip is on screen at \(time)")
            XCTAssertFalse(layers.contains { $0.clipId.hasPrefix("caption") }, "no caption layer at \(time)")
        }
    }
}
