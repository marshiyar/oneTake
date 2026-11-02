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
import MpvfxPanels
import MpvfxShared
import MpvfxTimeline

public struct StageLayoutMenu: Equatable {
    public static let width = 232.0, rowHeight = 44.0, footerHeight = 44.0, pad = 4.0, step = 4.0, maxSpace = 200.0
    public static let layouts = NativeGridLayout.allCases

    public var origin: CanvasPoint
    /// The row the keyboard is on (and the one a Return applies).
    public var selected = 0
    public var gutter = 0.0, margin = 0.0
    /// How many clips are selected: rows that take fewer cells than that are shown disabled.
    public var clipCount: Int

    public init(origin: CanvasPoint, clipCount: Int) { self.origin = origin; self.clipCount = clipCount }

    public static func label(_ layout: NativeGridLayout) -> String {
        switch layout {
        case .sideBySide: "Side by side"
        case .stacked: "Stacked"
        case .threeUp: "Three up"
        case .grid2x2: "2 × 2 grid"
        case .largeLeft: "Large left"
        case .pictureInPicture: "Picture in picture"
        }
    }

    /// How many clips the layout takes.
    public static func cells(_ layout: NativeGridLayout) -> Int {
        switch layout {
        case .sideBySide, .stacked, .pictureInPicture: 2
        case .threeUp, .largeLeft: 3
        case .grid2x2: 4
        }
    }

    public var layout: NativeGridLayout { Self.layouts[selected] }
    public var options: NativeGridOptions { NativeGridOptions(gutter: gutter, margin: margin) }
    /// A layout can take the selection when it has a cell for every selected clip.
    public func isEnabled(_ layout: NativeGridLayout) -> Bool { clipCount >= 1 && Self.cells(layout) >= clipCount }

    public var height: Double { 2 + 2 * Self.pad + Double(Self.layouts.count) * Self.rowHeight + Self.footerHeight }

    /// Clamped inside `bounds`.
    public func frame(in bounds: CanvasRect) -> CanvasRect {
        CanvasRect(x: max(bounds.x + 4, min(origin.x, bounds.maxX - Self.width - 4)),
                   y: max(bounds.y + 4, min(origin.y, bounds.maxY - height - 4)), width: Self.width, height: height)
    }
    public func rowRect(_ index: Int, in frame: CanvasRect) -> CanvasRect {
        CanvasRect(x: frame.x + 1, y: frame.y + 1 + Self.pad + Double(index) * Self.rowHeight, width: frame.width - 2, height: Self.rowHeight)
    }
    public func footerRect(in frame: CanvasRect) -> CanvasRect {
        CanvasRect(x: frame.x + 1, y: frame.maxY - 1 - Self.footerHeight, width: frame.width - 2, height: Self.footerHeight)
    }

    public enum Hit: Equatable { case row(Int), footer, outside }
    public func hit(at p: CanvasPoint, bounds: CanvasRect) -> Hit {
        let f = frame(in: bounds)
        guard f.contains(p) else { return .outside }
        for index in Self.layouts.indices where rowRect(index, in: f).contains(p) { return .row(index) }
        return .footer
    }

    public enum KeyResult: Equatable { case none, handled, close, apply(NativeGridLayout, NativeGridOptions) }
    /// The menu's keys. Disabled rows are skipped by Up and Down and refuse Return.
    public mutating func key(_ code: EditorKey.Code, shift: Bool) -> KeyResult {
        switch code {
        case .escape: return .close
        case .enter:
            return isEnabled(layout) ? .apply(layout, options) : .handled
        case .up, .down:
            let enabled = Self.layouts.indices.filter { isEnabled(Self.layouts[$0]) }
            guard !enabled.isEmpty else { return .handled }
            if let at = enabled.firstIndex(of: selected) {
                selected = enabled[(at + (code == .down ? 1 : enabled.count - 1)) % enabled.count]
            } else { selected = code == .down ? enabled[0] : enabled[enabled.count - 1] }
            return .handled
        case .left, .right:
            let delta = code == .right ? Self.step : -Self.step
            if shift { margin = min(Self.maxSpace, max(0, margin + delta)) } else { gutter = min(Self.maxSpace, max(0, gutter + delta)) }
            return .handled
        case .char(let ch):
            guard let n = Int(String(ch)), Self.layouts.indices.contains(n - 1) else { return .none }
            selected = n - 1
            return .handled
        default: return .none
        }
    }

