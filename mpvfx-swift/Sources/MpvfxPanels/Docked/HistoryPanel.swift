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

/// The History panel (dock id `history`): every undo and redo entry of the timeline editor by label and time, oldest
/// first, with the current state marked. A click steps to that state with the editor's own `undo()` / `redo()`, so
/// each step is a normal document change (the host saves it) and the redo entries stay available.
public final class HistoryPanel: DockedPanelView {
    /// One row: the state after an edit (row 0 is the state before the first one).
    public struct Row: Equatable {
        public enum Kind: Equatable { case initial, done, undone }
        public var label: String
        public var time: Double?
        public var kind: Kind
    }

    public var editor: TimelineEditor?
    /// After a jump changed the document (the host saves and redraws through the editor's own hooks).
    public var onJump: (() -> Void)?
    /// Seconds-since-1970 to label text; the default is local `HH:mm:ss`. Tests inject a fixed zone.
    public var timeText: (Double) -> String = HistoryPanel.localClock
    public private(set) var list = PanelRowList(rowHeight: 26)
    public private(set) var hovered: Int?

    public init() {}

    /// Initial state, then the undo entries oldest first, then the redo entries nearest first.
    public var rows: [Row] {
        guard let editor else { return [] }
        var out = [Row(label: "Original", time: nil, kind: .initial)]
        out += editor.undoStack.map { Row(label: $0.label, time: $0.time, kind: .done) }
        out += editor.redoStack.reversed().map { Row(label: $0.label, time: $0.time, kind: .undone) }
        return out
    }

    /// The row of the state the document is in.
    public var currentRow: Int { editor?.undoStack.count ?? 0 }

    /// Steps the editor to the state of `row`; false when the row does not exist or a step fails.
    @discardableResult
    public func jump(to row: Int) -> Bool {
        guard let editor, (0..<rows.count).contains(row) else { return false }
        let steps = row - currentRow
        guard steps != 0 else { return true }
        for _ in 0..<abs(steps) {
            guard steps < 0 ? editor.undo() : editor.redo() else { onJump?(); return false }
        }
        onJump?()
        return true
    }

    public static func localClock(_ t: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    // MARK: Drawing

    public func draw(_ c: CanvasContext, size: CanvasSize) {
        DockedPanelDraw.background(c, size: size)
        let rows = self.rows
        list.layout(viewport: CanvasRect(x: 0, y: 0, width: size.width, height: size.height), count: rows.count)
        guard rows.count > 1 else {
            DockedPanelDraw.empty(c, size: size, title: "No edits yet", detail: "Every edit you make is listed here.")
            return
        }
        c.save()
        c.clip(list.viewport)
        for i in list.visibleRows {
            let r = list.rect(of: i), row = rows[i]
            DockedPanelDraw.rowFill(c, r, selected: i == currentRow, hovered: i == hovered)
            let dim = row.kind == .undone
            let textColor = dim ? PanelTheme.text4 : (i == currentRow ? PanelTheme.text0 : PanelTheme.text2)
            let time = row.time.map(timeText) ?? ""
            let timeW = time.isEmpty ? 0 : 64.0
            PanelDraw.text(c, row.label, in: CanvasRect(x: r.x + 12, y: r.y, width: max(0, r.width - 24 - timeW), height: r.height),
                           font: PanelTheme.font(12, i == currentRow ? .medium : .regular), color: textColor)
            if !time.isEmpty {
                PanelDraw.text(c, time, in: CanvasRect(x: r.maxX - 12 - timeW, y: r.y, width: timeW, height: r.height),
                               font: PanelTheme.mono(10), color: PanelTheme.text4, align: .right)
            }
        }
        c.restore()
        PanelScrollbar.draw(c, track: list.viewport, offset: list.scrollY, content: list.contentHeight, hovered: false)
    }

    // MARK: Input

    public func pointerDown(_ p: CanvasPoint, shift: Bool) -> Bool {
        guard rows.count > 1, let row = list.row(at: p) else { return false }
        jump(to: row)
        return true
    }

    public func pointerMove(_ p: CanvasPoint) -> Bool {
        let next = list.row(at: p)
        defer { hovered = next }
        return next != hovered
    }

    public func scroll(dy: Double) -> Bool { list.scroll(by: dy) }

    /// Up / Down step one state back or forward (when this panel has the keys).
    public func keyDown(_ k: EditorKey) -> Bool {
        switch k.code {
        case .up where !k.command: return jump(to: max(0, currentRow - 1))
        case .down where !k.command: return jump(to: min(rows.count - 1, currentRow + 1))
        default: return false
        }
    }

    public var hint: String? { "Click an entry to go back or forward to that state" }
}
