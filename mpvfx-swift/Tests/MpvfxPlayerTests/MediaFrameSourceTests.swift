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

/// Preview decoding through the media engine, on inputs the engine wrote itself (TestMedia).
final class MediaFrameSourceTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws { dir = try TestMedia.scratch("frames") }
    override func tearDown() { if let dir { try? FileManager.default.removeItem(at: dir) } }

    /// 1 s red then 1 s blue, 64×36 @30fps, lossless (PNG frames in MOV) so pixel values are exact.
    func makeVideo() throws -> String { try TestMedia.SolidVideo.redThenBlue.write(to: dir.appendingPathComponent("rb.mov").path) }

    func centre(_ img: CanvasImage) -> [UInt8] { let i = (img.height / 2 * img.width + img.width / 2) * 4; return Array(img.rgba[i..<i + 3]) }

    func video(_ src: String, id: String = "c", start: Double, end: Double, sourceIn: Double, rate: Double = 1, fps: Double = 30) -> PreviewLayer {
        PreviewLayer(clipId: id, source: src, kind: .video, start: start, end: end, sourceIn: sourceIn, rate: rate,
                     startFrame: Int((start * fps).rounded()), endFrame: Int((end * fps).rounded()),
                     box: CanvasRect(x: 0, y: 0, width: 64, height: 36))
    }
    let small = PreviewDecodeSize(width: 32, height: 18)

    func testDecodesFramesAtTimeWithSourceInAndReusesStream() throws {
        let src = try makeVideo()
        let cx = PreviewCompositor()
        let clip = video(src, start: 2, end: 4, sourceIn: 0)
        let red = try XCTUnwrap(cx.decodeNow(clip, time: 2.2, fps: 30, size: small))
        XCTAssertEqual(red.width, 32); XCTAssertEqual(red.height, 18)
        XCTAssertEqual(centre(red), [255, 0, 0])
        let lane = try XCTUnwrap(cx.lanes[clip.laneKey])
        _ = cx.decodeNow(clip, time: 2.2 + 1.0 / 30, fps: 30, size: small)
        XCTAssertEqual(lane.restarts, 1, "next frame reuses the running stream")
        XCTAssertEqual(centre(try XCTUnwrap(cx.decodeNow(clip, time: 3.5, fps: 30, size: small))), [0, 0, 255])
        XCTAssertEqual(lane.restarts, 2, "a jump past a second restarts at the new time")
        let trimmed = video(src, id: "t", start: 0, end: 1, sourceIn: 1)
        XCTAssertEqual(centre(try XCTUnwrap(cx.decodeNow(trimmed, time: 0.2, fps: 30, size: small))), [0, 0, 255], "sourceIn offsets into the media")
        cx.stopAll()
    }

    func testPlaybackRateMapsTimelineToSourceTime() throws {
        let src = try makeVideo()
        let cx = PreviewCompositor()
        let fast = video(src, id: "f", start: 0, end: 1, sourceIn: 0, rate: 2)
        XCTAssertEqual(fast.sourceTime(at: 0.6), 1.2, accuracy: 1e-9)
        XCTAssertEqual(centre(try XCTUnwrap(cx.decodeNow(fast, time: 0.3, fps: 30, size: small))), [255, 0, 0])
        XCTAssertEqual(centre(try XCTUnwrap(cx.decodeNow(fast, time: 0.3 + 1.0 / 30, fps: 30, size: small))), [255, 0, 0])
        XCTAssertEqual(centre(try XCTUnwrap(cx.decodeNow(fast, time: 0.6, fps: 30, size: small))), [0, 0, 255], "2x reaches the blue half at 0.5s")
        let slow = video(src, id: "s", start: 0, end: 4, sourceIn: 0, rate: 0.5)
        XCTAssertEqual(centre(try XCTUnwrap(cx.decodeNow(slow, time: 1.5, fps: 30, size: small))), [255, 0, 0], "0.5x is still red at 1.5s")
        XCTAssertEqual(centre(try XCTUnwrap(cx.decodeNow(slow, time: 2.5, fps: 30, size: small))), [0, 0, 255])
        cx.stopAll()
    }

    /// Decoding slower than playback: the playhead has moved on by the time a frame is decoded. That frame is still
    /// the newest picture of the clip and must be kept to be shown; dropping it left the preview frozen on an old frame
    /// for as long as decoding stayed behind.
    func testAFrameThePlayheadPassedWhileDecodingIsKeptWhenNothingNewerIsCached() throws {
        let src = try makeVideo()
        let cx = PreviewCompositor()
        let clip = video(src, start: 0, end: 2, sourceIn: 0)
        let lane = try XCTUnwrap(cx.lane(for: clip, fps: 30))
        lane.request(frame: 3, ahead: 0, size: small); lane.wait()
        XCTAssertTrue(cx.cache.contains(lane: clip.laneKey, frame: 3))
        // The playhead is at 20 while frame 4 decodes (lane queue idle, so the step runs here).
        lane.lock.lock(); lane.want = 20; lane.lock.unlock()
        XCTAssertTrue(lane.stepVideo(want: 4, ahead: 0, size: small))
        XCTAssertTrue(cx.cache.contains(lane: clip.laneKey, frame: 4), "the newest picture is kept for the display")
        XCTAssertEqual(cx.cache.nearest(lane: clip.laneKey, to: 20)?.frame, 4)
        // An older frame than one already cached is still dropped.
        cx.cache.store(try XCTUnwrap(cx.cache.frame(lane: clip.laneKey, frame: 4)), lane: clip.laneKey, frame: 10)
        let skipped = lane.framesSkipped
        XCTAssertTrue(lane.stepVideo(want: 5, ahead: 0, size: small))
        XCTAssertFalse(cx.cache.contains(lane: clip.laneKey, frame: 5))
        XCTAssertEqual(lane.framesSkipped, skipped + 1)
        cx.stopAll()
    }

    func testDecodeAheadFillsTheCacheAndFallingBehindSkips() throws {
        let src = try makeVideo()
        let cx = PreviewCompositor()
        let clip = video(src, start: 0, end: 2, sourceIn: 0)
        let lane = try XCTUnwrap(cx.lane(for: clip, fps: 30))
        lane.request(frame: 10, ahead: 6, size: small); lane.wait()
        XCTAssertEqual(cx.cache.cachedFrames(lane: clip.laneKey, from: 0, to: 60), Array(10...16), "playhead frame plus six ahead")
        XCTAssertEqual(lane.restarts, 1)
        // The playhead jumped 20 frames (decoding fell behind): read through, drop the stale frames, no restart.
        lane.request(frame: 36, ahead: 0, size: small); lane.wait()
        XCTAssertEqual(lane.restarts, 1, "within a second: no new stream")
        XCTAssertEqual(lane.framesSkipped, 19, "frames 17…35 decoded and dropped")
        XCTAssertTrue(cx.cache.contains(lane: clip.laneKey, frame: 36))
        XCTAssertFalse(cx.cache.contains(lane: clip.laneKey, frame: 20))
        // Scrubbing backwards restarts the stream at the wanted frame.
        lane.request(frame: 2, ahead: 0, size: small); lane.wait()
        XCTAssertEqual(lane.restarts, 2)
        XCTAssertEqual(centre(try XCTUnwrap(cx.cache.frame(lane: clip.laneKey, frame: 2))), [255, 0, 0])
        // Past the end of the media: holds without spinning.
        let long = video(src, id: "long", start: 0, end: 4, sourceIn: 1.5)
        let l2 = try XCTUnwrap(cx.lane(for: long, fps: 30))
        l2.request(frame: 30, ahead: 0, size: small); l2.wait()
        XCTAssertFalse(cx.cache.contains(lane: long.laneKey, frame: 30))
        XCTAssertLessThanOrEqual(l2.restarts, 1)
        cx.stopAll()
    }

    func testReversePlaybackDecodesInChunksInsteadOfSeekingEveryFrame() throws {
        let src = try makeVideo()
        let cx = PreviewCompositor()
        let clip = video(src, start: 0, end: 2, sourceIn: 0)
        let lane = try XCTUnwrap(cx.lane(for: clip, fps: 30))
        // Playing backward from frame 50, one frame at a time, with 8-frame chunks.
        for f in stride(from: 50, through: 20, by: -1) {
            lane.request(frame: f, ahead: 0, behind: 8, size: small); lane.wait()
            XCTAssertTrue(cx.cache.contains(lane: clip.laneKey, frame: f), "frame \(f) is ready when shown")
        }
        XCTAssertLessThanOrEqual(lane.restarts, 6, "31 frames backward: one stream start per 8-frame chunk, not one per frame")
        XCTAssertEqual(centre(try XCTUnwrap(cx.cache.frame(lane: clip.laneKey, frame: 45))), [0, 0, 255])
        XCTAssertEqual(centre(try XCTUnwrap(cx.cache.frame(lane: clip.laneKey, frame: 25))), [255, 0, 0])
        // The chunk below the playhead is decoded before it is needed.
        XCTAssertTrue(cx.cache.contains(lane: clip.laneKey, frame: 13))
        cx.stopAll()
    }

    func testFramesKeepTheMediaAspectInsideTheBox() throws {
        let src = try makeVideo()   // 16:9
        // The stream pads to the requested size with transparent rows.
        let stream = try MediaFrameStream(source: src, frames: .init(from: 0, fps: 30, width: 32, height: 32))
        let padded = try XCTUnwrap(stream.next())
        XCTAssertEqual(padded.width, 32); XCTAssertEqual(padded.height, 32)
        XCTAssertEqual(padded.rgba[3], 0, "letterbox rows are transparent")
        XCTAssertEqual(centre(padded), [255, 0, 0])
        XCTAssertEqual(try XCTUnwrap(PreviewDecodeLane.opaqueAspect(padded)), 16.0 / 9, accuracy: 0.1)
        // A lane learns the media's aspect from its first frame and decodes at that aspect from then on.
        let cx = PreviewCompositor()
        let img = try XCTUnwrap(cx.decodeNow(video(src, start: 0, end: 2, sourceIn: 0), time: 0.1, fps: 30, size: PreviewDecodeSize(width: 32, height: 32)))
        XCTAssertEqual(img.width, 32); XCTAssertEqual(img.height, 18)
        let lane = try XCTUnwrap(cx.lanes.values.first)
        XCTAssertEqual(try XCTUnwrap(lane.mediaAspect), 16.0 / 9, accuracy: 0.1)
        XCTAssertEqual(lane.restarts, 2, "one restart to drop the letterbox once the aspect is known")
        // A box animating toward a square keeps the running stream.
        lane.request(frame: 4, ahead: 0, size: PreviewDecodeSize(width: 32, height: 26)); lane.wait()
        lane.request(frame: 5, ahead: 0, size: PreviewDecodeSize(width: 32, height: 22)); lane.wait()
        XCTAssertEqual(lane.restarts, 2)
        let f5 = try XCTUnwrap(cx.cache.frame(lane: lane.key, frame: 5))
        XCTAssertEqual(f5.width, 32); XCTAssertEqual(f5.height, 18)
        cx.stopAll()
    }

    func testImageClipDecodesOneStillFrame() throws {
        let cx = PreviewCompositor()
        // Stills (JPEG, PNG, BMP) decode through the engine like videos, as one frame.
        let jpg = try TestMedia.writeJPEG(TestMedia.solid([0, 128, 0], width: 40, height: 40), width: 40, height: 40,
                                          to: dir.appendingPathComponent("g.jpg").path)
        let clip = PreviewLayer(clipId: "i", source: jpg, kind: .image, start: 1, end: 5, sourceIn: 0, startFrame: 30, endFrame: 150,
                                box: CanvasRect(x: 0, y: 0, width: 16, height: 16))
        let sq = PreviewDecodeSize(width: 16, height: 16)
        let a = try XCTUnwrap(cx.decodeNow(clip, time: 1.0, fps: 30, size: sq)), b = try XCTUnwrap(cx.decodeNow(clip, time: 4.9, fps: 30, size: sq))
        XCTAssertEqual(Int(centre(a)[1]), 128, accuracy: 4); XCTAssertLessThan(Int(centre(a)[0]), 8)
        XCTAssertEqual(a, b, "same still for the whole clip")
        XCTAssertEqual(cx.lanes[clip.laneKey]?.framesDecoded, 1, "decoded once")
        #if os(Linux)
        let png = dir.appendingPathComponent("r.png").path
        let t = CairoImageTarget(width: 8, height: 8); t.canvas.fillRect(CanvasRect(x: 0, y: 0, width: 8, height: 8), CanvasColor(r: 1, g: 0, b: 0))
        XCTAssertEqual(t.writePNG(png), 0)
        var pc = clip; pc.clipId = "p"; pc.source = png
        XCTAssertEqual(centre(try XCTUnwrap(cx.decodeNow(pc, time: 2, fps: 30, size: sq))), [255, 0, 0])
        #endif
        cx.stopAll()
    }

    #if os(Linux)
    func testDrawCompositesDecodedFramesAfterAsyncDecode() throws {
        let src = try makeVideo()
        let cx = PreviewCompositor()
        // Point both video clips at the test video: A (bottom, full) and B (top, cropped to its right half).
        var d2 = try PreviewCompositorTests.document()
        for i in d2.assets.indices where d2.assets[i].kind == .video { d2.assets[i].source = src }
        d2.sequence.tracks[1].clips[0].crop = .init(top: 0, right: 0, bottom: 0, left: 100)
        d2.sequence.tracks[0].clips = []   // no image clip here
        let comp = PreviewComposition(document: d2, projectDir: nil, engine: nil, fileExists: { $0 == src })
        cx.composition = comp
        let ready = expectation(description: "frame"); ready.assertForOverFulfill = false
        cx.frameReady = { ready.fulfill() }
        let t = CairoImageTarget(width: 64, height: 32)
        let rect = CanvasRect(x: 0, y: 0, width: 64, height: 32)
        cx.draw(t.canvas, in: rect, time: 0.8, elements: [], context: FrameDrawContext(backingScale: 2))
        XCTAssertEqual(cx.lanes.count, 2, "one decoder per visible layer")
        wait(for: [ready], timeout: 10)
        for l in cx.lanes.values { l.wait() }
        cx.frameReady = nil
        cx.draw(t.canvas, in: rect, time: 0.8, elements: [], context: FrameDrawContext(backingScale: 2))
        XCTAssertEqual(cx.lastShown.map(\.exact), [true, true])
        // B starts 0.4 s into the media: blue on its right half over A's red.
        let l = t.pixel(10, 16), r = t.pixel(54, 16)
        XCTAssertEqual([l.r, l.g, l.b], [255, 0, 0]); XCTAssertEqual([r.r, r.g, r.b], [0, 0, 255])
        let lane = try XCTUnwrap(cx.lanes.values.first)
        XCTAssertEqual(lane.size, PreviewDecodeSize(width: 128, height: 64), "decoded at 2× for the backing scale")
        cx.stopAll()
    }
    #endif
}

