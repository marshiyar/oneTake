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
import MpvfxTimeline

/// The shortcuts card's "Keyframe marks" legend (#201): each kind's mark, as the timeline and the inspector draw it,
/// with what it keys, then the three interpolation variants on a transform mark.
public let keyframeLegend: [(kind: TimelineKeyframeKind, label: String)] = [
    (.transform, "Transform (position, size…)"), (.threeD, "3D (depth, tilt)"), (.opacity, "Opacity"),
    (.color, "Color and grade"), (.effect, "Effect amounts"), (.audio, "Audio volume"),
]
public let keyframeEaseLegend: [(ease: TimelineKeyframeEase, label: String)] = [(.linear, "Linear"), (.ease, "Ease"), (.hold, "Hold")]

extension ShortcutsPanel {
    /// Appends the legend's draws below `y` and returns the new bottom.
    static func layoutKeyframeLegend(_ L: inout Layout, from top: Double) -> Double {
        var y = top + 12
        let titleY = y
        L.draws.append { c, o in
            c.drawText("KEYFRAME MARKS", at: .init(o.x + 12, o.y + titleY), font: CanvasFont(size: 9, weight: .medium), color: PanelStyle.neutral500)
        }
        y += 13.5 + 6
        for (i, entry) in keyframeLegend.enumerated() {
            let rowY = y
            L.draws.append { c, o in
                TimelineKeyframeGlyph.draw(c, .init(entry.kind), at: CanvasPoint(o.x + 22, o.y + rowY + 8), r: 6)
                c.drawText(entry.label, at: .init(o.x + 40, o.y + rowY + 3), font: CanvasFont(size: 10), color: PanelStyle.neutral400)
            }
            y += 16 + (i == keyframeLegend.count - 1 ? 6 : 2)
        }
        let easeY = y
        L.draws.append { c, o in
            var x = o.x + 16
            for e in keyframeEaseLegend {
                TimelineKeyframeGlyph.draw(c, .init(.transform, ease: e.ease), at: CanvasPoint(x + 6, o.y + easeY + 8), r: 6)
                c.drawText(e.label, at: .init(x + 16, o.y + easeY + 3), font: CanvasFont(size: 10), color: PanelStyle.neutral400)
                x += 62
            }
        }
        return y + 16
    }
}
