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

/// The facts about one source file the Info panel shows (read-only; `nil` where the file has no such stream).
public struct ClipInfo: Equatable, Sendable {
    /// The file's path as the user would find it (absolute when it could be resolved).
    public var path: String
    public var container: String?
    public var videoCodec: String?
    /// Display size in pixels (rotation and pixel aspect applied).
    public var width: Int?, height: Int?
    public var frameRate: Double?
    public var duration: Double?
    public var audioCodec: String?
    public var channels: Int?, sampleRate: Int?
    /// `true` for an HDR stream, `false` for SDR, nil without a picture.
    public var hdr: Bool?
    public var fileSize: Int64?
    /// The file is missing, so only `path` is known.
    public var offline: Bool

    public init(path: String, container: String? = nil, videoCodec: String? = nil, width: Int? = nil, height: Int? = nil,
                frameRate: Double? = nil, duration: Double? = nil, audioCodec: String? = nil, channels: Int? = nil,
                sampleRate: Int? = nil, hdr: Bool? = nil, fileSize: Int64? = nil, offline: Bool = false) {
        self.path = path; self.container = container; self.videoCodec = videoCodec; self.width = width; self.height = height
        self.frameRate = frameRate; self.duration = duration; self.audioCodec = audioCodec; self.channels = channels
        self.sampleRate = sampleRate; self.hdr = hdr; self.fileSize = fileSize; self.offline = offline
    }

    /// A missing file: its path and the offline mark.
    public static func missing(path: String) -> ClipInfo { ClipInfo(path: path, offline: true) }
}
