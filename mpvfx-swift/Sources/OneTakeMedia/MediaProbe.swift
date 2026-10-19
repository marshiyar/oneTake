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
import Foundation

/// What the media engine reads from a file: container, duration and its first video and audio streams.
/// Decoded from the JSON object `mpvfx_probe_json` returns (keys match the property names).
public struct MediaProbe: Decodable, Equatable, Sendable {
    public struct Video: Decodable, Equatable, Sendable {
        /// Codec name (h264, hevc, prores, av1, vp9, vp8, png, mjpeg, bmp, ...).
        public let codec: String
        /// Coded size, before rotation and pixel aspect.
        public let width: Int, height: Int
        /// Sample (pixel) aspect ratio.
        public let sarNum: Int, sarDen: Int
        /// Clockwise rotation, in degrees, applied for display.
        public let rotation: Int
        /// EXIF orientation of a still image (1 = as stored).
        public let orientation: Int
        /// Size shown to the user: rotation, pixel aspect and orientation applied.
        public let displayWidth: Int, displayHeight: Int
        public let frameRate: Double?
        public let frames: Int
        public let still: Bool
        public let hdr: Bool
        public let decodable: Bool
        /// Why the stream cannot be decoded, in words for the user; nil when `decodable`.
        public let reason: String?
    }

    public struct Audio: Decodable, Equatable, Sendable {
        public let codec: String
        public let sampleRate: Int, channels: Int
        public let decodable: Bool
        public let reason: String?
    }

    /// Container name (mp4, mov, png, jpeg, bmp, wav, flac, aac, ...).
    public let container: String
    public let duration: Double?
    public let video: Video?
    public let audio: Audio?

    public static func probe(path: String) throws -> MediaProbe {
        guard let json = mpvfx_probe_json(path) else { throw MediaError.fromEngine(MPVFX_ERR_INVALID_DATA) }
        defer { mpvfx_string_free(json) }
        let data = Data(String(cString: json).utf8)
        do {
            return try JSONDecoder().decode(MediaProbe.self, from: data)
        } catch {
            throw MediaError(kind: .internalError, message: "probe result unreadable: \(error)")
        }
    }
}
