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
import MpvfxColor
import MpvfxTimeline
@testable import MpvfxPanels

/// The preview's memory stays bounded through a long editing session: the raw frame cache never exceeds its byte
/// budget and evicts least recently used frames, memory pressure takes memory back, a removed clip's frames, graded
/// picture and decoder are released, and a long play / scrub / grade / reverse / replay loop does not grow the
/// process beyond what the caches are allowed to hold.
final class PreviewMemoryTests: XCTestCase {
    static let packageRoot = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func image(_ w: Int, _ h: Int, _ v: UInt8) -> CanvasImage {
        CanvasImage(width: w, height: h, rgba: [UInt8](repeating: v, count: w * h * 4))
    }

    // MARK: Frame cache (no decoding)

    func testFrameCacheNeverExceedsItsBudgetAndEvictsLeastRecentlyUsed() {
        let frameBytes = 64 * 36 * 4
        let cache = PreviewFrameCache(budgetBytes: frameBytes * 10, pressure: nil)
        for f in 0..<500 {
            cache.store(Self.image(64, 36, UInt8(f % 251)), lane: f % 2 == 0 ? "a" : "b", frame: f)
            if f == 3 { XCTAssertNotNil(cache.frame(lane: "b", frame: 3)) }
            // Keep frame 0 hot: it is used again and again, so it is never the least recently used.
            _ = cache.frame(lane: "a", frame: 0)
            XCTAssertLessThanOrEqual(cache.bytes, cache.budgetBytes, "over budget after frame \(f)")
        }
        XCTAssertLessThanOrEqual(cache.peakBytes, cache.budgetBytes)
        XCTAssertLessThanOrEqual(cache.count, 10)
        XCTAssertNotNil(cache.frame(lane: "a", frame: 0), "a frame in use survives")
        XCTAssertNotNil(cache.frame(lane: "b", frame: 499), "the newest frame is kept")
        XCTAssertNil(cache.frame(lane: "b", frame: 3), "an old frame nobody looked at again is gone")
        cache.removeLane("a")
        XCTAssertTrue(cache.cachedFrames(lane: "a", from: 0, to: 1000).isEmpty)
        XCTAssertEqual(cache.laneKeys, ["b"])
    }

    /// A frame being decoded is counted before it exists: reserving its bytes evicts to make room, storing it moves
    /// the bytes from in flight to cached without evicting again, and a dropped frame gives its reservation back.
    func testFramesInFlightCountAgainstTheBudget() {
        let frameBytes = 64 * 36 * 4
        let cache = PreviewFrameCache(budgetBytes: frameBytes * 10, pressure: nil)
        for f in 0..<10 { cache.store(Self.image(64, 36, 1), lane: "a", frame: f) }
        XCTAssertEqual(cache.bytes, cache.budgetBytes, "full")
        let first = cache.reserve(frameBytes, lane: "b"), second = cache.reserve(frameBytes, lane: "c")
        XCTAssertEqual(cache.inFlightBytes, 2 * frameBytes)
        XCTAssertLessThanOrEqual(cache.bytes + cache.inFlightBytes, cache.budgetBytes,
                                 "room is made before the frames exist")
        XCTAssertFalse(cache.contains(lane: "a", frame: 0), "the least recently used frames made the room")
        XCTAssertFalse(cache.contains(lane: "a", frame: 1))
        XCTAssertTrue(cache.contains(lane: "a", frame: 9), "the newest frame stays")
        let countBefore = cache.count
        cache.store(Self.image(64, 36, 2), lane: "b", frame: 0, reserved: first)
        XCTAssertEqual(cache.count, countBefore + 1, "a reserved frame lands without evicting another")
        cache.release(second)
        XCTAssertEqual(cache.inFlightBytes, 0, "a dropped frame gives its reservation back")
        XCTAssertLessThanOrEqual(cache.peakHeldBytes, cache.budgetBytes, "cached plus in flight never above the budget")
        XCTAssertEqual(cache.peakInFlightBytes, 2 * frameBytes)
    }

