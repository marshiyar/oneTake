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

/// What the shell needs from a docked panel's content: one pane's drawing and input in pane-local coordinates.
/// Every method that handles an event returns true when the pane changed and must be redrawn.
public protocol DockedPanelView: AnyObject {
    func draw(_ c: CanvasContext, size: CanvasSize)
    func pointerDown(_ p: CanvasPoint, shift: Bool) -> Bool
    func pointerMove(_ p: CanvasPoint) -> Bool
    func pointerUp(_ p: CanvasPoint) -> Bool
    func scroll(dy: Double) -> Bool
    func keyDown(_ k: EditorKey) -> Bool
    /// The status line's text for what is under the pointer.
    var hint: String? { get }
}

public extension DockedPanelView {
    func pointerMove(_ p: CanvasPoint) -> Bool { false }
    func pointerUp(_ p: CanvasPoint) -> Bool { false }
    func scroll(dy: Double) -> Bool { false }
    func keyDown(_ k: EditorKey) -> Bool { false }
    var hint: String? { nil }
}

/// A vertical list of equal rows inside a viewport: the scroll offset, the row under a point, and what is visible.
/// Shared by the History, Markers, Effects and Info panels.
public struct PanelRowList: Equatable {
    public var rowHeight = 26.0
    public private(set) var scrollY = 0.0
    public private(set) var viewport = CanvasRect(x: 0, y: 0, width: 0, height: 0)
    public private(set) var count = 0

    public init(rowHeight: Double = 26) { self.rowHeight = rowHeight }

    public var contentHeight: Double { Double(count) * rowHeight }

    /// Sets the viewport and row count for this draw; keeps the offset within the content.
    public mutating func layout(viewport: CanvasRect, count: Int) {
        self.viewport = viewport
        self.count = max(0, count)
        scrollY = clamped(scrollY)
    }

    private func clamped(_ y: Double) -> Double {
        guard y.isFinite else { return 0 }
        return min(max(0, y), max(0, contentHeight - viewport.height))
    }

    /// Scrolls by `dy` points (positive: down). True when the offset moved.
    @discardableResult
    public mutating func scroll(by dy: Double) -> Bool {
        let next = clamped(scrollY + dy)
        defer { scrollY = next }
        return next != scrollY
    }

    /// The row's rectangle in pane coordinates (may lie outside the viewport).
    public func rect(of row: Int) -> CanvasRect {
        CanvasRect(x: viewport.x, y: viewport.y + Double(row) * rowHeight - scrollY, width: viewport.width, height: rowHeight)
    }

    /// The row under a pane point, nil outside the viewport or past the last row.
    public func row(at p: CanvasPoint) -> Int? {
        guard viewport.contains(p) else { return nil }
        let i = Int(((p.y - viewport.y + scrollY) / rowHeight).rounded(.down))
        return (0..<count).contains(i) ? i : nil
    }

    /// The rows that touch the viewport.
    public var visibleRows: Range<Int> {
        guard count > 0, rowHeight > 0 else { return 0..<0 }
        let first = max(0, Int((scrollY / rowHeight).rounded(.down)))
        let last = min(count, Int(((scrollY + viewport.height) / rowHeight).rounded(.up)))
        return first..<max(first, last)
    }

    /// Scrolls the least that shows `row` entirely.
    public mutating func reveal(_ row: Int) {
        guard (0..<count).contains(row) else { return }
        let top = Double(row) * rowHeight
        if top < scrollY { scrollY = clamped(top) }
        else if top + rowHeight > scrollY + viewport.height { scrollY = clamped(top + rowHeight - viewport.height) }
    }
}

/// Shared look of the docked list panels.
enum DockedPanelDraw {
    static func background(_ c: CanvasContext, size: CanvasSize) {
        c.fillRect(CanvasRect(x: 0, y: 0, width: size.width, height: size.height), PanelTheme.panelBg)
    }

    /// A centred two-line note for an empty panel.
    static func empty(_ c: CanvasContext, size: CanvasSize, title: String, detail: String) {
        let w = max(0, size.width - 24)
        PanelDraw.text(c, title, in: CanvasRect(x: 12, y: 16, width: w, height: 18), font: PanelTheme.font(12, .medium), color: PanelTheme.text2)
        PanelDraw.text(c, detail, in: CanvasRect(x: 12, y: 36, width: w, height: 16), font: PanelTheme.font(11), color: PanelTheme.text4)
    }

    static func rowFill(_ c: CanvasContext, _ r: CanvasRect, selected: Bool, hovered: Bool) {
        if selected { c.fillRect(r, PanelTheme.accent.withAlpha(0.22)) }
        else if hovered { c.fillRect(r, PanelTheme.panelHover) }
    }
}