/// The preview decodes a JPEG still upright by its EXIF orientation (as export does), at the upright aspect.
final class PreviewExifOrientationTests: XCTestCase {
    func testStillDecodeAppliesTheExifOrientation() throws {
        let dir = try TestMedia.scratch("exif")
        defer { try? FileManager.default.removeItem(at: dir) }
        // 40×20 red with a blue 10×10 square at the stored top-left.
        let stored = TestMedia.blueCornerOnRed(side: 10, width: 40, height: 20)
        let plain = try TestMedia.writeJPEG(stored, width: 40, height: 20, to: dir.appendingPathComponent("plain.jpg").path)
        let rotated = dir.appendingPathComponent("rot6.jpg").path
        // APP1 Exif, little-endian TIFF, IFD0 Orientation = 6.
        let tiff: [UInt8] = [0x49, 0x49, 42, 0, 8, 0, 0, 0, 1, 0, 0x12, 0x01, 3, 0, 1, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0]
        let app1: [UInt8] = [0x45, 0x78, 0x69, 0x66, 0, 0] + tiff
        let jpeg = [UInt8](try Data(contentsOf: URL(fileURLWithPath: plain)))
        try Data(jpeg.prefix(2) + [0xFF, 0xE1, 0, UInt8(app1.count + 2)] + app1 + jpeg.dropFirst(2)).write(to: URL(fileURLWithPath: rotated))
        let stream = try MediaFrameStream(source: rotated, frames: .still(width: 20, height: 40))
        let img = try XCTUnwrap(stream.next())
        XCTAssertNil(stream.next(), "a still is one frame")
        XCTAssertEqual(img.width, 20); XCTAssertEqual(img.height, 40)
        func px(_ x: Int, _ y: Int) -> [UInt8] { let i = (y * img.width + x) * 4; return Array(img.rgba[i..<(i + 4)]) }
        XCTAssertGreaterThan(px(15, 4)[2], 150, "the stored top-left square is top-right once upright \(px(15, 4))")
        XCTAssertGreaterThan(px(4, 4)[0], 150, "red top-left \(px(4, 4))"); XCTAssertEqual(px(4, 34)[3], 255, "no letterbox: the picture fills 20×40")
    }
}
