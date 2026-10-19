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
// Media metadata: the stream facts (duration, picture size, sound) the editor keeps for a media file.
import Foundation

/// Stream facts from the original media, independent of a clip's mute setting.
public struct MediaMetadata: Codable, Equatable {
    public var duration: Double
    public var hasVideo: Bool
    public var hasAudio: Bool
    /// Natural picture size of the first picture stream (NativeMediaNaturalSize.display); nil without one.
    public var width: Double? = nil, height: Double? = nil
    public init(duration: Double, hasVideo: Bool, hasAudio: Bool, width: Double? = nil, height: Double? = nil) {
        self.duration = duration; self.hasVideo = hasVideo; self.hasAudio = hasAudio; self.width = width; self.height = height
    }
}
