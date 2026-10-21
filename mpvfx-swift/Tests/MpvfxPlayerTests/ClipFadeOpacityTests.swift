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

/// Clip fades on visual clips (issue #89): `fadeInFrames` / `fadeOutFrames` (#85) ramp the layer's opacity, multiplied
/// with the keyframed opacity, in the preview's composition, which export paints too (`ExportFramePainter`).
final class ClipFadeOpacityTests: XCTestCase {
    /// A black 200×100 canvas at 10 fps: a video clip V (lane 1, 20 frames), an image clip I and a text clip T
    /// (lanes 2 and 3, 20 frames each, all from frame 0). `fades` and `opacity` are spliced into every clip.
    static func document(fades: String = "", opacity: String = "") throws -> NativeProjectDocument {
        let statics = opacity.isEmpty ? "" : #","staticParameters":{"transform.opacity":\#(opacity)}"#
        let rest = #""muted":false,"effects":[],"parameterTracks":[]\#(statics)\#(fades)"#
        let json = """
        {"schemaVersion":1,"id":"project:fade","revision":1,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":200,"height":100,"background":"#000000"},
         "assets":[{"id":"v","kind":"video","name":"v.mp4","source":"v.mp4","durationFrames":100},
                   {"id":"i","kind":"image","name":"i.png","source":"i.png","durationFrames":100},
                   {"id":"t","kind":"element","name":"Title","durationFrames":100}],
         "sequence":{"id":"s","name":"Main","tracks":[
          {"id":"t3","kind":"video","lane":{"authoredTrack":3,"displayTrack":0},"clips":[
           {"id":"T","assetId":"t","startFrame":0,"durationFrames":20,"sourceInFrame":0,\(rest),
            "text":{"content":"Fade","fontSize":20,"color":"#ffffff"}}]},
          {"id":"t2","kind":"video","lane":{"authoredTrack":2,"displayTrack":1},"clips":[
           {"id":"I","assetId":"i","startFrame":0,"durationFrames":20,"sourceInFrame":0,\(rest)}]},
          {"id":"t1","kind":"video","lane":{"authoredTrack":1,"displayTrack":2},"clips":[
           {"id":"V","assetId":"v","startFrame":0,"durationFrames":20,"sourceInFrame":0,\(rest)}]}]}}
        """
        return try parseNativeProjectDocument(try NativeJSONValue.parse(json))
    }

    static func composition(_ doc: NativeProjectDocument) -> PreviewComposition {
        PreviewComposition(document: doc, projectDir: URL(fileURLWithPath: "/proj"), engine: nil, fileExists: { _ in true })
    }

    /// Only V: the text and image clips hidden, so a pixel read sees V over the black canvas.
    static func videoOnly(_ doc: NativeProjectDocument) -> PreviewComposition {
        var d = doc
        d.sequence.tracks[0].clips[0].hidden = true   // T
        d.sequence.tracks[1].clips[0].hidden = true   // I
        return composition(d)
    }

    static func painter(_ comp: PreviewComposition) throws -> ExportFramePainter {
        try ExportFramePainter(composition: comp, width: 200, height: 100, pad: CanvasColor(r: 0, g: 0, b: 0))
    }

