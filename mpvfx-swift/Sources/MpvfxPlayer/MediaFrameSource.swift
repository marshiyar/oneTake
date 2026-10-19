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
import Foundation
import MpvfxCanvas
import OneTakeMedia

/// Frames of `source` from `startSeconds`, one every `rate / fps` seconds of source time, decoded by the media
/// engine. Each frame is exactly width×height: the picture is fitted inside keeping its aspect (as export does),
/// upright (rotation, pixel aspect and EXIF orientation applied), and the rest is transparent.
public final class MediaFrameStream {
    public let width: Int, height: Int, fps: Double, startSeconds: Double, rate: Double
    let reader: VideoFrameReader
    let still: Bool
    public private(set) var framesRead = 0

    /// Which frames a stream returns: from `start` (source seconds), `fps` per timeline second, fitted to
    /// width×height. `rate` is the clip playback rate (frames are 1/fps apart in timeline time, rate/fps in source
    /// time); `still` returns exactly one frame (image clips).
    public struct Frames: Equatable, Sendable {
        public var start: Double, fps: Double, width: Int, height: Int
        public var rate = 1.0, still = false

        public init(from start: Double, fps: Double, width: Int, height: Int) {
            self.start = start; self.fps = fps; self.width = width; self.height = height
        }

        /// The single frame of an image (or the first frame of a video).
        public static func still(width: Int, height: Int) -> Frames {
            var f = Frames(from: 0, fps: 1, width: width, height: height); f.still = true; return f
        }

        /// One frame at `seconds` (a thumbnail), or the still when `still`.
        public static func one(at seconds: Double, width: Int, height: Int, still: Bool) -> Frames {
            still ? .still(width: width, height: height) : Frames(from: seconds, fps: 1, width: width, height: height)
        }

        public func playing(at rate: Double) -> Frames { var f = self; f.rate = rate; return f }
    }

    /// `reader` is shared with earlier streams of the same file, so a restart reuses the parsed file and decoder
    /// instead of opening it again.
    public init(reader: VideoFrameReader, frames f: Frames) {
        self.reader = reader; width = f.width; height = f.height; fps = f.fps
        startSeconds = f.start; rate = f.rate; still = f.still || reader.info.isStill
    }

    public convenience init(source: String, frames: Frames) throws {
        self.init(reader: try VideoFrameReader(path: source), frames: frames)
    }

    /// Source time of the next frame this stream will return.
    public var nextTime: Double { startSeconds + Double(framesRead) * rate / fps }

    /// Passes over the next `count` frames without returning them (a lane that fell behind the playhead). The engine
    /// reader then decodes forward to the frame after them, converting none of the ones passed over.
    public func skip(_ count: Int) { if !still { framesRead += max(0, count) } }

    /// The next frame; nil at the end of the media (or after a still's one frame) and when it cannot be decoded.
    public func next() -> CanvasImage? {
        if still ? framesRead > 0 : nextTime >= reader.info.duration { return nil }
        guard let frame = try? reader.frame(at: still ? 0 : max(0, nextTime), width: width, height: height) else { return nil }
        framesRead += 1
        return CanvasImage(width: width, height: height, rgba: frame.rgba)
    }
}
