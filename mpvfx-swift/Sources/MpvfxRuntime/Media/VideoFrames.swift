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
// Thumbnail frames decoded by the media engine (VideoFrameReader)
// and encoded as JPEG by it (ImageCodec), as formats.md asks for frames crossing the backend boundary. No browser,
// DOM, or composition markup. At most two decodes run at once; waiters can be cancelled.
import Foundation
import OneTakeMedia
import MpvfxShared

/// A thumbnail strip request (VideoFramesRequest). frameCount, width and
/// height are Int, so whole numbers are enforced by the type.
public struct VideoFramesRequest: Equatable, Sendable {
    public var source: String; public var sourceStart: Double?; public var sourceRangeDuration: Double?
    public var frameCount: Int; public var width: Int; public var height: Int
    public init(source: String, sourceStart: Double? = nil, sourceRangeDuration: Double? = nil, frameCount: Int, width: Int, height: Int) {
        self.source = source; self.sourceStart = sourceStart; self.sourceRangeDuration = sourceRangeDuration
        self.frameCount = frameCount; self.width = width; self.height = height
    }
}

/// `frames` are base64 JPEGs.
public struct VideoFramesResult: Equatable, Sendable {
    public var duration: Double; public var aspect: Double; public var width: Int; public var height: Int; public var frames: [String]
}

private final class DecoderSlots: @unchecked Sendable {
    let condition = NSCondition()
    var active = 0
    func acquire(_ cancellation: MediaCancellation) throws {
        try cancellation.throwIfCancelled()
        condition.lock(); defer { condition.unlock() }
        while active >= 2 {
            if cancellation.isCancelled { throw MediaAbortError() }
            _ = condition.wait(until: Date().addingTimeInterval(0.05))
        }
        active += 1
    }
    func release() { condition.lock(); active -= 1; condition.signal(); condition.unlock() }
}
private let decoderSlots = DecoderSlots()

public func decodeNativeVideoFrames(_ projectRoot: String, _ request: VideoFramesRequest, cancellation: MediaCancellation) throws -> VideoFramesResult {
    try decoderSlots.acquire(cancellation)
    defer { decoderSlots.release() }
    do { return try decodeFrames(projectRoot, request, cancellation) } catch let e as MediaError { throw mediaToolError(e) }
}

/// JPEG quality of a thumbnail for our baseline encoder: 85, a high quality that keeps the strips small.
let VIDEO_FRAME_JPEG_QUALITY = 85

/// JS Math.round for the positive values used here.
private func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

private func decodeFrames(_ projectRoot: String, _ request: VideoFramesRequest, _ cancellation: MediaCancellation) throws -> VideoFramesResult {
    func invalid(_ v: Double?) -> Bool { v.map { !$0.isFinite || $0 < 0 } ?? false }
    if request.source.isEmpty || !(1...6).contains(request.frameCount) || !(1...480).contains(request.width) ||
        !(1...270).contains(request.height) || invalid(request.sourceStart) || invalid(request.sourceRangeDuration) {
        throw MediaToolError("Invalid video frame request")
    }
    let root = try ProjectFS.realpath(projectRoot)
    let source = try ProjectFS.realpath(PosixPath.resolve(root, request.source))
    let offset = PosixPath.relative(root, source)
    if try PosixPath.isAbsolute(offset) || offset == ".." || offset.hasPrefix("../") ||
        source.range(of: #"\.(mp4|mov|m4v|webm|mkv|avi|mxf)$"#, options: [.regularExpression, .caseInsensitive]) == nil ||
        !ProjectFS.statInfo(source).isFile {
        throw MediaToolError("Video source must be a media file inside this project")
    }
    try cancellation.throwIfCancelled()
    let reader = try VideoFrameReader(path: source)
    // The reader's size is the display size: pixel aspect and rotation are already applied.
    guard reader.info.width > 0, reader.info.height > 0 else { throw MediaToolError("Video source has no decodable video track") }
    let aspect = Double(reader.info.width) / Double(reader.info.height)
    let width = Swift.max(1, Swift.min(Double(request.width), jsRound(Double(request.height) * aspect)))
    let height = Swift.max(1, Swift.min(Double(request.height), jsRound(width / aspect)))
    let duration = reader.info.duration
    guard duration.isFinite, duration > 0 else { throw MediaToolError("Video duration is unavailable") }
    let frameRate = reader.info.frameRate
    let lastFrame = Swift.max(0, duration - (frameRate.isFinite && frameRate > 0 ? 1 / frameRate : 0.1))
    let start = Swift.min(request.sourceStart ?? 0, lastFrame)
    let range = Swift.min(request.sourceRangeDuration ?? duration - start, duration - start)
    var frames: [String] = []
    for index in 0..<request.frameCount {
        try cancellation.throwIfCancelled()
        let fraction = request.frameCount == 1 ? 0.5 : Double(index) / Double(request.frameCount - 1)
        let time = Swift.min(start + range * fraction, lastFrame)
        let frame = try reader.frame(at: time, width: Int(width), height: Int(height), fit: .stretch)
        let jpeg = try ImageCodec.encodeJPEG(rgba: frame.rgba, width: Int(width), height: Int(height), quality: VIDEO_FRAME_JPEG_QUALITY)
        guard !jpeg.isEmpty else { throw MediaToolError("Video source returned no frame") }
        frames.append(jpeg.base64EncodedString())
    }
    return VideoFramesResult(duration: duration, aspect: aspect, width: Int(width), height: Int(height), frames: frames)
}
