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
// Silence analysis: decode only the selected source interval (the media engine's
// AudioSampleReader, mono at 16 kHz) and detect pauses. Paths remain confined to the project.
import Foundation
import OneTakeMedia
import MpvfxShared

public struct SilenceAnalysisRequest: Equatable, Sendable {
    public var source: String; public var sourceStart: Double; public var sourceDuration: Double
    public init(source: String, sourceStart: Double, sourceDuration: Double) {
        self.source = source; self.sourceStart = sourceStart; self.sourceDuration = sourceDuration
    }
}

private let SAMPLE_RATE = 16_000
private let CHUNK_SECONDS = 120.0
private let OVERLAP_SECONDS = 1.0
private let VIDEO_SOURCE_PATTERN = #"\.(mp4|mov|m4v|webm|mkv|avi|mxf)$"#

/// `duration` seconds of mono samples from `start` (fewer at the end of the track).
private func decodeChunk(_ reader: AudioSampleReader, _ start: Double, _ duration: Double, _ cancellation: MediaCancellation) throws -> [Float] {
    try reader.seek(to: start)
    let wanted = Int((duration * Double(SAMPLE_RATE)).rounded())
    var samples: [Float] = []
    samples.reserveCapacity(wanted)
    while samples.count < wanted {
        try cancellation.throwIfCancelled()
        let chunk = try reader.read(frames: Swift.min(SAMPLE_RATE, wanted - samples.count))
        if chunk.isEmpty { break }
        samples.append(contentsOf: chunk)
    }
    return samples
}

/// The project's real root, the source's real path and its project-relative path; refuses an invalid request or a
/// source that is not a video file inside the project.
private func silenceSource(_ projectRoot: String, _ request: SilenceAnalysisRequest,
                           _ cancellation: MediaCancellation) throws -> (root: String, source: String, offset: String) {
    guard !request.source.isEmpty, request.sourceStart.isFinite, request.sourceStart >= 0,
          request.sourceDuration.isFinite, request.sourceDuration > 0 else { throw MediaToolError("Invalid silence analysis request") }
    try cancellation.throwIfCancelled()
    let root = try ProjectFS.realpath(projectRoot)
    let source = try ProjectFS.realpath(PosixPath.resolve(root, request.source))
    let offset = PosixPath.relative(root, source)
    if try PosixPath.isAbsolute(offset) || offset == ".." || offset.hasPrefix("../") ||
        source.range(of: VIDEO_SOURCE_PATTERN, options: [.regularExpression, .caseInsensitive]) == nil || !ProjectFS.statInfo(source).isFile {
        throw MediaToolError("Video source must be a file inside this project")
    }
    return (root, source, offset)
}

/// Returns source-time ranges. A video whose audio the engine cannot decode is refused with the engine's reason.
public func analyzeProjectVideoSilence(_ projectRoot: String, _ request: SilenceAnalysisRequest, cancellation: MediaCancellation,
                                       options: PartialSilenceRemovalOptions = .init()) throws -> [SilenceRange] {
    let (root, source, offset) = try silenceSource(projectRoot, request, cancellation)
    let probe = try probeProjectMedia(root, offset, cancellation: cancellation).probe
    guard probe.video != nil, let audio = probe.audio else { throw MediaToolError("Selected video has no audio track") }
    guard audio.decodable else { throw MediaToolError(audio.reason ?? "Selected video's audio cannot be decoded") }
    let metadata = mediaMetadata(probe)
    let reader: AudioSampleReader
    do { reader = try AudioSampleReader(path: source, sampleRate: SAMPLE_RATE, channels: 1) } catch let e as MediaError { throw mediaToolError(e) }
    let duration = Swift.min(request.sourceDuration, Swift.max(0, metadata.duration - request.sourceStart))
    guard duration > 0 else { throw MediaToolError("Selected clip is outside the video source") }
    var ranges: [SilenceRange] = []
    var offsetSeconds = 0.0
    while offsetSeconds < duration {
        try cancellation.throwIfCancelled()
        let length = Swift.min(CHUNK_SECONDS, duration - offsetSeconds)
        let samples: [Float]
        do { samples = try decodeChunk(reader, request.sourceStart + offsetSeconds, length, cancellation) }
        catch let e as MediaError { throw mediaToolError(e) }
        for range in detectSilences([samples], sampleRate: Double(SAMPLE_RATE), options: options) {
            let start = request.sourceStart + offsetSeconds + range.start
            let end = request.sourceStart + offsetSeconds + range.end
            if let last = ranges.indices.last, start <= ranges[last].end { ranges[last].end = Swift.max(ranges[last].end, end) }
            else { ranges.append(SilenceRange(start: start, end: end)) }
        }
        offsetSeconds += CHUNK_SECONDS - OVERLAP_SECONDS
    }
    return ranges
}
