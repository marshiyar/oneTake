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

/// The four tool buttons (select, razor, slip, roll): which tool each one picks, its tooltip and its glyph.
extension TimelineToolbar {
    static func tool(for item: Item) -> TimelineController.Tool {
        switch item {
        case .razor: .razor
        case .slip: .slip
        case .roll: .roll
        default: .select
        }
    }

    static func toolTooltip(_ tool: TimelineController.Tool) -> String {
        switch tool {
        case .select: "Selection tool (V)"
        case .razor: "Razor tool (B) — Shift+click splits all tracks"
        case .slip: "Slip tool (Y) — drag a clip to change which part of its media plays"
        case .roll: "Roll tool — drag the cut between two touching clips"
        }
    }

    static func drawToolGlyph(_ c: CanvasContext, _ item: Item, _ icon: CanvasRect, _ col: CanvasColor) {
        switch tool(for: item) {
        case .select:
            c.fill(TimelineIconPath.parse("M2 0.5L10 6L6.5 6.5L8.5 11L6.5 11.5L4.5 7L2 9Z", viewBox: 12, into: icon), col)
        case .razor: drawScissors(c, icon, col)
        case .slip:
            // A clip frame with a two-way arrow inside: the content moves, the frame does not.
            c.stroke(TimelineIconPath.parse("M1.5 3.5H14.5V12.5H1.5Z", viewBox: 16, into: icon), col, StrokeStyle(width: 1.2))
            c.stroke(TimelineIconPath.parse("M4.5 8H11.5M4.5 8L6.5 6M4.5 8L6.5 10M11.5 8L9.5 6M11.5 8L9.5 10", viewBox: 16, into: icon),
                     col, StrokeStyle(width: 1.2))
        case .roll:
            // "][": the end of one clip against the start of the next.
            c.stroke(TimelineIconPath.parse("M1.5 3H5.5V13H1.5M14.5 3H10.5V13H14.5", viewBox: 16, into: icon), col, StrokeStyle(width: 1.6))
        }
    }
}