    /// Layer opacity by clip id at `time` seconds.
    func opacities(_ comp: PreviewComposition, at time: Double) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: comp.layers(at: time).map { ($0.clipId, $0.opacity) })
    }

    /// A white 1 s fade-in over the black canvas.
    func testMiddleFrameOfAOneSecondFadeInIsHalfInPreviewAndExport() throws {
        let comp = Self.videoOnly(try Self.document(fades: #","fadeInFrames":10"#))
        XCTAssertEqual(try XCTUnwrap(opacities(comp, at: 0.5)["V"]), 0.5, accuracy: 1e-9, "frame 5 of a 10-frame fade-in")
        let img = try Self.painter(comp).paint(time: 0.5) { layer, _, _, _ in
            layer.clipId == "V" ? PreviewCompositorTests.solid(255, 255, 255) : nil
        }
        let i = (50 * img.width + 100) * 4
        for channel in 0..<3 { XCTAssertEqual(Int(img.rgba[i + channel]), 128, accuracy: 1, "channel \(channel) reads 50%") }
        XCTAssertEqual(img.rgba[i + 3], 255)
    }

    func testTheFadeMultipliesKeyframedOpacity() throws {
        let faded = Self.composition(try Self.document(fades: #","fadeInFrames":10"#, opacity: "0.5"))
        XCTAssertEqual(try XCTUnwrap(opacities(faded, at: 0.5)["V"]), 0.25, accuracy: 1e-9, "0.5 keyed × 0.5 fade")
        XCTAssertEqual(try XCTUnwrap(opacities(faded, at: 1.5)["V"]), 0.5, accuracy: 1e-9, "after the fade, the keyed value")
        let fadeOut = Self.composition(try Self.document(fades: #","fadeOutFrames":10"#, opacity: "0.5"))
        XCTAssertEqual(try XCTUnwrap(opacities(fadeOut, at: 1.5)["V"]), 0.25, accuracy: 1e-9, "frame 15 of 20: 5 frames before the end")
    }

    func testTextAndImageClipsFadeTheSameWayAsVideo() throws {
        let comp = Self.composition(try Self.document(fades: #","fadeInFrames":10,"fadeOutFrames":4"#))
        XCTAssertEqual(Set(comp.entries.map(\.kind)), [.video, .image, .text])
        for (time, expected) in [(0.0, 0.0), (0.5, 0.5), (1.0, 1.0), (1.8, 0.5)] {
            let o = opacities(comp, at: time)
            for id in ["V", "I", "T"] {
                XCTAssertEqual(try XCTUnwrap(o[id], "\(id) at \(time)"), expected, accuracy: 1e-9, "\(id) at \(time) s")
            }
        }
    }

    /// A fade-in's first frame draws nothing but keeps the clip decoded and pre-rolled, so the frames after the cut are
    /// ready; a clip keyed fully transparent stays invisible to the decoders as before.
    func testAFadeInsFirstFrameIsHiddenButStillDecoded() throws {
        var doc = try Self.document(fades: #","fadeInFrames":10"#)
        let first = try XCTUnwrap(Self.composition(doc).layers(at: 0).first { $0.clipId == "V" })
        XCTAssertFalse(first.isVisible)
        XCTAssertTrue(first.hiddenByFade)
        XCTAssertTrue(first.needsDecoder)
        doc.sequence.tracks[2].clips[0].startFrame = 10   // V starts at 1 s
        let upcoming = try XCTUnwrap(Self.composition(doc).upcoming(after: 0.5, within: 1).first { $0.clipId == "V" })
        XCTAssertTrue(upcoming.needsDecoder, "pre-rolled before its fade-in starts")
        let keyedOff = try XCTUnwrap(Self.composition(try Self.document(fades: #","fadeInFrames":10"#, opacity: "0"))
            .layers(at: 0).first { $0.clipId == "V" })
        XCTAssertFalse(keyedOff.hiddenByFade)
        XCTAssertFalse(keyedOff.needsDecoder, "keyed to 0 opacity: not decoded, as before")
    }

    /// Playing forward or backward from a fade-in's first frame reads ahead, as for a visible clip.
    func testAFadeInsFirstFrameStillReadsAhead() throws {
        let comp = Self.videoOnly(try Self.document(fades: #","fadeInFrames":10"#))
        let layers = comp.layers(at: 0)
        XCTAssertEqual(layers.map(\.clipId), ["V"]); XCTAssertFalse(layers[0].isVisible)
        let cx = PreviewCompositor(decodesMedia: false, cacheBudgetBytes: 1 << 30)
        XCTAssertGreaterThan(cx.lookahead(layers, comp: comp, scale: 1, backing: 1, speed: 1), 0)
        XCTAssertGreaterThan(cx.reverseChunk(layers, comp: comp, scale: 1, backing: 1, speed: 1), 1, "1 means no video")
    }

    /// A live opacity gesture during a fade shows the gesture's value faded, as the committed take will play.
    func testALiveOpacityOverrideKeepsTheFade() throws {
        let comp = Self.videoOnly(try Self.document(fades: #","fadeInFrames":10"#))
        let frame = CanvasRect(x: 0, y: 0, width: 200, height: 100)
        let el = StageElement(id: "V", name: "V", rect: frame, kind: .video, opacity: 0.8)
        let half = PreviewCompositor.applyStage([el], to: comp.layers(at: 0.5), frame: frame, scale: 1)
        XCTAssertEqual(half[0].opacity, 0.4, accuracy: 1e-9, "0.8 live × 0.5 fade")
        let first = PreviewCompositor.applyStage([el], to: comp.layers(at: 0), frame: frame, scale: 1)
        XCTAssertEqual(first[0].opacity, 0); XCTAssertTrue(first[0].hiddenByFade)
    }

    func testClipsWithoutFadesRenderAsBefore() throws {
        let comp = Self.composition(try Self.document())
        for time in [0.0, 0.5, 1.9] {
            XCTAssertEqual(opacities(comp, at: time), ["V": 1, "I": 1, "T": 1], "no fade fields: full opacity at \(time) s")
        }
        let keyed = Self.composition(try Self.document(opacity: "0.3"))
        XCTAssertEqual(opacities(keyed, at: 0.0)["V"], 0.3, "the keyed value is used unchanged")
        let plain = Self.videoOnly(try Self.document())
        let zero = Self.videoOnly(try Self.document(fades: #","fadeInFrames":0,"fadeOutFrames":0"#))
        let provider: ExportFramePainter.FrameProvider = { layer, _, _, _ in
            layer.clipId == "V" ? PreviewCompositorTests.solid(200, 120, 40) : nil
        }
        XCTAssertTrue(try Self.painter(plain).paint(time: 0.5, frames: provider).rgba == Self.painter(zero).paint(time: 0.5, frames: provider).rgba,
                      "zero-length fades paint the same bytes as no fades")
    }
}
