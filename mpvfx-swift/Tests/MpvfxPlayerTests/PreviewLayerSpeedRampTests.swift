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
import OneTakeMedia
@testable import MpvfxPlayer

/// The source frame a ramped layer shows: export asks `sourceTime(at:)` for every output frame.
final class PreviewLayerSpeedRampTests: XCTestCase {
    private func layer(rate: Double = 1, ramp: NativeSpeedRamp? = nil) -> PreviewLayer {
        var l = PreviewLayer(clipId: "c", source: "/x.mov", kind: .video, start: 2, end: 12, sourceIn: 5, rate: rate,
                             box: CanvasRect(x: 0, y: 0, width: 10, height: 10))
        l.speedRamp = ramp; l.timelineFPS = 30
        return l
    }

    func testConstantTwoXRampShowsTheSameSourceFramesAsPlaybackRateTwo() {
        let ramped = layer(ramp: NativeSpeedRamp(points: [.init(t: 0, speed: 2)])), plain = layer(rate: 2)
        for frame in 0..<300 {
            let t = 2 + Double(frame) / 30
            XCTAssertEqual(ramped.sourceTime(at: t), plain.sourceTime(at: t), accuracy: 1e-9, "frame \(frame)")
        }
    }

    func testRampedLayerListsTheSourceFramesOfItsTimeMap() {
        let ramp = NativeSpeedRamp(points: [.init(t: 0, speed: 1), .init(t: 30, speed: 3)])
        let l = layer(ramp: ramp)
        for frame in [0, 1, 15, 30, 45, 90] {
            let expected = 5 + ramp.sourcePosition(atClipFrame: Double(frame)) / 30
            XCTAssertEqual(l.sourceTime(at: 2 + Double(frame) / 30), expected, accuracy: 1e-9)
        }
    }

    // MARK: Decoding along the time map (#270)

    /// A source whose frame n is solid red value 4n, so a decoded picture names the source frame it came from.
    private func numberedSource(frames: Int = 120, in dir: URL) throws -> String {
        var v = TestMedia.SolidVideo(segments: (0..<frames).map { (rgb: [UInt8(min(255, $0 * 2)), 0, 0], seconds: 1.0 / 30) })
        v.width = 32; v.height = 18
        return try v.write(to: dir.appendingPathComponent("numbered.mov").path)
    }

    private func sourceFrame(_ img: CanvasImage) -> Int {
        let i = (img.height / 2 * img.width + img.width / 2) * 4
        return Int(img.rgba[i]) / 2
    }

    private func rampedLayer(_ src: String, ramp: NativeSpeedRamp, id: String = "r") -> PreviewLayer {
        // Source-in sits a quarter frame into frame 0, so a mapped time never lands on a frame boundary.
        var l = PreviewLayer(clipId: id, source: src, kind: .video, start: 0, end: 4, sourceIn: 0.25 / 30, startFrame: 0, endFrame: 120,
                             box: CanvasRect(x: 0, y: 0, width: 32, height: 18))
        l.speedRamp = ramp; l.timelineFPS = 30
        return l
    }

    private let tiny = PreviewDecodeSize(width: 32, height: 18)

    func testDecodedFramesFollowTheTimeMapWhileOneStreamKeepsPlaying() throws {
        let dir = try TestMedia.scratch("ramp-preview"); defer { try? FileManager.default.removeItem(at: dir) }
        let src = try numberedSource(in: dir)
        let ramp = NativeSpeedRamp(points: [.init(t: 0, speed: 1), .init(t: 20, speed: 2), .init(t: 40, speed: 0.5), .init(t: 60, speed: 1)])
        let layer = rampedLayer(src, ramp: ramp)
        let cx = PreviewCompositor()
        let lane = try XCTUnwrap(cx.lane(for: layer, fps: 30))
        for frame in 0..<60 {
            lane.request(frame: frame, ahead: 0, size: tiny); lane.wait()
            let expected = Int((layer.sourceTime(at: Double(frame) / 30) * 30).rounded(.down))
            let image = try XCTUnwrap(cx.cache.frame(lane: layer.laneKey, frame: frame), "frame \(frame)")
            XCTAssertEqual(sourceFrame(image), expected, "timeline frame \(frame)")
        }
        XCTAssertEqual(lane.restarts, 1, "playing through the ramp reads one stream; it does not seek per frame")
        cx.stopAll()
    }

