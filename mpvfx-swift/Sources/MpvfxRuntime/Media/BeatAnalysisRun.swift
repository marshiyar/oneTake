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
// Beat analysis of a project audio file: decode the slice of the media a clip plays (mono, 48 kHz, the media engine's
// AudioSampleReader), run `BeatAnalysis` and return the beats as seconds of the source. Paths remain confined to the
// project, like silence analysis.
import Foundation
import OneTakeMedia
import MpvfxAudioGraph

public struct BeatAnalysisRequest: Equatable, Sendable {
    public var source: String; public var sourceStart: Double; public var sourceDuration: Double
    public var sensitivity: Double; public var every: Int
    public init(source: String, sourceStart: Double, sourceDuration: Double, sensitivity: Double = 0.5, every: Int = 1) {
        self.source = source; self.sourceStart = sourceStart; self.sourceDuration = sourceDuration
        self.sensitivity = sensitivity; self.every = every
    }
}

private let BEAT_SAMPLE_RATE = 48_000

/// Beats found in the requested slice of an audio file in the project, as `(seconds from the start of the file, 0...1
/// strength)`. `progress` runs on the calling thread with 0...1; `isCancelled` is polled while decoding and
/// analysing, and a cancelled run throws `MediaAbortError`.
public func analyzeProjectAudioBeats(_ projectRoot: String, _ request: BeatAnalysisRequest, isCancelled: () -> Bool = { false },
                                     progress: (Double) -> Void = { _ in }) throws -> [(seconds: Double, strength: Double)] {
    guard !request.source.isEmpty, request.sourceStart.isFinite, request.sourceStart >= 0,
          request.sourceDuration.isFinite, request.sourceDuration > 0 else { throw MediaToolError("Invalid beat analysis request") }
    if isCancelled() { throw MediaAbortError() }
    let root = try ProjectFS.realpath(projectRoot)
    let source = try ProjectFS.realpath(PosixPath.resolve(root, request.source))
    let offset = PosixPath.relative(root, source)
    if try PosixPath.isAbsolute(offset) || offset == ".." || offset.hasPrefix("../") || !ProjectFS.statInfo(source).isFile {
        throw MediaToolError("Audio source must be a file inside this project")
    }
    let reader: AudioSampleReader
    do { reader = try AudioSampleReader(path: source, sampleRate: BEAT_SAMPLE_RATE, channels: 1) } catch let e as MediaError { throw mediaToolError(e) }
    let duration = Swift.min(request.sourceDuration, Swift.max(0, reader.duration - request.sourceStart))
    guard duration > 0 else { throw MediaToolError("The clip is outside the audio source") }
    let wanted = Int((duration * Double(BEAT_SAMPLE_RATE)).rounded())
    var samples: [Float] = []
    samples.reserveCapacity(wanted)
    do {
        try reader.seek(to: request.sourceStart)
        while samples.count < wanted {
            if isCancelled() { throw MediaAbortError() }
            let chunk = try reader.read(frames: Swift.min(BEAT_SAMPLE_RATE, wanted - samples.count))
            if chunk.isEmpty { break }
            samples.append(contentsOf: chunk)
            progress(0.2 * Double(samples.count) / Double(wanted))     // decoding is the first fifth of the work
        }
    } catch let e as MediaError { throw mediaToolError(e) }
    let options = BeatAnalysis.Options(sensitivity: request.sensitivity, every: request.every)
    guard let beats = BeatAnalysis.analyse(samples, sampleRate: Double(BEAT_SAMPLE_RATE), options: options,
                                           isCancelled: isCancelled,
                                           progress: { progress(0.2 + 0.8 * $0) }) else { throw MediaAbortError() }
    return beats.map { (request.sourceStart + $0.time, $0.strength) }
}
