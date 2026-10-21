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
import MpvfxShared

// The "dissolve" scenario: clip1080.mp4 cut to clip1080b.mp4 on one track at 5 s with a centred 150-frame cross-
// dissolve (frames 75…225), so half of the 10 s timeline plays two 1080p30 H.264 lanes at once and mixes them, the
// case the "stacked" scenario measures with two tracks.

/// A 1920x1080 30 fps project: clip1080 [0, 150) from source 0 and clip1080b [150, 300) from source 150, both with
/// 150 frames of handle on the side the dissolve borrows from.
func dissolveDocument(dir: String) throws -> NativeProjectDocument {
    let json = ##"""
    {"schemaVersion":1,"id":"project:bench-dissolve","revision":1,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":1920,"height":1080,"background":"#000000"},
     "assets":[{"id":"a0","kind":"video","name":"clip1080.mp4","source":"\##(dir)/clip1080.mp4","durationFrames":300},
               {"id":"a1","kind":"video","name":"clip1080b.mp4","source":"\##(dir)/clip1080b.mp4","durationFrames":300}],
     "sequence":{"id":"s","name":"Main","tracks":[{"id":"t0","kind":"video","lane":{"authoredTrack":1,"displayTrack":0},"clips":[
       {"id":"c0","assetId":"a0","startFrame":0,"durationFrames":150,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]},
       {"id":"c1","assetId":"a1","startFrame":150,"durationFrames":150,"sourceInFrame":150,"muted":false,"effects":[],"parameterTracks":[]}],
      "transitions":[{"v":1,"id":"d","fromClipId":"c0","toClipId":"c1","kind":"dissolve","durationFrames":150,"alignment":"centre"}]}]}}
    """##
    return try parseNativeProjectDocument(try NativeJSONValue.parse(json))
}
