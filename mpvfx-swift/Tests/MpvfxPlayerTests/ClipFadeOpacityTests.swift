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
import MpvfxCanvas
@testable import MpvfxPlayer
import MpvfxShared
import XCTest

/// Clip fades on visual clips (issue #89): `fadeInFrames` / `fadeOutFrames` (#85) ramp the layer's opacity, multiplied
/// with the keyframed opacity, in the preview's composition, which export paints too (`ExportFramePainter`).
final class ClipFadeOpacityTests: XCTestCase {
    /// A black 200×100 canvas at 10 fps: a video clip V (lane 1, 20 frames), an image clip I and a text clip T
    /// (lanes 2 and 3, 20 frames each, all from frame 0). `fades` and `opacity` are spliced into every clip.
    private static func document(fades: String = "", opacity: String = "") throws -> NativeProjectDocument {
        let statics: String = opacity.isEmpty ? "" : #","staticParameters":{"transform.opacity":\#(opacity)}"#
        let rest: String = #""muted":false,"effects":[],"parameterTracks":[]\#(statics)\#(fades)"#
        let json: String = """
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

    private static func composition(_ doc: NativeProjectDocument) -> PreviewComposition {
        // Labelled: a trailing closure would bind to `naturalSize`, the first closure parameter with a default.
        PreviewComposition(document: doc, projectDir: URL(fileURLWithPath: "/proj"), engine: nil,
                           fileExists: { _ in true })
    }

    /// Only V: the text and image clips hidden, so a pixel read sees V over the black canvas.
    private static func videoOnly(_ doc: NativeProjectDocument) -> PreviewComposition {
        var edited: NativeProjectDocument = doc
        edited.sequence.tracks[0].clips[0].hidden = true   // T
        edited.sequence.tracks[1].clips[0].hidden = true   // I
        return composition(edited)
    }

    private static func painter(_ comp: PreviewComposition) throws -> ExportFramePainter {
        try ExportFramePainter(composition: comp, width: 200, height: 100, pad: CanvasColor(r: 0, g: 0, b: 0))
    }

    /// Layer opacity by clip id at `time` seconds.
    private func opacities(_ comp: PreviewComposition, at time: Double) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: comp.layers(at: time).map { ($0.clipId, $0.opacity) })
    }

    /// A white 1 s fade-in over the black canvas.
    func testMiddleFrameOfAOneSecondFadeInIsHalfInPreviewAndExport() throws {
        let comp: PreviewComposition = Self.videoOnly(try Self.document(fades: #","fadeInFrames":10"#))
        let middle: Double = try XCTUnwrap(opacities(comp, at: 0.5)["V"])
        XCTAssertEqual(middle, 0.5, accuracy: 1e-9, "frame 5 of a 10-frame fade-in")
        let img: CanvasImage = try Self.painter(comp).paint(time: 0.5) { layer, _, _, _ in
            layer.clipId == "V" ? PreviewCompositorTests.solid(255, 255, 255) : nil
        }
        let offset: Int = (50 * img.width + 100) * 4
        for channel in 0..<3 {
            XCTAssertEqual(Int(img.rgba[offset + channel]), 128, accuracy: 1, "channel \(channel) reads 50%")
        }
        XCTAssertEqual(img.rgba[offset + 3], 255)
    }

    func testTheFadeMultipliesKeyframedOpacity() throws {
        let fadeIn: NativeProjectDocument = try Self.document(fades: #","fadeInFrames":10"#, opacity: "0.5")
        let faded: PreviewComposition = Self.composition(fadeIn)
        XCTAssertEqual(try XCTUnwrap(opacities(faded, at: 0.5)["V"]), 0.25, accuracy: 1e-9, "0.5 keyed × 0.5 fade")
        XCTAssertEqual(try XCTUnwrap(opacities(faded, at: 1.5)["V"]), 0.5, accuracy: 1e-9, "after it: the keyed value")
        let fadeOutDoc: NativeProjectDocument = try Self.document(fades: #","fadeOutFrames":10"#, opacity: "0.5")
        let fadeOut: PreviewComposition = Self.composition(fadeOutDoc)
        XCTAssertEqual(try XCTUnwrap(opacities(fadeOut, at: 1.5)["V"]), 0.25, accuracy: 1e-9, "5 frames before the end")
    }

    func testTextAndImageClipsFadeTheSameWayAsVideo() throws {
        let fades: String = #","fadeInFrames":10,"fadeOutFrames":4"#
        let comp: PreviewComposition = Self.composition(try Self.document(fades: fades))
        XCTAssertEqual(Set(comp.entries.map(\.kind)), [.video, .image, .text])
        for (time, expected) in [(0.0, 0.0), (0.5, 0.5), (1.0, 1.0), (1.8, 0.5)] {
            let found: [String: Double] = opacities(comp, at: time)
            for id in ["V", "I", "T"] {
                let value: Double = try XCTUnwrap(found[id], "\(id) at \(time)")
                XCTAssertEqual(value, expected, accuracy: 1e-9, "\(id) at \(time) s")
            }
        }
    }

    /// A fade-in's first frame draws nothing but keeps the clip decoded and pre-rolled, so the frames after the cut are
    /// ready; a clip keyed fully transparent stays invisible to the decoders as before.
    func testAFadeInsFirstFrameIsHiddenButStillDecoded() throws {
        var doc: NativeProjectDocument = try Self.document(fades: #","fadeInFrames":10"#)
        let first: PreviewLayer = try XCTUnwrap(Self.composition(doc).layers(at: 0).first { $0.clipId == "V" })
        XCTAssertFalse(first.isVisible)
        XCTAssertTrue(first.hiddenByFade)
        XCTAssertTrue(first.needsDecoder)
        doc.sequence.tracks[2].clips[0].startFrame = 10   // V starts at 1 s
        let soon: [PreviewLayer] = Self.composition(doc).upcoming(after: 0.5, within: 1)
        let upcoming: PreviewLayer = try XCTUnwrap(soon.first { $0.clipId == "V" })
        XCTAssertTrue(upcoming.needsDecoder, "pre-rolled before its fade-in starts")
        let keyedDoc: NativeProjectDocument = try Self.document(fades: #","fadeInFrames":10"#, opacity: "0")
        let keyedOff: PreviewLayer = try XCTUnwrap(Self.composition(keyedDoc).layers(at: 0).first { $0.clipId == "V" })
        XCTAssertFalse(keyedOff.hiddenByFade)
        XCTAssertFalse(keyedOff.needsDecoder, "keyed to 0 opacity: not decoded, as before")
    }

    /// Playing forward or backward from a fade-in's first frame reads ahead, as for a visible clip.
    func testAFadeInsFirstFrameStillReadsAhead() throws {
        let comp: PreviewComposition = Self.videoOnly(try Self.document(fades: #","fadeInFrames":10"#))
        let layers: [PreviewLayer] = comp.layers(at: 0)
        XCTAssertEqual(layers.map(\.clipId), ["V"])
        XCTAssertFalse(layers[0].isVisible)
        let compositor: PreviewCompositor = PreviewCompositor(decodesMedia: false, cacheBudgetBytes: 1 << 30)
        XCTAssertGreaterThan(compositor.lookahead(layers, comp: comp, scale: 1, backing: 1, speed: 1), 0)
        let chunk: Int = compositor.reverseChunk(layers, comp: comp, scale: 1, backing: 1, speed: 1)
        XCTAssertGreaterThan(chunk, 1, "1 means no video")
    }

    /// A live opacity gesture during a fade shows the gesture's value faded, as the committed take will play.
    func testALiveOpacityOverrideKeepsTheFade() throws {
        let comp: PreviewComposition = Self.videoOnly(try Self.document(fades: #","fadeInFrames":10"#))
        let frame: CanvasRect = CanvasRect(x: 0, y: 0, width: 200, height: 100)
        let element: StageElement = StageElement(id: "V", name: "V", rect: frame, kind: .video, opacity: 0.8)
        let half: [PreviewLayer] = PreviewCompositor.applyStage([element], to: comp.layers(at: 0.5),
                                                                 frame: frame, scale: 1)
        XCTAssertEqual(half[0].opacity, 0.4, accuracy: 1e-9, "0.8 live × 0.5 fade")
        let first: [PreviewLayer] = PreviewCompositor.applyStage([element], to: comp.layers(at: 0),
                                                                  frame: frame, scale: 1)
        XCTAssertEqual(first[0].opacity, 0)
        XCTAssertTrue(first[0].hiddenByFade)
    }

    func testClipsWithoutFadesRenderAsBefore() throws {
        let comp: PreviewComposition = Self.composition(try Self.document())
        for time in [0.0, 0.5, 1.9] {
            XCTAssertEqual(opacities(comp, at: time), ["V": 1, "I": 1, "T": 1], "no fades: full opacity at \(time) s")
        }
        let keyed: PreviewComposition = Self.composition(try Self.document(opacity: "0.3"))
        XCTAssertEqual(opacities(keyed, at: 0.0)["V"], 0.3, "the keyed value is used unchanged")
        let plain: PreviewComposition = Self.videoOnly(try Self.document())
        let zero: PreviewComposition = Self.videoOnly(try Self.document(fades: #","fadeInFrames":0,"fadeOutFrames":0"#))
        let provider: ExportFramePainter.FrameProvider = { layer, _, _, _ in
            layer.clipId == "V" ? PreviewCompositorTests.solid(200, 120, 40) : nil
        }
        let plainBytes: [UInt8] = try Self.painter(plain).paint(time: 0.5, frames: provider).rgba
        let zeroBytes: [UInt8] = try Self.painter(zero).paint(time: 0.5, frames: provider).rgba
        XCTAssertTrue(plainBytes == zeroBytes, "zero-length fades paint the same bytes as no fades")
    }
}
