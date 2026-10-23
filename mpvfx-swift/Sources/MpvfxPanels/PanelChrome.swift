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

/// The strip across the top of a side panel (docs/DESIGN.md, rollout step 2): the tabs (`PanelTabBar`, `.strip`)
/// from the left inset, the panel's buttons at the right end with the panel menu button last. A hairline closes the
/// strip.
public enum PanelTabStrip {
    public static let height = 32.0
    /// The strip's square icon buttons (hide, panel menu) and the Import media button's height.
    public static let buttonSize = 24.0
    static let tabPadding = 10.0, underline = 2.0, edgeInset = 4.0, buttonGap = 2.0
    static var font: CanvasFont { PanelTheme.font(PanelTheme.textXs, .medium) }

    public static func drawBackground(_ c: CanvasContext, _ r: CanvasRect) {
        c.fillRect(r, PanelTheme.panelBg)
        PanelDraw.hline(c, x0: r.x, x1: r.maxX, y: r.maxY - 1, PanelTheme.panelHairline)
    }

    public static func tabWidth(_ c: CanvasContext, _ label: String) -> Double {
        c.measureText(label, font: font).width + tabPadding * 2
    }
    /// One tab; `r` spans the strip's height, so the underline covers the hairline under the active tab.
    public static func tab(_ c: CanvasContext, _ r: CanvasRect, label: String, active: Bool, hovered: Bool) {
        let color = active ? PanelTheme.text0 : (hovered ? PanelTheme.text1 : PanelTheme.text3)
        PanelDraw.text(c, label, in: CanvasRect(x: r.x, y: r.y, width: r.width, height: r.height - 1), font: font, color: color, align: .center)
        if active { c.fillRect(CanvasRect(x: r.x, y: r.maxY - underline, width: r.width, height: underline), PanelTheme.accent) }
    }
    /// The tabs laid left to right from the strip's left edge.
    public static func tabRects(_ c: CanvasContext, _ strip: CanvasRect, labels: [String]) -> [CanvasRect] {
        var x = strip.x + edgeInset
        return labels.map { label in
            let r = CanvasRect(x: x, y: strip.y, width: tabWidth(c, label), height: strip.height)
            x = r.maxX
            return r
        }
    }
    /// The `index`th icon button from the strip's right end (0 is the panel menu button).
    public static func buttonRect(_ strip: CanvasRect, index: Int) -> CanvasRect {
        let x = strip.maxX - edgeInset - buttonSize - Double(index) * (buttonSize + buttonGap)
        return CanvasRect(x: x, y: strip.y + (height - buttonSize) / 2, width: buttonSize, height: buttonSize)
    }

    /// A strip icon button: the hover wash, the glyph muted at rest and in full ink on hover or while its menu is open.
    public static func iconButton(_ c: CanvasContext, _ r: CanvasRect, icon: PanelIcon, hovered: Bool, open: Bool = false) {
        let lit = hovered || open
        if lit { c.fillRoundedRect(r, radius: PanelTheme.radius, PanelTheme.panelHover) }
        let s = 14.0
        icon.draw(c, in: CanvasRect(x: r.midX - s / 2, y: r.midY - s / 2, width: s, height: s), color: lit ? PanelTheme.text1 : PanelTheme.text3)
    }

    /// A collapsed panel: the 40px rail with its show button where the strip's buttons sit.
    public static func drawRail(_ c: CanvasContext, _ r: CanvasRect, icon: PanelIcon, hovered: Bool) -> CanvasRect {
        c.fillRect(r, PanelTheme.panelBg)
        let b = CanvasRect(x: r.x + (r.width - buttonSize) / 2, y: r.y + (height - buttonSize) / 2, width: buttonSize, height: buttonSize)
        iconButton(c, b, icon: icon, hovered: hovered)
        return b
    }
}

/// The status line along the bottom of the editor window: one line of hint text for what is under the pointer,
/// 11px muted ink on the panel grey.
public enum ShellStatusLine {
    public static let height = 22.0

    public static func draw(_ c: CanvasContext, _ r: CanvasRect, hint: String?, error: String? = nil) {
        guard r.width > 0, r.height > 0 else { return }
        c.fillRect(r, PanelTheme.panelBg)
        guard let text = error ?? hint, !text.isEmpty else { return }
        PanelDraw.text(c, text, in: CanvasRect(x: r.x + 8, y: r.y, width: max(0, r.width - 16), height: r.height),
                       font: PanelTheme.font(11), color: error == nil ? PanelTheme.text2 : PanelTheme.danger)
    }
}
