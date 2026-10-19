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
@testable import MpvfxTimeline
import MpvfxCanvas
import MpvfxShared
import OneTakeKeyframes

/// Filmstrips and waveforms reach the drawn timeline (useRenderClipContent): the feeder asks the loaders for what
/// the visible clips need, answers land asynchronously and trigger a redraw, and the clip menu's "Show thumbnails"
/// toggle turns filmstrips off and back on.
final class TimelineMediaFeederTests: XCTestCase {
    static let size = CanvasSize(1266, 333)

    final class FakeLoaders {
        var frameRequests: [TimelineMediaFeeder.FramesRequest] = []
        var peakRequests: [String] = []
        var pendingFrames: [(TimelineMediaFeeder.FramesRequest, (TimelineThumbnailStrip?) -> Void)] = []
        var pendingPeaks: [(String, ([Double]?) -> Void)] = []
        /// 4×2 frames, aspect 2 (tiles 132px wide at the 66px strip height).
        static func strip(_ n: Int) -> TimelineThumbnailStrip {
            TimelineThumbnailStrip(frames: (0..<n).map { i in CanvasImage(width: 4, height: 2, rgba: [UInt8](repeating: UInt8(i * 40), count: 32)) }, aspect: 2)
        }
        func answerAll() {
            let f = pendingFrames, p = pendingPeaks
            pendingFrames = []; pendingPeaks = []
            for (r, done) in f { done(Self.strip(r.frameCount)) }
            for (_, done) in p { done([0.2, 0.8, 0.5]) }
        }
    }

    func make() throws -> (TimelineRegion, TimelineController, TimelineMediaFeeder, FakeLoaders, () -> Int) {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON, engine: KeyframeRuntime())
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        let region = TimelineRegion(controller: c)
        region.resized(Self.size)
        let fake = FakeLoaders()
        let feeder = TimelineMediaFeeder(view: c.view, loadFrames: { r, done in
            fake.frameRequests.append(r); fake.pendingFrames.append((r, done))
        }, loadPeaks: { id, done in
            fake.peakRequests.append(id); fake.pendingPeaks.append((id, done))
        })
        var redraws = 0
        feeder.needsDisplay = { redraws += 1 }
        region.media = feeder
        return (region, c, feeder, fake, { redraws })
    }

    func paint(_ region: TimelineRegion) -> RecordingCanvas {
        let canvas = RecordingCanvas(); region.draw(canvas, size: Self.size); return canvas
    }

    func testFramesAndPeaksAreRequestedCachedAndDrawn() throws {
        let (region, c, feeder, fake, redraws) = try make()
        XCTAssertTrue(c.view.thumbnailsEnabled, "adaptive by default")
        var canvas = paint(region)
        XCTAssertEqual(Set(fake.frameRequests.map(\.assetId)), ["asset:a", "asset:b", "asset:logo"], "video and image clips ask for strips")
        XCTAssertTrue(fake.frameRequests.allSatisfy { $0.frameCount == 1 }, "one frame first, before the aspect is known")
        XCTAssertEqual(fake.peakRequests, ["asset:music"], "audio clips ask for peaks")
        XCTAssertTrue(canvas.images.isEmpty, "nothing to draw until an answer lands")

        // A second paint while loading asks for nothing new.
        _ = paint(region)
        XCTAssertEqual(fake.frameRequests.count, 3); XCTAssertEqual(fake.peakRequests.count, 1)

        fake.answerAll()
        XCTAssertEqual(redraws(), 4, "each answer asks for a redraw")
        XCTAssertEqual(c.view.waveforms["asset:music"], [0.2, 0.8, 0.5])
        XCTAssertNotNil(c.view.thumbnails["asset:a"])

        // With the aspect known, wide clips ask for a richer strip (tiles across the clip, at most 6) at this zoom.
        canvas = paint(region)
        XCTAssertFalse(canvas.images.isEmpty, "filmstrip frames are drawn")
        let wantA = feeder.wantedFrames(asset: "asset:a", kind: .video, width: 6 * c.view.pixelsPerSecond)
        XCTAssertEqual(fake.frameRequests.last { $0.assetId == "asset:a" }?.frameCount, wantA)
        XCTAssertEqual(fake.frameRequests.first { $0.assetId == "asset:logo" && $0.frameCount > 1 }, nil, "a still repeats one frame")

        // Zooming in changes the strip size; the cache keeps each size per asset.
        fake.answerAll()
        c.setZoom(percent: 800)
        _ = paint(region)
        XCTAssertEqual(fake.frameRequests.last { $0.assetId == "asset:a" }?.frameCount, 6)
        fake.answerAll()
        let requests = fake.frameRequests.count
        c.setZoom(percent: 100); _ = paint(region); c.setZoom(percent: 800); _ = paint(region)
        XCTAssertEqual(fake.frameRequests.count, requests, "cached per asset and strip size: no new requests")
        XCTAssertEqual(c.view.thumbnails["asset:a"]?.frames.count, 6)
    }

    func testShowThumbnailsToggleHidesAndRestoresFilmstrips() throws {
        let (region, c, _, fake, _) = try make()
        let store = MemoryTimelineUIPreferencesStore()
        _ = paint(region); fake.answerAll()
        let videoFrames = { (canvas: RecordingCanvas) in canvas.images.filter { $0.image.width == 4 }.count }
        XCTAssertGreaterThan(videoFrames(paint(region)), 0)

        // Clip menu → "Show thumbnails" (unchecks: thumbnailMode hidden).
        XCTAssertTrue(c.runClipMenu(.thumbnails, clipId: "clip:a"))
        XCTAssertFalse(c.view.thumbnailsEnabled)
        let before = fake.frameRequests.count
        XCTAssertEqual(videoFrames(paint(region)), 0, "hidden: no filmstrips drawn")
        XCTAssertEqual(fake.frameRequests.count, before, "hidden: nothing requested")

        // Back on: frames are requested again where missing and drawn.
        XCTAssertTrue(c.runClipMenu(.thumbnails, clipId: "clip:a"))
        _ = paint(region); fake.answerAll()
        XCTAssertGreaterThan(videoFrames(paint(region)), 0, "adaptive: filmstrips drawn again")

        // The mode persists with the other timeline preferences.
        let r2 = TimelineRegion(controller: c, preferences: store)
        c.setThumbnailsEnabled(false)
        XCTAssertEqual(store.prefs.thumbnailMode, "hidden"); _ = r2
    }

    func testFailedLoadsAreNotRetriedEveryPaint() throws {
        let (region, _, feeder, fake, _) = try make()
        _ = paint(region)
        for (_, done) in fake.pendingFrames { done(nil) }
        for (_, done) in fake.pendingPeaks { done(nil) }
        fake.pendingFrames = []; fake.pendingPeaks = []
        let n = fake.frameRequests.count, m = fake.peakRequests.count
        _ = paint(region)
        XCTAssertEqual(fake.frameRequests.count, n); XCTAssertEqual(fake.peakRequests.count, m)
        feeder.invalidate(assets: ["asset:a"])
        _ = paint(region)
        XCTAssertEqual(fake.frameRequests.count, n + 1, "invalidated assets load again")
    }
}