    func testSkippingAheadInsideARampKeepsTheMappedFrame() throws {
        let dir = try TestMedia.scratch("ramp-skip"); defer { try? FileManager.default.removeItem(at: dir) }
        let src = try numberedSource(in: dir)
        let layer = rampedLayer(src, ramp: NativeSpeedRamp(points: [.init(t: 0, speed: 0.5), .init(t: 30, speed: 2)]))
        let cx = PreviewCompositor()
        let lane = try XCTUnwrap(cx.lane(for: layer, fps: 30))
        lane.request(frame: 2, ahead: 0, size: tiny); lane.wait()
        lane.request(frame: 28, ahead: 0, size: tiny); lane.wait()   // within a second: the stream reads through, no restart
        XCTAssertEqual(lane.restarts, 1)
        let image = try XCTUnwrap(cx.cache.frame(lane: layer.laneKey, frame: 28))
        XCTAssertEqual(sourceFrame(image), Int((layer.sourceTime(at: 28.0 / 30) * 30).rounded(.down)))
        cx.stopAll()
    }

    func testEditingARampPointStartsANewLaneForThatClipOnly() throws {
        let a = NativeSpeedRamp(points: [.init(t: 0, speed: 1), .init(t: 30, speed: 2)])
        var b = a; b.points[1].speed = 3
        let l1 = rampedLayer("/x.mov", ramp: a), l2 = rampedLayer("/x.mov", ramp: b), other = rampedLayer("/x.mov", ramp: a, id: "o")
        XCTAssertEqual(l1.laneKey, rampedLayer("/x.mov", ramp: a).laneKey, "the same ramp keeps its lane")
        XCTAssertNotEqual(l1.laneKey, l2.laneKey)
        var unramped = l1; unramped.speedRamp = nil
        XCTAssertNotEqual(l1.laneKey, unramped.laneKey)
        XCTAssertNotEqual(l1.laneKey, other.laneKey)
    }

    func testAnEditedRampShowsTheOldPictureUntilItsNewFramesArriveThenTheNewMapping() throws {
        let dir = try TestMedia.scratch("ramp-edit"); defer { try? FileManager.default.removeItem(at: dir) }
        let src = try numberedSource(in: dir)
        let before = rampedLayer(src, ramp: NativeSpeedRamp(points: [.init(t: 0, speed: 1)]))
        let after = rampedLayer(src, ramp: NativeSpeedRamp(points: [.init(t: 0, speed: 2)]))
        let cx = PreviewCompositor()
        let oldLane = try XCTUnwrap(cx.lane(for: before, fps: 30))
        oldLane.request(frame: 20, ahead: 0, size: tiny); oldLane.wait()
        cx.drew(try XCTUnwrap(cx.picture(for: before, want: 20)), for: before)
        // The edit: nothing of the new lane is decoded yet, and the draw still has the clip's earlier picture.
        let stand = try XCTUnwrap(cx.picture(for: after, want: 20))
        XCTAssertFalse(stand.exact)
        XCTAssertEqual(sourceFrame(stand.image), 20)
        let newLane = try XCTUnwrap(cx.lane(for: after, fps: 30))
        newLane.request(frame: 20, ahead: 0, size: tiny); newLane.wait()
        let fresh = try XCTUnwrap(cx.picture(for: after, want: 20))
        XCTAssertTrue(fresh.exact)
        XCTAssertEqual(sourceFrame(fresh.image), Int((after.sourceTime(at: 20.0 / 30) * 30).rounded(.down)))
        XCTAssertEqual(sourceFrame(fresh.image), 40)
        cx.stopAll()
    }

    /// A1: the preview's picture at 20 timeline times is the picture export decodes at the same time (export reads the
    /// source at `sourceTime(at:)` for every output frame).
    func testPreviewPicturesEqualTheFramesExportDecodesAtTwentyTimes() throws {
        let dir = try TestMedia.scratch("ramp-parity"); defer { try? FileManager.default.removeItem(at: dir) }
        let src = try numberedSource(in: dir)
        let ramp = NativeSpeedRamp(points: [.init(t: 0, speed: 1), .init(t: 24, speed: 0.4), .init(t: 48, speed: 2.5), .init(t: 72, speed: 1)])
        let layer = rampedLayer(src, ramp: ramp)
        let cx = PreviewCompositor()
        let lane = try XCTUnwrap(cx.lane(for: layer, fps: 30))
        let reader = try VideoFrameReader(path: src)
        let frames = (0..<20).map { $0 * 4 }
        for frame in frames {
            lane.request(frame: frame, ahead: 0, size: tiny); lane.wait()
            let preview = try XCTUnwrap(cx.cache.frame(lane: layer.laneKey, frame: frame), "frame \(frame)")
            let exported = try reader.frame(at: layer.sourceTime(at: Double(frame) / 30), width: tiny.width, height: tiny.height)
            XCTAssertEqual(preview.rgba.count, exported.rgba.count)
            let worst = zip(preview.rgba, exported.rgba).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(worst, 1, "timeline frame \(frame)")
        }
        cx.stopAll()
    }
}