    /// The corner a picture in picture moves to when ⌥ and an arrow key are pressed: the arrow picks the side, so a
    /// press toward the side it is already on changes nothing.
    public static func corner(_ corner: NativeGridCorner, moving key: EditorKey.Code) -> NativeGridCorner {
        var right = corner == .topRight || corner == .bottomRight
        var bottom = corner == .bottomLeft || corner == .bottomRight
        switch key {
        case .left: right = false
        case .right: right = true
        case .up: bottom = false
        case .down: bottom = true
        default: break
        }
        switch (right, bottom) {
        case (false, false): return .topLeft
        case (true, false): return .topRight
        case (false, true): return .bottomLeft
        case (true, true): return .bottomRight
        }
    }

    /// The clips with their cells moved one step: the first one's cell goes to the next clip (forward) or the last one's
    /// to the first (backward). With two clips both steps swap them.
    public static func rotated(_ ids: [String], forward: Bool) -> [String] {
        guard ids.count > 1 else { return ids }
        return forward ? [ids[ids.count - 1]] + ids.dropLast() : Array(ids.dropFirst()) + [ids[0]]
    }

    /// The cells of `layout` in a 16:9 diagram `size` wide, as rects inside it (the gutter and margin scaled to it).
    public func diagram(_ layout: NativeGridLayout, size: CanvasSize) -> [CanvasRect] {
        let scale = size.width / 160
        let o = NativeGridOptions(gutter: max(2, gutter * scale / 4), margin: max(2, margin * scale / 4))
        guard let cells = try? nativeGridCells(layout, width: size.width, height: size.height, options: o) else { return [] }
        return cells.map { CanvasRect(x: $0.left, y: $0.top, width: $0.width, height: $0.height) }
    }

    public func draw(_ c: CanvasContext, bounds: CanvasRect) {
        let f = frame(in: bounds)
        c.fillRoundedRect(f, radius: 6, PanelStyle.neutral900)
        c.strokeRoundedRect(f.insetBy(0.5), radius: 5.5, PanelStyle.neutral700, width: 1)
        let font = CanvasFont(size: 12), small = CanvasFont(size: 10)
        for (index, layout) in Self.layouts.enumerated() {
            let r = rowRect(index, in: f), on = isEnabled(layout)
            if index == selected { c.fillRect(r, PanelStyle.neutral800) }
            let ink = on ? PanelStyle.neutral300 : PanelStyle.neutral600
            let box = CanvasRect(x: r.x + 10, y: r.y + 6, width: 56, height: 32)
            c.strokeRoundedRect(box.insetBy(0.5), radius: 2, PanelStyle.neutral700, width: 1)
            for cell in diagram(layout, size: CanvasSize(box.width, box.height)) {
                c.fillRect(CanvasRect(x: box.x + cell.x, y: box.y + cell.y, width: cell.width, height: cell.height), ink.withAlpha(0.55))
            }
            c.drawText(Self.label(layout), at: CanvasPoint(box.maxX + 10, r.y + 8), font: font, color: ink)
            let count = "\(Self.cells(layout)) clips"
            c.drawText(count, at: CanvasPoint(box.maxX + 10, r.y + 24), font: small, color: PanelStyle.neutral500)
        }
        let foot = footerRect(in: f)
        c.fillRect(CanvasRect(x: foot.x, y: foot.y, width: foot.width, height: 1), PanelStyle.neutral700.withAlpha(0.6))
        c.drawText("Gutter \(Int(gutter)) px   ←  →", at: CanvasPoint(foot.x + 12, foot.y + 8), font: small, color: PanelStyle.neutral300)
        c.drawText("Margin \(Int(margin)) px   ⇧← ⇧→", at: CanvasPoint(foot.x + 12, foot.y + 24), font: small, color: PanelStyle.neutral300)
    }
}
