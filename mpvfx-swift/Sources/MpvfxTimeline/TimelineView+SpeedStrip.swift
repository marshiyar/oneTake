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
// A ramped clip's speed strip: a 2 px line along the foot of the clip, brighter the further the speed is from 1x, in the
// accent where the clip slows down and in white where it speeds up (theme tokens, so it follows both appearances).
import Foundation
import MpvfxCanvas
import MpvfxShared
import MpvfxTheme

extension TimelineView {
    public static let speedStripHeight = 2.0

    /// The strip's colour at `speed`: 1x is faint, 0.1x and 10x are the strongest.
    static func speedStripColor(speed: Double) -> CanvasColor {
        let level = min(1, abs(log10(max(speed, 1e-3))))
        let base = speed < 1 ? ThemeTokens.mint : ThemeTokens.white
        return CanvasColor(base.alpha(0.3 + 0.65 * level))
    }

    func drawSpeedStrip(_ c: CanvasContext, _ r: CanvasRect, _ clip: TimelineClipModel) {
        guard let ramp = clip.speedRamp, r.width >= 12, r.height > 16 else { return }
        let frames = clip.duration * max(frameRate, 1e-9)
        let left = r.x + 3, right = r.maxX - 3, y = r.maxY - Self.speedStripHeight - 1
        var x = left
        while x < right {
            let w = min(2, right - x)
            let frame = (x + w / 2 - r.x) / r.width * frames
            c.fillRect(CanvasRect(x: x, y: y, width: w, height: Self.speedStripHeight), Self.speedStripColor(speed: ramp.speed(atClipFrame: frame)))
            x += 2
        }
    }
}
