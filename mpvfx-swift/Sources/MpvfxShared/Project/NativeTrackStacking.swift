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

/// Compositing layer of each track (index-aligned with `tracks`): the timeline's top row draws on top.
/// Display order is lane.displayTrack, then document order; the top row gets the highest layer.
public func nativeTrackStackingLayers(_ tracks: [NativeProjectTrack]) -> [Double] {
    let order = tracks.enumerated()
        .sorted { ($0.element.lane?.displayTrack ?? Double($0.offset), $0.offset) < ($1.element.lane?.displayTrack ?? Double($1.offset), $1.offset) }
        .map(\.offset)
    var layers = [Double](repeating: 0, count: tracks.count)
    for (position, index) in order.enumerated() { layers[index] = Double(tracks.count - 1 - position) }
    return layers
}
