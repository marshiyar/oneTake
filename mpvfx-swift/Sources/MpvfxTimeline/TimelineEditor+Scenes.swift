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
import MpvfxShared

public extension TimelineEditor {
    /// Split one video at source-time scene boundaries, preserving its position and all media.
    /// Descending splits retain the original id for the next boundary; the transaction is one undo step.
    @discardableResult
    func splitScenes(clipId: String, sourceTimes: [Double]) -> Bool {
        guard let address = address(clipId: clipId), !isTrackLocked(address.trackId), let (_, clip) = clip(clipId),
              document.assets.contains(where: { $0.id == clip.assetId && $0.kind == .video }),
              clip.speedRamp == nil, clip.holdSourceFrame == nil else { return false }
        let rate = clip.playbackRate.map { $0.numerator / $0.denominator } ?? 1
        guard rate.isFinite, rate > 0 else { return false }
        let sourceIn = sourceFrameValue(.init(sourceInFrame: clip.sourceInFrame, sourceInFraction: clip.sourceInFraction))
        let frames = Set(sourceTimes.filter(\.isFinite).map {
            (clip.startFrame + ($0 * fps - sourceIn) / rate).rounded()
        }.filter { $0 > clip.startFrame && $0 < clip.startFrame + clip.durationFrames }).sorted(by: >)
        guard !frames.isEmpty else { return false }
        return transaction("Split at scene changes") { step, _ in
            frames.allSatisfy { step(.split(address: address, splitFrame: $0)) }
        }
    }
}
