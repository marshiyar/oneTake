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
import CMediaEngine

/// Reads a file's first audio track as interleaved Float32 samples at a chosen rate and channel count.
public final class AudioSampleReader {
    private let reader: OpaquePointer
    public let sampleRate: Int, channels: Int

    public init(path: String, sampleRate: Int, channels: Int) throws {
        guard sampleRate > 0, channels > 0 else {
            throw MediaError(kind: .argument, message: "invalid audio format \(sampleRate) Hz, \(channels) channels")
        }
        guard let opened = mpvfx_audio_open(path, u32(sampleRate), u32(channels)) else {
            throw MediaError.fromEngine(MPVFX_ERR_ARGUMENT)
        }
        reader = opened
        self.sampleRate = sampleRate
        self.channels = channels
    }

    deinit { mpvfx_audio_close(reader) }

    /// Source duration in seconds.
    public var duration: Double { mpvfx_audio_duration(reader) }

    public func seek(to seconds: Double) throws {
        try MediaError.check(mpvfx_audio_seek(reader, seconds))
    }

    /// Pitch-preserving speed (0.25 ... 4) for everything read after the call.
    public func setTempo(_ tempo: Double) throws {
        try MediaError.check(mpvfx_audio_set_tempo(reader, tempo))
    }

    /// Up to `frames` frames of interleaved samples; fewer near the end, empty once the track is finished.
    public func read(frames: Int) throws -> [Float] {
        guard frames > 0 else { return [] }
        var samples = [Float](repeating: 0, count: frames * channels)
        let got = samples.withUnsafeMutableBufferPointer { mpvfx_audio_read(reader, $0.baseAddress, frames) }
        guard got >= 0 else { throw MediaError.fromEngine(Int32(truncatingIfNeeded: got)) }
        samples.removeSubrange(Int(got) * channels..<samples.count)
        return samples
    }
}