    /// Many lanes reserving at once (Codex review of #132): a reservation that would take the frames in flight past
    /// the budget waits for another to settle, so cached plus in flight stays within the budget for any number of
    /// lanes, down to a budget of one frame.
    func testConcurrentReservationsKeepCachedPlusInFlightWithinTheBudget() {
        let frameBytes = 64 * 36 * 4
        for frames in [1, 3] {
            let cache = PreviewFrameCache(budgetBytes: frameBytes * frames, pressure: nil)
            DispatchQueue.concurrentPerform(iterations: 6) { lane in
                for frame in 0..<20 {
                    let reserved = cache.reserve(frameBytes, lane: "lane\(lane)")
                    if frame % 5 == 2 { cache.release(reserved); continue }   // some decodes are dropped
                    cache.store(Self.image(64, 36, UInt8(lane)), lane: "lane\(lane)", frame: frame, reserved: reserved)
                }
            }
            XCTAssertLessThanOrEqual(cache.peakHeldBytes, cache.budgetBytes, "budget of \(frames) frames")
            XCTAssertLessThanOrEqual(cache.peakInFlightBytes, cache.budgetBytes)
            XCTAssertEqual(cache.inFlightBytes, 0, "every reservation settled")
            XCTAssertGreaterThan(cache.count, 0, "the last decode of every lane is stored")
        }
    }

    /// A reservation keeps the reserving lane's most recent frame while it fits beside the frames in flight: it is
    /// what the layer shows when the decode fails (end of the media). Another lane's frames go first.
    func testAReservationKeepsItsLanesLastFrameWhenItFits() {
        let frameBytes = 64 * 36 * 4
        let cache = PreviewFrameCache(budgetBytes: frameBytes * 4, pressure: nil)
        cache.store(Self.image(64, 36, 1), lane: "a", frame: 0)
        for f in 0..<3 { cache.store(Self.image(64, 36, 2), lane: "b", frame: f) }
        let reserved = cache.reserve(frameBytes, lane: "a")
        XCTAssertTrue(cache.contains(lane: "a", frame: 0), "the lane's fallback frame stays, though the oldest")
        XCTAssertFalse(cache.contains(lane: "b", frame: 0), "the oldest frame of another lane made the room")
        cache.release(reserved)
        // One frame of budget: the fallback cannot fit beside the frame in flight, and the bound wins.
        let tiny = PreviewFrameCache(budgetBytes: frameBytes, pressure: nil)
        tiny.store(Self.image(64, 36, 1), lane: "a", frame: 0)
        tiny.release(tiny.reserve(frameBytes, lane: "a"))
        XCTAssertLessThanOrEqual(tiny.peakHeldBytes, tiny.budgetBytes)
    }

    /// A memory warning halves the budget for what is held, frames in flight included.
    func testAMemoryWarningCountsFramesInFlight() {
        let frameBytes = 64 * 36 * 4
        let cache = PreviewFrameCache(budgetBytes: frameBytes * 10, pressure: nil)
        for f in 0..<4 { cache.store(Self.image(64, 36, 1), lane: "a", frame: f) }
        let reserved = cache.reserve(frameBytes * 4, lane: "b")
        cache.purge(.warning)
        XCTAssertLessThanOrEqual(cache.bytes + cache.inFlightBytes, cache.budgetBytes / 2)
        cache.release(reserved)
    }

    func testMemoryPressureEmptiesTheFrameCacheAndAReleasedCacheStopsObserving() {
        let monitor = MemoryPressureMonitor()
        var cache: PreviewFrameCache? = PreviewFrameCache(budgetBytes: 100 * 64 * 36 * 4, pressure: monitor)
        for f in 0..<100 { cache!.store(Self.image(64, 36, 1), lane: "a", frame: f) }
        XCTAssertGreaterThan(cache!.bytes, cache!.budgetBytes / 2)
        monitor.simulate(.warning)
        XCTAssertLessThanOrEqual(cache!.bytes, cache!.budgetBytes / 2, "a warning halves what is held")
        XCTAssertNotNil(cache!.frame(lane: "a", frame: 99), "the most recent frames stay")
        monitor.simulate(.critical)
        XCTAssertEqual(cache!.bytes, 0); XCTAssertEqual(cache!.count, 0)
        weak let gone = cache
        XCTAssertEqual(monitor.observerCount, 1)
        cache = nil
        XCTAssertNil(gone, "the pressure observer does not retain the cache")
        XCTAssertEqual(monitor.observerCount, 0)
    }

