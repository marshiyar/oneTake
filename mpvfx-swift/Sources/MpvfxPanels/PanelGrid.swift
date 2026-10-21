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

/// The one layout metric set of the side panels (docs/DESIGN.md "Layout grid"): an 8 pt vertical grid, a 16 pt
/// gutter, and a two-column row (label column, control column) whose split depends only on the content width, so
/// every inspector section lines its labels, values and controls up on the same x positions.
///
/// Rows are whole grid steps tall (`rowHeight` for a control row, `compactRowHeight` for a heading or one line
/// of hint text) and are stacked with gaps that are grid steps too, so every row's top lands on the grid.
public enum PanelGrid {
    /// The grid step: row heights, gaps and paddings are multiples of it.
    public static let unit = 8.0
    /// Panel edge to content (left and right).
    public static let gutter = 16.0
    /// A control row: number field, slider, toggle, segmented control, buttons.
    public static let rowHeight = 32.0
    /// A heading, a section title or one line of hint text.
    public static let compactRowHeight = 24.0
    /// One wrapped line of a note.
    public static let lineHeight = 16.0
    /// Top and bottom padding of an open inspector group's body.
    public static let bodyPadding = 8.0
    /// Space between the label column and the control column.
    public static let columnGap = 8.0
    /// The narrowest and widest label column; between them it is a third of the content width, on the grid.
    public static let minLabelWidth = 72.0, maxLabelWidth = 96.0
    /// WCAG 2.2 SC 2.5.8 Target Size (Minimum): the smallest pointer target, in points.
    public static let minTarget = 24.0
    /// The space between a control row's text and the next item in the same row.
    public static let itemGap = 4.0

    /// The label column's width for a row `contentWidth` wide.
    public static func labelWidth(contentWidth: Double) -> Double {
        let third = (contentWidth / 3 / unit).rounded(.down) * unit
        return min(maxLabelWidth, max(minLabelWidth, third))
    }

    /// The label and control columns of a row rect: the label from the row's left edge, the control from the
    /// label column's end plus `columnGap` to the row's right edge.
    public static func columns(_ row: CanvasRect) -> (label: CanvasRect, control: CanvasRect) {
        let lw = min(labelWidth(contentWidth: row.width), max(0, row.width - columnGap))
        let label = CanvasRect(x: row.x, y: row.y, width: lw, height: row.height)
        let cx = row.x + lw + columnGap
        return (label, CanvasRect(x: cx, y: row.y, width: max(0, row.maxX - cx), height: row.height))
    }

    /// `v` rounded up to the next grid step (a row slot that holds a bespoke row of any height).
    public static func snapUp(_ v: Double) -> Double {
        guard v.isFinite, v > 0 else { return 0 }
        return (v / unit - 1e-9).rounded(.up) * unit
    }

    /// Whether `v` is a whole number of grid steps (within float error).
    public static func isOnGrid(_ v: Double) -> Bool {
        abs(v / unit - (v / unit).rounded()) < 1e-6
    }
}
