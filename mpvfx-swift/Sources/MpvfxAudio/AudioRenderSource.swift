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

/// What `AudioPlayback` pulls blocks from: the legacy clip mixer or the bus/FX graph (`GraphAudioSource`).
/// Master gain and mute are the transport's; they apply after the mix.
public protocol AudioRenderSource: AnyObject {
    var format: AudioFormat { get }
    var masterGain: Double { get set }
    var muted: Bool { get set }
    /// Position the next `render` at timeline time `t` (seconds).
    func seek(_ t: Double)
    /// Next `frames` frames, interleaved, always exactly `frames * channels` samples.
    func render(frames: Int) -> [Float]
    /// A seek to `t` is coming (the loop start): get ready so it is instant. Never blocks.
    func prepareSeek(_ t: Double)
}

public extension AudioRenderSource {
    func prepareSeek(_ t: Double) {}
}

extension AudioMixer: AudioRenderSource {}
