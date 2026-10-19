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

/// Speed menu: "1x" trigger (h-7 w-8, mono 10px) and a radio menu of 0.25/0.5/1/1.5/2 opening above it.
public final class SpeedPopover {
    public static let options: [Double] = [0.25, 0.5, 1, 1.5, 2]
    public static let triggerSize = CanvasSize(32, 28)
    public static let itemHeight = 28.0, menuWidth = 56.0, gap = 6.0

    public var playbackRate: Double = 1
    public var isOpen = false
    public var disabled = false
    public var hoveredIndex: Int?
    public var onRateChange: ((Double) -> Void)?

    public init(playbackRate: Double = 1) { self.playbackRate = playbackRate }

    public static func label(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))x" : "\(rate)x"
    }

    public func menuRect(trigger: CanvasRect) -> CanvasRect {
        PanelStyle.anchorAbove(trigger: trigger, size: CanvasSize(Self.menuWidth, Self.itemHeight * Double(Self.options.count)), gap: Self.gap)
    }

    public func itemIndex(at p: CanvasPoint, trigger: CanvasRect) -> Int? {
        guard isOpen else { return nil }
        let m = menuRect(trigger: trigger)
        guard m.contains(p) else { return nil }
        return min(Self.options.count - 1, Int((p.y - m.y) / Self.itemHeight))
    }

    /// Pointer down. Returns true when consumed (trigger toggles; item selects and closes; outside closes).
    @discardableResult
    public func pointerDown(_ p: CanvasPoint, trigger: CanvasRect) -> Bool {
        if trigger.contains(p) { if !disabled { isOpen.toggle() }; return true }
        if let i = itemIndex(at: p, trigger: trigger) {
            playbackRate = Self.options[i]; isOpen = false; onRateChange?(playbackRate); return true
        }
        if isOpen { isOpen = false; return true }
        return false
    }

    public func pointerMove(_ p: CanvasPoint, trigger: CanvasRect) { hoveredIndex = itemIndex(at: p, trigger: trigger) }

    /// Escape dismisses (useContextMenuDismiss).
    public func escape() -> Bool { guard isOpen else { return false }; isOpen = false; return true }

    public func draw(_ c: CanvasContext, trigger: CanvasRect, triggerHovered: Bool = false) {
        let font = CanvasFont.mono(10)
        let text = Self.label(playbackRate)
        let textSize = c.measureText(text, font: font)
        let color = disabled ? PanelStyle.neutral500.withAlpha(0.3) : (triggerHovered ? PanelStyle.neutral200 : PanelStyle.neutral500)
        c.drawText(text, at: .init(trigger.x + (trigger.width - textSize.width) / 2, trigger.y + (trigger.height - textSize.height) / 2), font: font, color: color)
        guard isOpen else { return }
        let m = menuRect(trigger: trigger)
        PanelStyle.drawPopover(c, m)
        c.withState {
            c.clip(.roundedRect(m.insetBy(1), radius: 7))
            let itemFont = CanvasFont.mono(11)
            for (i, rate) in Self.options.enumerated() {
                let r = CanvasRect(x: m.x, y: m.y + Double(i) * Self.itemHeight, width: m.width, height: Self.itemHeight)
                let current = rate == playbackRate
                if current { c.fillRect(r, PanelStyle.menuItemCurrent) } else if hoveredIndex == i { c.fillRect(r, PanelStyle.menuItemHover) }
                let s = c.measureText(Self.label(rate), font: itemFont)
                c.drawText(Self.label(rate), at: .init(r.x + 12, r.y + (r.height - s.height) / 2), font: itemFont,
                           color: current ? PanelStyle.neutral50 : PanelStyle.neutral500)
            }
        }
    }
}
