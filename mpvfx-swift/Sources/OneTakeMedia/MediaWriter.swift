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

/// Writes an exported movie: RGBA frames at a fixed rate plus interleaved audio, finished into place atomically.
public final class MediaWriter {
    /// MP4 (H.264 video, FLAC audio) or MOV (PNG video with alpha, 16-bit PCM audio).
    public enum Container: UInt32, Sendable { case mp4 = 0, mov = 1 }
    public enum Quality: UInt32, Sendable { case draft = 0, standard = 1, high = 2 }

    public struct Config: Equatable, Sendable {
        public var container: Container
        /// Even pixel sizes.
        public var width: Int, height: Int
        public var fpsNumerator = 30, fpsDenominator = 1
        public var quality = Quality.standard
        /// 0 writes no audio track.
        public var audioRate = 48_000
        public var audioChannels = 2

        /// 30 fps, standard quality, 48 kHz stereo; change the fields for anything else.
        public init(container: Container, width: Int, height: Int) {
            self.container = container
            self.width = width
            self.height = height
        }
    }

    private let writer: OpaquePointer
    public let config: Config

    public init(path: String, config: Config) throws {
        var raw = MpvfxWriterConfig()
        raw.container = config.container.rawValue
        raw.width = u32(max(0, config.width))
        raw.height = u32(max(0, config.height))
        raw.fps_num = u32(max(0, config.fpsNumerator))
        raw.fps_den = u32(max(0, config.fpsDenominator))
        raw.quality = config.quality.rawValue
        raw.audio_rate = u32(max(0, config.audioRate))
        raw.audio_channels = u32(max(0, config.audioChannels))
        guard let opened = mpvfx_writer_open(path, &raw) else { throw MediaError.fromEngine(MPVFX_ERR_ARGUMENT) }
        writer = opened
        self.config = config
    }

    /// Releases the writer; a file that was never finished is deleted by the engine.
    deinit { mpvfx_writer_close(writer) }

    /// Appends one frame of straight RGBA8 (width x height x 4 bytes).
    public func addVideo(_ rgba: [UInt8]) throws {
        try MediaError.check(rgba.withUnsafeBufferPointer { mpvfx_writer_add_video(writer, $0.baseAddress, $0.count) })
    }

    /// Appends interleaved samples; a trailing partial frame is dropped.
    public func addAudio(_ samples: [Float]) throws {
        guard config.audioChannels > 0 else { return }
        let frames = samples.count / config.audioChannels
        try MediaError.check(samples.withUnsafeBufferPointer { mpvfx_writer_add_audio(writer, $0.baseAddress, frames) })
    }

    /// Completes the file and moves it to its final path.
    public func finish() throws {
        try MediaError.check(mpvfx_writer_finish(writer))
    }
}
