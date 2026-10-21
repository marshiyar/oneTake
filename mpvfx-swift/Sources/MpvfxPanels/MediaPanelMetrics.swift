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

/// Every spacing value of the Media panel, in points, in one place so the panels' shared layout metrics can
/// replace it in one edit. Every row (header, search, section titles) and the grid start at `inset` from the left
/// edge and end at `inset` from the right edge; nothing in the panel computes its own padding.
///
/// The values sit on an 8 pt grid with a 16 pt gutter, 32 pt control rows, 24 pt compact rows and 16 pt text
/// lines, the side panels' layout grid, so adopting a shared metric type is a rename of these names.
public enum MediaPanelMetrics {
    /// Left and right content inset of every row and of the grid.
    public static let inset = 16.0
    /// Space under the tab strip, and between the header row, the search row and the first section.
    public static let rowGap = 8.0
    /// Header buttons, the search field and the filter button (toolbar targets are at least 28 pt).
    public static let control = 32.0
    /// Between controls side by side in one row.
    public static let controlGap = 8.0
    /// The switcher keeps at least this width; below it Import shows only its plus.
    public static let minSwitcher = 120.0
    /// Section title line (title and count), above its tiles or rows.
    public static let sectionHeader = 24.0
    /// Space above every section title but the first.
    public static let sectionGap = 8.0
    /// Gap between tiles, across and down.
    public static let tileGap = 8.0
    /// The narrowest tile: 2 columns at 280 pt and 364 pt, 3 at 409 pt (content = width − 2 × inset).
    public static let minTileWidth = 112.0
    /// Thumbnails are 16:9 whatever the media's shape; the picture fills the tile (see `MediaTileDraw.fill`).
    public static let thumbAspect = 9.0 / 16
    /// Name lines under a thumbnail: at most two, end-truncated.
    public static let nameTop = 4.0, nameLine = 16.0, nameLines = 2
    /// The hover action on a tile (add, attach, save): the 24 pt minimum target.
    public static let tileAction = 24.0
    /// Badges on a thumbnail (duration, Missing) and their distance from its edges.
    public static let badgeHeight = 16.0, badgeInset = 4.0
    /// An audio or font row.
    public static let row = 48.0
    /// Context-menu rows: taller than the 24 pt dropdown rows, since they hold a shortcut hint beside the label.
    public static let menuItem = 28.0

    /// Grid columns that fit `content` points (the panel width less both insets).
    public static func columns(_ content: Double) -> Int {
        max(1, Int(((content + tileGap) / (minTileWidth + tileGap)).rounded(.down)))
    }

    /// Width of one tile when `columns` share `content` points.
    public static func tileWidth(_ content: Double, columns: Int) -> Double {
        max(0, (content - tileGap * Double(columns - 1)) / Double(max(1, columns)))
    }

    /// Height of a tile `width` wide: the 16:9 thumbnail and two name lines.
    public static func tileHeight(_ width: Double) -> Double {
        width * thumbAspect + nameTop + nameLine * Double(nameLines)
    }
}
