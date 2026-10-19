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

/// Colors and metrics shared by the player popovers (Tailwind neutral palette + studio accent),
/// for the speed menu, volume control and shortcuts panel.
public enum PanelStyle {
    public static var popoverBackground: CanvasColor { CanvasColor(ThemeTokens.popoverPair.now) }
    public static var popoverBorder: CanvasColor { PanelTheme.white.withAlpha(0.08) }
    public static var divider: CanvasColor { PanelTheme.white.withAlpha(0.06) }
    public static var chipBackground: CanvasColor { PanelTheme.white.withAlpha(0.05) }
    public static var accent: CanvasColor { PanelTheme.mint }
    public static var neutral50: CanvasColor { PanelTheme.neutral50 }
    public static var neutral200: CanvasColor { PanelTheme.neutral200 }
    public static var neutral300: CanvasColor { PanelTheme.neutral300 }
    public static var neutral400: CanvasColor { PanelTheme.neutral400 }
    public static var neutral500: CanvasColor { PanelTheme.neutral500 }
    public static var neutral600: CanvasColor { PanelTheme.neutral600 }
    public static var neutral700: CanvasColor { PanelTheme.neutral700 }
    public static var neutral800: CanvasColor { PanelTheme.neutral800 }
    public static var neutral900: CanvasColor { PanelTheme.neutral900 }
    public static var menuItemCurrent: CanvasColor { PanelTheme.white.withAlpha(0.06) }
    public static var menuItemHover: CanvasColor { PanelTheme.white.withAlpha(0.04) }

    /// rounded-lg card with the 1px rgba(255,255,255,0.08) border.
    public static func drawPopover(_ c: CanvasContext, _ r: CanvasRect) {
        c.fillRoundedRect(r, radius: 8, popoverBackground)
        c.strokeRoundedRect(r.insetBy(0.5), radius: 7.5, popoverBorder, width: 1)
    }

    /// Popover placed `bottom-full right-0 mb-*` relative to its trigger.
    public static func anchorAbove(trigger: CanvasRect, size: CanvasSize, gap: Double) -> CanvasRect {
        CanvasRect(x: trigger.maxX - size.width, y: trigger.y - gap - size.height, width: size.width, height: size.height)
    }
}

public extension CanvasRect {
    func contains(_ p: CanvasPoint) -> Bool { p.x >= x && p.x < maxX && p.y >= y && p.y < maxY }
}
