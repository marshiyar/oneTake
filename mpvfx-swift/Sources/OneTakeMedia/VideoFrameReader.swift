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

/// Reads display-ready frames from a video or still image.
public final class VideoFrameReader {
    /// How a frame is placed in the requested size.
    public enum Fit: UInt32, Sendable {
        /// Scaled to fit, centred, with transparent margins (MPVFX_FIT_CONTAIN).
        case contain = 0
        /// Scaled to fill the size exactly (MPVFX_FIT_STRETCH).
        case stretch = 1
    }

    public struct Info: Equatable, Sendable {
        /// Display size: rotation, pixel aspect and EXIF orientation applied.
        public let width: Int, height: Int
        /// Seconds; 0 for stills.
        public let duration: Double
        /// Frames per second; 0 for stills.
        public let frameRate: Double
        public let isStill: Bool
    }

    /// Work the reader did since it was opened (diagnostics and the preview benchmark).
    public struct Stats: Equatable, Sendable {
        public var frames = 0, pictures = 0
        /// Seconds spent decoding, converting colour, and scaling into the caller's buffer.
        public var decode = 0.0, convert = 0.0, scale = 0.0
        public init() {}
    }

    private let reader: OpaquePointer
    public let info: Info

    public init(path: String) throws {
        guard let opened = mpvfx_video_open(path) else { throw MediaError.fromEngine(MPVFX_ERR_INVALID_DATA) }
        var raw = MpvfxVideoInfo()
        let status = mpvfx_video_info(opened, &raw)
        if status != MPVFX_OK {
            let error = MediaError.fromEngine(status)
            mpvfx_video_close(opened)
            throw error
        }
        reader = opened
        info = Info(width: Int(raw.width), height: Int(raw.height), duration: raw.duration, frameRate: raw.frame_rate,
                    isStill: raw.is_still != 0)
    }

    deinit { mpvfx_video_close(reader) }

    public func stats() throws -> Stats {
        var raw = MpvfxVideoStats()
        try MediaError.check(mpvfx_video_stats(reader, &raw))
        var stats = Stats()
        stats.frames = Int(raw.frames)
        stats.pictures = Int(raw.pictures)
        stats.decode = Double(raw.decode_ns) / 1_000_000_000
        stats.convert = Double(raw.convert_ns) / 1_000_000_000
        stats.scale = Double(raw.scale_ns) / 1_000_000_000
        return stats
    }

    /// The frame shown at `seconds` as straight-alpha RGBA8 of `width` x `height`, and that frame's presentation time.
    public func frame(at seconds: Double, width: Int, height: Int, fit: Fit = .contain) throws -> (rgba: [UInt8], time: Double) {
        guard width > 0, height > 0 else {
            throw MediaError(kind: .argument, message: "invalid frame size \(width)x\(height)")
        }
        var shown = 0.0
        var status = MPVFX_OK
        // The engine fills every byte, so the array is handed over uninitialised.
        let pixels = [UInt8](unsafeUninitializedCapacity: width * height * 4) { buffer, initialized in
            status = mpvfx_video_frame_at(reader, seconds, u32(width), u32(height), fit.rawValue, buffer.baseAddress,
                                          buffer.count, &shown)
            initialized = status == MPVFX_OK ? buffer.count : 0
        }
        try MediaError.check(status)
        return (pixels, shown)
    }
}
