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

/// A native select popover (the panels' select fields): opens under its field, lists options with
/// optional group headings, scrolls, hover-highlights, closes on pick / outside click / Escape.
public final class PanelDropdown {
    public struct Option: Equatable { public var value: String; public var label: String; public var group: String?
        public init(value: String, label: String, group: String? = nil) { self.value = value; self.label = label; self.group = group } }

    public private(set) var key: String?
    public private(set) var options: [Option] = []
    public private(set) var selected: String?
    /// Options shown with a checkmark besides the selected one (a menu of toggles, like the dock's panel list); set it
    /// before `open`; `close` clears it.
    public var checked: Set<String> = []
    var anchor = CanvasRect(x: 0, y: 0, width: 0, height: 0)
    var bounds = CanvasRect(x: 0, y: 0, width: 0, height: 0)
    var hovered: Int?
    var scroll = 0.0
    var onPick: ((String) -> Void)?
    public static let itemH = 24.0, headH = 20.0, maxH = 280.0

    public init() {}
    public var isOpen: Bool { key != nil }

    public func open(key: String, options: [Option], selected: String?, anchor: CanvasRect, bounds: CanvasRect, onPick: @escaping (String) -> Void) {
        self.key = key; self.options = options; self.selected = selected; self.anchor = anchor; self.bounds = bounds
        self.onPick = onPick; hovered = nil; scroll = 0
    }
    public func close() { key = nil; onPick = nil; checked = [] }
    /// Highlights the selected option, as a native list opened from the keyboard does: the arrows move from it and
    /// Enter keeps it. The list scrolls so the highlighted row shows.
    public func highlightSelected() {
        hovered = options.firstIndex { $0.value == selected }
        revealHovered()
    }

    /// Scrolls the least that puts the highlighted row inside the list (rows sit 4 pt inside its top and bottom).
    func revealHovered() {
        guard let hovered, let row = rows().first(where: { $0.index == hovered }) else { return }
        let visible = rect.height - 8
        if row.y < scroll { scroll = row.y }
        if row.y + row.h > scroll + visible { scroll = row.y + row.h - visible }
        scroll = max(0, min(max(0, contentHeight - rect.height), scroll))
    }
    /// Picks `value` as a click on its item would: closes, then reports it.
    public func pick(_ value: String) {
        guard isOpen, options.contains(where: { $0.value == value }) else { return }
        let p = onPick; close(); p?(value)
    }

    struct Row { var y: Double; var h: Double; var index: Int?; var heading: String? }
    func rows() -> [Row] {
        var out: [Row] = []; var y = 0.0; var group: String?
        for (i, o) in options.enumerated() {
            if let g = o.group, g != group { out.append(Row(y: y, h: Self.headH, index: nil, heading: g)); y += Self.headH; group = g }
            out.append(Row(y: y, h: Self.itemH, index: i, heading: nil)); y += Self.itemH
        }
        return out
    }
    var contentHeight: Double { (rows().last.map { $0.y + $0.h } ?? 0) + 8 }

    public var rect: CanvasRect {
        let h = min(Self.maxH, contentHeight)
        let w = max(anchor.width, 160)
        var y = anchor.maxY + 4
        if y + h > bounds.maxY - 4 { y = max(bounds.y + 4, anchor.y - 4 - h) }
        let x = min(max(bounds.x + 4, anchor.x), bounds.maxX - w - 4)
        return CanvasRect(x: x, y: y, width: w, height: h)
    }

    public func draw(_ c: CanvasContext) {
        guard isOpen else { return }
        let r = rect
        PanelStyle.drawPopover(c, r)
        c.withState {
            c.clip(r.insetBy(1))
            for row in rows() {
                let rr = CanvasRect(x: r.x + 4, y: r.y + 4 + row.y - scroll, width: r.width - 8, height: row.h)
                guard rr.maxY > r.y, rr.y < r.maxY else { continue }
                if let h = row.heading {
                    PanelDraw.text(c, h.uppercased(), in: CanvasRect(x: rr.x + 8, y: rr.y, width: rr.width - 8, height: rr.height),
                                   font: PanelTheme.font(9, .semibold), color: PanelTheme.text5)
                } else if let i = row.index {
                    let o = options[i]
                    if hovered == i { c.fillRoundedRect(rr, radius: PanelTheme.radius, PanelTheme.panelHover) }
                    else if o.value == selected { c.fillRoundedRect(rr, radius: PanelTheme.radius, PanelStyle.menuItemCurrent) }
                    PanelDraw.text(c, o.label, in: CanvasRect(x: rr.x + 8, y: rr.y, width: rr.width - 26, height: rr.height),
                                   font: PanelTheme.font(11), color: o.value == selected ? PanelTheme.text0 : PanelTheme.text1)
                    if o.value == selected || checked.contains(o.value) {
                        PanelIcon.check.draw(c, in: CanvasRect(x: rr.maxX - 16, y: rr.y + 6, width: 12, height: 12), color: PanelTheme.accent, lineWidth: 2)
                    }
                }
            }
        }
    }

    func index(at p: CanvasPoint) -> Int? {
        let r = rect
        guard r.contains(p) else { return nil }
        let y = p.y - r.y - 4 + scroll
        return rows().first { y >= $0.y && y < $0.y + $0.h }?.index
    }

    /// Returns true when consumed (always while open).
    public func pointerDown(_ p: CanvasPoint) -> Bool {
        guard isOpen else { return false }
        if let i = index(at: p) { let v = options[i].value; let pick = onPick; close(); pick?(v); return true }
        if !rect.contains(p) { close() }
        return true
    }
    public func pointerMove(_ p: CanvasPoint) -> Bool {
        guard isOpen else { return false }
        let h = index(at: p)
        guard h != hovered else { return false }
        hovered = h; return true
    }
    public func scrollBy(_ dy: Double) { scroll = max(0, min(max(0, contentHeight - rect.height), scroll + dy)) }   // host points, 1:1 like the native list
    public func key(_ k: EditorKey) -> Bool {
        guard isOpen else { return false }
        if options.isEmpty {   // nothing to highlight: the arrows do nothing, Enter closes without a pick
            if k.code == .escape || k.code == .enter { close() }
            return true
        }
        switch k.code {
        case .escape: close(); return true
        case .down: hovered = min(options.count - 1, (hovered ?? -1) + 1); revealHovered(); return true
        case .up: hovered = max(0, (hovered ?? options.count) - 1); revealHovered(); return true
        case .enter: if let h = hovered { let v = options[h].value; let pick = onPick; close(); pick?(v) }; return true
        default: return true
        }
    }
}


/// The select control look: `h-7 px-2 text-[11px] bg-panel-input rounded-md text-panel-text-1`, hover panel-hover.
public enum PanelSelect {
    public static func draw(_ c: CanvasContext, _ r: CanvasRect, text: String, hovered: Bool, disabled: Bool = false,
                            fill: CanvasColor = PanelTheme.panelInput, font: CanvasFont = PanelTheme.font(11), color: CanvasColor = PanelTheme.text1) {
        c.fillRoundedRect(r, radius: PanelTheme.radiusMd, hovered && !disabled ? PanelTheme.panelHover : fill)
        PanelDraw.text(c, text, in: CanvasRect(x: r.x + 8, y: r.y, width: r.width - 26, height: r.height), font: font,
                       color: disabled ? color.withAlpha(0.5) : color)
        PanelIcon.selectCaret.draw(c, in: CanvasRect(x: r.maxX - 16, y: r.y + (r.height - 10) / 2, width: 10, height: 10), color: PanelTheme.text4)
    }
}
