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
// Export paints frame N+1 while frame N encodes (issue #98): the file is byte-identical to the one-thread loop's,
// painting runs at most one frame ahead through a queue of 2 frames, cancel stops within one frame, progress rises
// monotonically, and a failure on either side ends the render with that failure (no hang, no file).
import Foundation
import XCTest
import OneTakeMedia
import MpvfxPlayer
@testable import MpvfxShared
@testable import MpvfxRuntime
import OneTakeKeyframes

/// Wraps the app's painter: `before(i)` runs before frame `i` is painted (it may throw).
private final class HookedFrames: NativeExportFrameRenderer {
    let inner: NativeExportFrameRenderer
    let before: (Int) throws -> Void
    private var index = 0
    init(_ inner: NativeExportFrameRenderer, before: @escaping (Int) throws -> Void) { self.inner = inner; self.before = before }
    func frame(at time: Double) throws -> [UInt8] {
        defer { index += 1 }
        try before(index)
        return try inner.frame(at: time)
    }
}

private struct PaintFailure: Error, Equatable {}
private struct EncodeFailure: Error, Equatable {}

final class ExportOverlapTests: XCTestCase {
    static var root = ""
    override class func setUp() {
        super.setUp()
        guard let dir = try? makeMediaTempDir("export-overlap-") else { return }
        root = dir
    }
    override class func tearDown() { if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }; super.tearDown() }
    var engine: KeyframeRuntime!
    var root: String { Self.root }

    override func setUpWithError() throws {
        try XCTSkipIf(Self.root.isEmpty)
        engine = try KeyframeRuntime(); installKeyframeEngine(engine)
        installAppExportFrames()
        guard !FileManager.default.fileExists(atPath: "\(root)/moving.mov") else { return }
        // Every frame differs (a moving bar over a ramp), with a tone, so a reordered or dropped frame changes the file.
        var video = TestVideo(width: 64, height: 32, fps: 10, seconds: 4, tone: 440)
        video.pixels = { t in
            let bar = Int(t * 10) % 64
            return Array((0..<(64 * 32)).map { i -> [UInt8] in
                let x = i % 64
                return x == bar ? [255, 255, 255, 255] : [UInt8(x * 4), UInt8(i / 64 * 8), 80, 255]
            }.joined())
        }
        try TestMedia.write(video, to: "\(root)/moving.mov")
    }

    /// 4 s at 10 fps of the moving clip, fading in, its sound ramping up.
    func project(frames: Int = 40) throws -> NativeProjectDocument {
        func track(_ id: String, _ keys: String) -> String {
            #"{"schemaVersion":1,"id":"t:\#(id)","parameterId":"\#(id)","valueType":"number","frameRate":{"numerator":10,"denominator":1},"keyframes":\#(keys)}"#
        }
        let ramp = #"[{"id":"k0","frame":0,"value":0.2,"outgoing":{"type":"linear"}},{"id":"k1","frame":30,"value":1,"outgoing":{"type":"linear"}}]"#
        return try parseNativeProjectDocument(try NativeJSONValue.parse(#"""
        {"schemaVersion":1,"mediaEngine":"native","id":"overlap","revision":0,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":64,"height":32,"background":"#102030"},
         "assets":[{"id":"m","kind":"video","name":"moving","source":"moving.mov","durationFrames":40}],
         "sequence":{"id":"sequence","name":"Sequence","durationFrames":\#(frames),"tracks":[{"id":"video","kind":"video","clips":[
           {"id":"m","assetId":"m","startFrame":0,"durationFrames":40,"sourceInFrame":0,"muted":false,"effects":[],
            "parameterTracks":[\#(track("transform.opacity", ramp)),\#(track("audio.volume", ramp))]}]}]}}
        """#))
    }

    func input(_ name: String, _ document: NativeProjectDocument, format: ExportFormat) -> NativeTimelineRenderInput {
        let output = "\(root)/\(name)"
        try? FileManager.default.removeItem(atPath: output)
        return NativeTimelineRenderInput(project: document, projectDir: root, outputPath: output, format: format,
                                         quality: .high, keyframeEngine: engine)
    }

    func hooked(_ input: inout NativeTimelineRenderInput, _ before: @escaping (Int) throws -> Void) {
        input.frameRenderer = { request in HookedFrames(try PreviewExportFrames(request), before: before) }
    }

    func sha(_ path: String) throws -> String { sha256Hex(try Data(contentsOf: URL(fileURLWithPath: path))) }

    // MARK: the output is the one-thread loop's

    func testTheOverlappedExportIsByteIdenticalToTheOneThreadLoop() throws {
        for format in [ExportFormat.mp4, .mov] {
            var serial = input("serial.\(format.rawValue)", try project(), format: format)
            serial.encodeAhead = false
            try renderNativeTimeline(serial)
            let overlapped = input("overlapped.\(format.rawValue)", try project(), format: format)
            XCTAssertTrue(overlapped.encodeAhead, "overlap is the default")
            try renderNativeTimeline(overlapped)
            XCTAssertEqual(try sha(overlapped.outputPath), try sha(serial.outputPath), "\(format): encoded stream differs")
            let probe = try MediaProbe.probe(path: overlapped.outputPath)
            XCTAssertEqual(probe.video?.frames, 40); XCTAssertNotNil(probe.audio)
        }
    }

    // MARK: painting runs one frame ahead through a queue of 2 frames

    func testPaintingRunsAtMostOneFrameAheadOfEncoding() throws {
        var overlapped = input("ahead.mp4", try project(), format: .mp4)
        let times = NativeExportStageTimes()
        overlapped.stageTimes = times
        var ahead: [Int] = []
        // Before frame i is painted, frames 0..<i-1 are encoded: frame i-1 may still be encoding, nothing older.
        hooked(&overlapped) { i in ahead.append(i - times.framesEncoded) }
        try renderNativeTimeline(overlapped)
        XCTAssertEqual(ahead.count, 40)
        // Frame 0 is encoded before frame 1 paints: the decoder's and the encoder's start-up memory never overlap.
        XCTAssertEqual(Array(ahead.prefix(2)), [0, 0], "\(ahead)")
        XCTAssertLessThanOrEqual(ahead.max() ?? 99, EXPORT_ENCODE_QUEUE_FRAMES - 1, "\(ahead)")
        XCTAssertEqual(EXPORT_ENCODE_QUEUE_FRAMES, 2)
        XCTAssertEqual(times.framesPainted, 40); XCTAssertEqual(times.framesEncoded, 40)
    }

    func testThePipelineHoldsAtMostDepthFramesAndKeepsTheirOrder() throws {
        let lock = NSLock()
        var encoded: [Int] = [], returned = 0, aheadAtEncode: [Int] = []
        let pipeline = ExportEncodePipeline(depth: 2, cancellation: nil) { frame in
            lock.lock(); defer { lock.unlock() }
            // submit(k + 1) cannot return before frame k is encoded: the painter is at most one frame ahead.
            aheadAtEncode.append(returned - frame.index)
            encoded.append(frame.index)
        }
        for i in 0..<50 {
            try pipeline.submit(ExportPaintedFrame(index: i, rgba: [UInt8(i)], sound: nil))
            lock.lock(); returned += 1; lock.unlock()
        }
        try pipeline.finish()
        XCTAssertEqual(encoded, Array(0..<50))
        XCTAssertLessThanOrEqual(aheadAtEncode.max() ?? 99, 1, "\(aheadAtEncode)")
        XCTAssertLessThanOrEqual(pipeline.mostOutstanding, 2)
    }

    #if os(Linux)
    /// The encoder thread runs at a lower priority (nice 10); the painter's thread, the caller's, keeps its own.
    func testTheEncoderRunsAtALowerPriorityThanThePainter() throws {
        let which = __priority_which_t(PRIO_PROCESS.rawValue)
        let painter = getpriority(which, 0)
        var encoder: Int32 = -99
        let pipeline = ExportEncodePipeline(depth: 2, cancellation: nil) { _ in encoder = getpriority(which, 0) }
        try pipeline.submit(ExportPaintedFrame(index: 0, rgba: [], sound: nil))
        try pipeline.finish()
        XCTAssertEqual(encoder, Swift.max(painter, EXPORT_ENCODER_NICE))
        XCTAssertEqual(getpriority(which, 0), painter, "only the encoder's thread is lowered")
    }
    #endif

    // MARK: cancel, progress, failures

    func testCancelStopsWithinOneFrame() throws {
        let cancellation = MediaCancellation()
        var overlapped = input("cancel.mp4", try project(frames: 400), format: .mp4)
        overlapped.cancellation = cancellation
        let times = NativeExportStageTimes()
        overlapped.stageTimes = times
        hooked(&overlapped) { i in if i == 10 { cancellation.cancel() } }
        XCTAssertThrowsError(try renderNativeTimeline(overlapped)) { error in
            XCTAssertTrue(cancellation.isCancelled, "\(error)")
        }
        // Cancelled while painting frame 10: that frame is the last painted, and it is never encoded (the encoder
        // checks the cancellation before every frame).
        XCTAssertEqual(times.framesPainted, 11)
        XCTAssertLessThanOrEqual(times.framesEncoded, 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: overlapped.outputPath))
        XCTAssertEqual(try leftovers(root), [])
    }

    func testProgressRisesMonotonicallyToTheEnd() throws {
        let lock = NSLock()
        var seen: [Double] = []
        var overlapped = input("progress.mp4", try project(), format: .mp4)
        overlapped.onProgress = { p in lock.lock(); seen.append(p); lock.unlock() }
        try renderNativeTimeline(overlapped)
        lock.lock(); let progress = seen; lock.unlock()
        XCTAssertEqual(progress, progress.sorted())
        XCTAssertEqual(progress.last, 100)
        XCTAssertGreaterThanOrEqual(progress.filter { $0 > 10 && $0 < 100 }.count, 40, "one step per encoded frame")
    }

    func testAPaintingFailureEndsTheRenderWithThatFailure() throws {
        var overlapped = input("paint-fails.mp4", try project(), format: .mp4)
        hooked(&overlapped) { i in if i == 7 { throw PaintFailure() } }
        XCTAssertThrowsError(try renderNativeTimeline(overlapped)) { XCTAssertEqual($0 as? PaintFailure, PaintFailure()) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: overlapped.outputPath))
        XCTAssertEqual(try leftovers(root), [])
    }

    func testAnEncodingFailureReachesThePainterAndStopsIt() throws {
        var submitted = 0
        let pipeline = ExportEncodePipeline(depth: 2, cancellation: nil) { frame in
            if frame.index == 3 { throw EncodeFailure() }
        }
        XCTAssertThrowsError(try {
            for i in 0..<1000 { try pipeline.submit(ExportPaintedFrame(index: i, rgba: [], sound: nil)); submitted += 1 }
        }()) { XCTAssertEqual($0 as? EncodeFailure, EncodeFailure()) }
        XCTAssertLessThanOrEqual(submitted, 5, "the painter stops one frame after the failed one")
        XCTAssertThrowsError(try pipeline.finish()) { XCTAssertEqual($0 as? EncodeFailure, EncodeFailure()) }
        pipeline.abandon()   // safe after finish: the thread has ended
    }
}