    func testGraderKeepsItsPicturesWithinBudgetAndDropsRemovedClips() throws {
        let monitor = MemoryPressureMonitor()
        let grader = PreviewGrader(renderer: CPUColorRenderer(), pressure: monitor)
        let frame = 64 * 36 * 4
        grader.budgetBytes = frame * 3
        guard case .object(let o) = try NativeJSONValue.parse(#"{"adjust":{"exposure":0.4}}"#), let params = ColorGradeParams(json: o)
        else { return XCTFail("grade json") }
        let grade = ColorGradeRenderer(params: params, seedKey: "clip:x")
        for i in 0..<10 {
            grader.request("clip\(i)", PreviewGrader.Request(key: "k\(i)", sourceKey: "s\(i)", image: Self.image(64, 36, 100), target: nil,
                                                             grade: grade, time: 0))
            grader.waitUntilIdle()
            XCTAssertLessThanOrEqual(grader.bytes, grader.budgetBytes, "after clip \(i)")
        }
        XCTAssertNotNil(grader.latest("clip9"), "the newest look is kept")
        XCTAssertNil(grader.latest("clip0"), "the least recently used look is dropped")
        grader.keepOnly(["clip9"])
        XCTAssertEqual(grader.bytes, frame)
        monitor.simulate(.critical)
        XCTAssertEqual(grader.bytes, 0, "critical pressure drops idle pictures")
    }

    /// Playing a graded clip on the CPU renderer: each new frame is graded once at full size. A draft first is for an
    /// edit of the grade on the same picture; drafting every new frame doubled the grading work of playback.
    func testCPUGraderDraftsEditsButNotNewFrames() throws {
        let grader = PreviewGrader(renderer: CPUColorRenderer(), pressure: nil)
        grader.draftSize = PreviewDecodeSize(width: 32, height: 18)
        func grade(_ exposure: Double) throws -> ColorGradeRenderer {
            guard case .object(let o) = try NativeJSONValue.parse(#"{"adjust":{"exposure":\#(exposure)}}"#), let params = ColorGradeParams(json: o)
            else { throw CocoaError(.coderInvalidValue) }
            return ColorGradeRenderer(params: params, seedKey: "clip:x")
        }
        func ask(_ frame: Int, _ g: ColorGradeRenderer) {
            grader.request("clip", PreviewGrader.Request(key: "f\(frame)|\(g.signature)", sourceKey: "f\(frame)", image: Self.image(64, 36, 100),
                                                         target: nil, grade: g, time: 0))
            grader.waitUntilIdle()
        }
        let g1 = try grade(0.4), g2 = try grade(0.8)
        ask(0, g1)
        let first = grader.drafts
        ask(1, g1); ask(2, g1); ask(3, g1)
        XCTAssertEqual(grader.drafts, first, "new frames with the same grade: no drafts")
        XCTAssertEqual(grader.latest("clip")?.key, "f3|\(g1.signature)", "each graded at full size")
        ask(3, g2)
        XCTAssertEqual(grader.drafts, first + 1, "a grade edit on the same frame is drafted first")
    }

    func testDefaultBudgetsComeFromPhysicalMemory() {
        let cx = PreviewCompositor(decodesMedia: false)
        XCTAssertEqual(cx.cache.budgetBytes, MemoryBudget.previewFrames())
        XCTAssertLessThanOrEqual(cx.cache.budgetBytes, 2 << 30)
        XCTAssertEqual(cx.gradedMemoBudget, MemoryBudget.gradedFrames())
        XCTAssertEqual(cx.cache.budgetBytes + cx.gradedMemoBudget, MemoryBudget.previewTotal(),
                       "what the preview benchmark sums")
    }

    // MARK: With decoded media

    var dir: URL!

    func makeMedia(seconds: Int = 6, width: Int = 160, height: Int = 90) throws {
        dir = try TestMedia.scratch("memory")
        _ = try TestMedia.PatternVideo(width: width, height: height, seconds: Double(seconds)).write(to: dir.appendingPathComponent("media.mov").path)
    }
    override func tearDown() { if let dir { try? FileManager.default.removeItem(at: dir) } }

    /// Two clips on two tracks (b over a), 180 frames each.
    func editor(clips: [String] = ["clip:a", "clip:b"],
                canvas: (width: Int, height: Int) = (160, 90)) throws -> TimelineEditor {
        let tracks = clips.enumerated().map { i, id in
            """
            {"id":"track:v\(i)","kind":"video","lane":{"authoredTrack":\(i + 1),"displayTrack":\(i)},"clips":[
             {"id":"\(id)","assetId":"asset:a","startFrame":0,"durationFrames":180,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[],
              "staticParameters":{"transform.opacity":0.6}}]}
            """
        }.joined(separator: ",")
        return try TimelineEditor(json: """
        {"schemaVersion":1,"id":"project:m","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":\(canvas.width),"height":\(canvas.height),"background":"#000000"},
         "assets":[{"id":"asset:a","kind":"video","name":"media.mov","source":"media.mov","durationFrames":180}],
         "sequence":{"id":"sequence:main","name":"Main","tracks":[\(tracks)]}}
        """)
    }

    /// An offscreen target to draw the preview into (kept alive by the second value).
    func canvas(width: Int = 160, height: Int = 90) throws -> (CanvasContext, AnyObject) {
        #if os(Linux)
        let t = CairoImageTarget(width: width, height: height); return (t.canvas, t)
        #elseif canImport(CoreGraphics) && canImport(CoreText)
        let c = try XCTUnwrap(CoreGraphicsCanvas.offscreen(width: width, height: height)); return (c, c)
        #else
        throw XCTSkip("no offscreen canvas on this platform")
        #endif
    }

    /// Draws at `t`, lets the decoders and the grader catch up, draws again (what the app's redraw after `frameReady` does).
    /// The view is the project's canvas size, so frames decode at canvas pixels.
    func draw(_ cx: PreviewCompositor, _ c: CanvasContext, _ t: Double, playing: Bool, speed: Double = 1) {
        let size = cx.composition?.canvas
        let rect = CanvasRect(x: 0, y: 0, width: size?.width ?? 160, height: size?.height ?? 90)
        cx.draw(c, in: rect, time: t, elements: [], context: FrameDrawContext(isPlaying: playing, speed: speed))
        for l in cx.lanes.values { l.wait() }
        cx.draw(c, in: rect, time: t, elements: [], context: FrameDrawContext(isPlaying: playing, speed: speed))
        cx.grader.waitUntilIdle()   // grades run off the main thread; the redraw after onFinished shows them
        cx.draw(c, in: rect, time: t, elements: [], context: FrameDrawContext(isPlaying: playing, speed: speed))
    }

    func testRemovingAClipReleasesItsFramesGradedPictureAndDecoder() throws {
        try makeMedia()
        let ed = try editor()
        var g = ColorGrading(); g.adjust["exposure"] = 0.3
        XCTAssertTrue(ed.setColorGrading(clipId: "clip:b", g))
        let cx = PreviewCompositor(cacheBudgetBytes: 32 << 20)
        defer { cx.stopAll() }
        cx.composition = PreviewComposition(document: ed.document, projectDir: dir, engine: nil)
        let (c, keep) = try canvas(); _ = keep
        for f in 0..<20 { draw(cx, c, Double(f) / 30, playing: true) }
        let laneB = try XCTUnwrap(cx.lanes.first { $0.value.layer.clipId == "clip:b" }?.key)
        weak let decoderB = cx.lanes[laneB]
        XCTAssertNotNil(decoderB)
        XCTAssertTrue(cx.cache.laneKeys.contains(laneB))
        XCTAssertGreaterThan(cx.gradedMemoBytes, 0)

        // Delete clip b: the next composition drops its frames and graded picture; the next draw ends its decoder.
        cx.composition = PreviewComposition(document: try editor(clips: ["clip:a"]).document, projectDir: dir, engine: nil)
        XCTAssertFalse(cx.cache.laneKeys.contains(laneB), "a removed clip's frames are freed")
        XCTAssertEqual(cx.gradedMemoBytes, 0, "and its graded picture")
        draw(cx, c, 0.7, playing: false)
        XCTAssertNil(cx.lanes[laneB])
        // The lane's queue may still be closing its stream; give it a moment, then it must be gone.
        for _ in 0..<50 where decoderB != nil { usleep(20_000) }
        XCTAssertNil(decoderB, "the removed clip's decoder is released, not kept alive by a closure")

        cx.releaseAll()
        XCTAssertEqual(cx.cache.bytes, 0, "closing the project frees every frame")
        XCTAssertTrue(cx.lanes.isEmpty)
    }

    /// A long simulated session: play, scrub, grade edits, reverse and replay, many times over two layers. The cache
    /// stays within its budget at every draw, decoders do not pile up, and the process footprint after the first
    /// round grows by no more than what the budgeted caches added (plus slack for allocator noise).
    func testLongEditingSessionStaysWithinBudget() throws {
        try makeMedia()
        let ed = try editor()
        let budget = 6 << 20   // ~110 frames of 160x90: far fewer than the session decodes, so eviction runs throughout
        let cx = PreviewCompositor(cacheBudgetBytes: budget)
        defer { cx.stopAll() }
        cx.composition = PreviewComposition(document: ed.document, projectDir: dir, engine: nil)
        let (c, keep) = try canvas(); _ = keep
        var samples: [(footprint: Int, cached: Int)] = []
        weak var firstRoundDecoder: PreviewDecodeLane?
        for round in 0..<4 {
            // Play two seconds forward (every other frame, like a busy display).
            for f in stride(from: 0, to: 60, by: 2) { draw(cx, c, Double(f) / 30, playing: true) }
            // Scrub.
            for i in 0..<16 { draw(cx, c, Double((i * 37 + round * 13) % 180) / 30, playing: false) }
            // Grade both clips (a new look each round), and every other round trim clip a so it gets a new lane.
            for id in ["clip:a", "clip:b"] {
                var g = ed.colorGrading(clipId: id) ?? ColorGrading()
                g.adjust["exposure"] = 0.1 * Double(round + 1)
                XCTAssertTrue(ed.setColorGrading(clipId: id, g))
            }
            if round == 0 { firstRoundDecoder = cx.lanes.values.first { $0.layer.clipId == "clip:a" } }
            if round % 2 == 1 { XCTAssertTrue(ed.editClip("clip:a") { $0.sourceInFrame = Double(round); $0.durationFrames = 170; return true }) }
            cx.composition = PreviewComposition(document: ed.document, projectDir: dir, engine: nil)
            for f in stride(from: 90, to: 60, by: -3) { draw(cx, c, Double(f) / 30, playing: true, speed: -1) }
            XCTAssertLessThanOrEqual(cx.cache.bytes, budget, "round \(round)")
            XCTAssertLessThanOrEqual(cx.lanes.count, 4, "decoders: at most the visible clips and their pre-roll")
            samples.append((ResidentMemory.footprintBytes() ?? 0, cx.cache.bytes + cx.gradedMemoBytes))
            print("MEMSTRESS round \(round) footprint=\(samples.last!.footprint >> 20)MB caches=\(samples.last!.cached >> 20)MB frames=\(cx.cache.count) peak=\(cx.cache.peakBytes >> 20)MB budget=\(budget >> 20)MB lanes=\(cx.lanes.count)")
        }
        XCTAssertLessThanOrEqual(cx.cache.peakBytes, budget, "never over budget")
        XCTAssertGreaterThan(cx.cache.count, 20, "caching stays effective within the budget")
        for _ in 0..<50 where firstRoundDecoder != nil { usleep(20_000) }
        XCTAssertNil(firstRoundDecoder, "the decoder of a lane replaced by a trim is released")
        if let first = samples.first?.footprint, first > 0, let last = samples.last {
            let unaccounted = (last.footprint - first) - (last.cached - samples[0].cached)
            print("MEMSTRESS unaccounted growth after round 1: \(unaccounted >> 20)MB")
            XCTAssertLessThan(unaccounted, 48 << 20, "the process grows only by what the caches may hold")
        }
    }

    /// Two stacked clips decoded at 1080p (a 1920x1080 project drawn at 1920x1080, so each lane decodes 1920x1080
    /// RGBA frames of about 8 MB from the small test clip) played forward with a budget of 8 such frames: decoding
    /// runs far past the budget, both lanes decode at once, and the cached frames plus the frames the lanes are
    /// decoding never exceed the budget (issue #97).
    func testTwoStacked1080pLanesKeepCachedPlusInFlightFramesWithinTheBudget() throws {
        try makeMedia(seconds: 2)
        let ed = try editor(canvas: (1920, 1080))
        let frameBytes = 1920 * 1080 * 4
        let budget = 8 * frameBytes
        let cx = PreviewCompositor(cacheBudgetBytes: budget)
        defer { cx.stopAll() }
        cx.composition = PreviewComposition(document: ed.document, projectDir: dir, engine: nil)
        let (c, keep) = try canvas(width: 1920, height: 1080); _ = keep
        // The peaks are taken under the cache's lock at every reservation and store; reading bytes and in-flight
        // bytes here one after the other would race the lanes.
        for f in 0..<30 { draw(cx, c, Double(f) / 30, playing: true) }
        XCTAssertEqual(Set(cx.lanes.values.map(\.layer.clipId)), ["clip:a", "clip:b"], "two lanes")
        let decoded = cx.lanes.values.reduce(0) { $0 + $1.framesDecoded }
        XCTAssertGreaterThan(decoded, 16, "decoding ran well past what the budget holds, so eviction ran")
        let sizes = Set(cx.lanes.values.compactMap { lane in
            cx.cache.nearest(lane: lane.key, to: 29).map { "\($0.image.width)x\($0.image.height)" }
        })
        XCTAssertEqual(sizes, ["1920x1080"], "frames are decoded at 1080p")
        XCTAssertGreaterThanOrEqual(cx.cache.peakInFlightBytes, frameBytes,
                                    "frames were counted while they were decoded")
        XCTAssertLessThanOrEqual(cx.cache.peakHeldBytes, budget, "cached plus in flight never above the budget")
        XCTAssertLessThanOrEqual(cx.cache.peakBytes, budget)
        for l in cx.lanes.values { l.wait() }
        XCTAssertEqual(cx.cache.inFlightBytes, 0, "every reservation was stored or given back")
    }

    /// The decoder's read path: 600 frames of 640x360 (about 550 MB of pixels across the C boundary) read in one loop
    /// without any autorelease pool of our own must not grow the process.
    func testReadingManyFramesInOneLoopKeepsTheFootprintFlat() throws {
        try makeMedia(seconds: 20, width: 640, height: 360)
        let s = try MediaFrameStream(source: dir.appendingPathComponent("media.mov").path,
                                     frames: .init(from: 0, fps: 30, width: 640, height: 360))
        var warm = 0, n = 0
        while let img = s.next() {
            XCTAssertEqual(img.rgba.count, 640 * 360 * 4)
            n += 1
            if n == 30 { warm = ResidentMemory.footprintBytes() ?? 0 }
        }
        XCTAssertEqual(n, 600)
        let end = ResidentMemory.footprintBytes() ?? 0
        print("MEMSTRESS frame read loop: 600 frames, footprint after 30 \(warm >> 20)MB, after 600 \(end >> 20)MB")
        if warm > 0 { XCTAssertLessThan(end - warm, 64 << 20, "reading frames does not accumulate memory") }
    }
}
