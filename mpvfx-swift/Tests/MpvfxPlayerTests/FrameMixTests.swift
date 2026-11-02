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
@testable import MpvfxPlayer

/// Frame mixing (#272): slow sections blend the two source frames around the mapped position in linear light, in the
/// preview's decode lanes and in export's frame decoder alike.
final class FrameMixTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws { dir = try TestMedia.scratch("frame-mix") }
    override func tearDown() { if let dir { try? FileManager.default.removeItem(at: dir) } }

    private func solid(_ v: UInt8) -> CanvasImage {
        CanvasImage(width: 4, height: 4, rgba: TestMedia.solid([v, v, v], width: 4, height: 4))
    }
    private func centre(_ rgba: [UInt8], width: Int = 4, height: Int = 4) -> [UInt8] {
        let i = (height / 2 * width + width / 2) * 4
        return Array(rgba[i..<i + 4])
    }

    // A1: black and white at 0.5 give the linear-light midpoint (sRGB 188), not the 128 an sRGB average gives.
    func testBlackAndWhiteAtHalfIsTheLinearLightMidpoint() {
        let mix = FrameMix.mixed(solid(0), solid(255), fraction: 0.5)
        let c = centre(mix.rgba)
        for channel in 0..<3 { XCTAssertEqual(Int(c[channel]), 188, accuracy: 1) }
        XCTAssertEqual(c[3], 255)
    }

    // A2: at fraction 0 the output is frame A exactly (and at 1 frame B).
    func testFractionZeroIsFrameAAndOneIsFrameB() {
        var a = solid(30)
        a.rgba[0] = 200; a.rgba[5] = 7
        let b = solid(90)
        XCTAssertEqual(FrameMix.mixed(a, b, fraction: 0), a)
        XCTAssertEqual(FrameMix.mixed(a, b, fraction: 1), b)
    }

    func testTransparentLetterboxDoesNotDarkenTheMix() {
        let clear = CanvasImage(width: 2, height: 1, rgba: [0, 0, 0, 0, 255, 255, 255, 255])
        let other = CanvasImage(width: 2, height: 1, rgba: [255, 255, 255, 255, 255, 255, 255, 255])
        let mix = FrameMix.mixed(clear, other, fraction: 0.4)
        // Where only `other` has a picture its colour is kept (not darkened by the transparent pixel) at 0.4 of the alpha.
        for channel in 0..<3 { XCTAssertEqual(Int(mix.rgba[channel]), 255, accuracy: 1) }
        XCTAssertEqual(Int(mix.rgba[3]), 102, accuracy: 1)
        XCTAssertEqual(Array(mix.rgba[4..<8]), [255, 255, 255, 255])
    }

    // MARK: Decode lane and export

    /// One black then one white frame (30 fps, 64x36), played at half speed: timeline frames 0, 1, 2 land on source
    /// positions 0, 0.5, 1.
    private func document(blend: String?) throws -> NativeProjectDocument {
        _ = try TestMedia.SolidVideo(width: 64, height: 36, fps: 30,
                                     segments: [(rgb: [0, 0, 0], seconds: 1.0 / 30), (rgb: [255, 255, 255], seconds: 1.0 / 30)])
            .write(to: dir.appendingPathComponent("bw.mov").path)
        let mode = blend.map { #","blend":"\#($0)""# } ?? ""
        return try parseNativeProjectDocument(try NativeJSONValue.parse(#"""
        {"schemaVersion":1,"id":"project:p","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":64,"height":36,"background":"#000000"},
         "assets":[{"id":"asset:a","kind":"video","name":"bw.mov","source":"bw.mov","durationFrames":2}],
         "sequence":{"id":"sequence:main","name":"Main","tracks":[{"id":"track:v1","kind":"video","clips":[
          {"id":"clip:a","assetId":"asset:a","startFrame":0,"durationFrames":4,"sourceInFrame":0,"muted":true,
           "speedRamp":{"v":1,"kind":"speed-ramp","points":[{"t":0,"speed":0.5}]\#(mode)},
           "effects":[],"parameterTracks":[]}]}]}}
        """#), engine: nil)
    }

    private func previewRed(_ doc: NativeProjectDocument, frame: Int) throws -> Int {
        let cx = PreviewCompositor()
        defer { cx.stopAll() }
        let comp = PreviewComposition(document: doc, projectDir: dir, engine: nil)
        let layer = try XCTUnwrap(comp.layers(at: Double(frame) / 30).first)
        let raw = try XCTUnwrap(cx.decodeRawNow(layer, time: Double(frame) / 30, fps: 30, size: PreviewDecodeSize(width: 64, height: 36)))
        return Int(centre(raw.image.rgba, width: 64, height: 36)[0])
    }

    private func exportedRed(_ doc: NativeProjectDocument, frame: Int) throws -> Int {
        let frames = try PreviewExportFrames(NativeExportFrameRequest(document: doc, projectDir: dir.path, width: 64, height: 36))
        return Int(centre(try frames.frame(at: Double(frame) / 30), width: 64, height: 36)[0])
    }

    func testPreviewAndExportMixTheFrameBetweenTwoSourceFramesInLinearLight() throws {
        let doc = try document(blend: "mix")
        for (frame, expected) in [(0, 0), (1, 188), (2, 255)] {
            XCTAssertEqual(try previewRed(doc, frame: frame), expected, accuracy: 1, "preview, timeline frame \(frame)")
            XCTAssertEqual(try exportedRed(doc, frame: frame), expected, accuracy: 1, "export, timeline frame \(frame)")
        }
    }

    func testWithoutBlendTheSlowFrameShowsTheEarlierSourceFrame() throws {
        for blend in [nil, "none"] {
            let doc = try document(blend: blend)
            XCTAssertEqual(try previewRed(doc, frame: 1), 0, "preview, blend \(blend ?? "absent")")
            XCTAssertEqual(try exportedRed(doc, frame: 1), 0, "export, blend \(blend ?? "absent")")
        }
    }

    func testTheMixIsPartOfTheLaneKey() throws {
        let plain = PreviewComposition(document: try document(blend: nil), projectDir: dir, engine: nil)
        let mixed = PreviewComposition(document: try document(blend: "mix"), projectDir: dir, engine: nil)
        XCTAssertNotEqual(try XCTUnwrap(plain.layers(at: 0).first).laneKey, try XCTUnwrap(mixed.layers(at: 0).first).laneKey)
    }

    /// Slow motion shows each pair of neighbouring source frames for several output frames: the reader is asked for each
    /// source frame once, not twice per output frame (which also seeks it back on every draw).
    func testAMixedStreamReadsEachSourceFrameOnce() throws {
        var video = TestMedia.SolidVideo(segments: (0..<30).map { (rgb: [UInt8($0 * 4), 0, 0], seconds: 1.0 / 30) })
        video.width = 32; video.height = 18
        let src = try video.write(to: dir.appendingPathComponent("numbered.mov").path)
        var layer = PreviewLayer(clipId: "m", source: src, kind: .video, start: 0, end: 4, sourceIn: 0, startFrame: 0, endFrame: 120,
                                 box: CanvasRect(x: 0, y: 0, width: 32, height: 18))
        layer.speedRamp = NativeSpeedRamp(points: [.init(t: 0, speed: 0.25)], blend: "mix"); layer.timelineFPS = 30
        let cx = PreviewCompositor()
        defer { cx.stopAll() }
        let lane = try XCTUnwrap(cx.lane(for: layer, fps: 30))
        for frame in 0..<40 {   // source positions 0 ... 9.75: source frames 0 ... 10
            lane.request(frame: frame, ahead: 0, size: PreviewDecodeSize(width: 32, height: 18)); lane.wait()
            XCTAssertTrue(cx.cache.contains(lane: layer.laneKey, frame: frame), "timeline frame \(frame)")
        }
        let asked = try XCTUnwrap(try lane.engineStats()).frames
        XCTAssertLessThanOrEqual(asked, 12, "11 source frames, each read once (twice per output frame would be 80)")
        // A mixed frame lies between its two source frames.
        let between = try XCTUnwrap(cx.cache.frame(lane: layer.laneKey, frame: 2))   // source position 0.5: frames 0 and 1
        let value = Int(between.rgba[(9 * 32 + 16) * 4])
        XCTAssertGreaterThan(value, 0); XCTAssertLessThan(value, 4)
    }
}
