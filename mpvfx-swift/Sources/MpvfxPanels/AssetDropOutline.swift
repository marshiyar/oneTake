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
import MpvfxCanvas
import MpvfxTheme
import MpvfxTimeline

/// The timeline's drop target while a bin asset is dragged over it (`isDragOver`:
/// `outline outline-1 outline-studio-accent/60 outline-offset-[-1px]` on the tracks container).
public enum AssetDropOutline {
    public static var color: CanvasColor { PanelTheme.accent.withAlpha(0.6) }

    /// The tracks area below the timeline toolbar, where a drop lands (window coordinates in, window coordinates out).
    public static func tracksArea(timeline r: CanvasRect) -> CanvasRect {
        CanvasRect(x: r.x, y: r.y + TimelineToolbar.height, width: r.width, height: max(0, r.height - TimelineToolbar.height))
    }

    /// A 1 px accent line just inside the tracks area's edge.
    public static func draw(_ c: CanvasContext, timeline: CanvasRect) {
        let area = tracksArea(timeline: timeline)
        guard area.width > 2, area.height > 2 else { return }
        c.stroke(.rect(area.insetBy(0.5)), color, StrokeStyle(width: 1))
    }
}
