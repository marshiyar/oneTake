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
import MpvfxShared
import MpvfxTimeline

/// The sequence's markers. Click/Enter jumps, double-click/F2 edits; Tab chooses a field, Enter commits.
public final class MarkersPanel: DockedPanelView {
    public var editor: TimelineEditor?
    public var onJump: ((Double) -> Void)?
    public var now: () -> Double = { Date().timeIntervalSinceReferenceDate }
    public private(set) var list = PanelRowList(rowHeight: 44)
    public private(set) var selectedID: String?
    public private(set) var editingID: String?
    public private(set) var field = 0
    public private(set) var fields: [String] = []
    private var replaceText = false
    private var lastPress: (String, Double)?
    public init() {}
    public var rows: [NativeSequenceMarker] {
        (editor?.document.sequence.markers ?? []).sorted { $0.time < $1.time }
    }
    public func beginEditing(_ id: String) -> Bool {
        guard let marker = rows.first(where: { $0.id == id }) else { return false }
        selectedID = id; editingID = id; field = 0
        fields = [marker.name, String(marker.time), marker.color, marker.note]; replaceText = true
        return true
    }
    @discardableResult public func commitEditing() -> Bool {
        guard let id = editingID, let time = Double(fields[1]), let editor else { return false }
        guard var marker = rows.first(where: { $0.id == id }) else { editingID = nil; return false }
        marker.time = time; marker.name = fields[0]; marker.color = fields[2]; marker.note = fields[3]
        guard editor.updateMarker(marker) || rows.contains(marker) else { return false }
        editingID = nil; return true
    }
    public func draw(_ c: CanvasContext, size: CanvasSize) {
        DockedPanelDraw.background(c, size: size)
        let rows = self.rows
        if let id = editingID, !rows.contains(where: { $0.id == id }) { editingID = nil }
        list.layout(viewport: CanvasRect(x: 0, y: 0, width: size.width, height: size.height), count: rows.count)
        guard !rows.isEmpty else {
            DockedPanelDraw.empty(c, size: size, title: "No markers", detail: "Press M at the playhead to add a marker."); return
        }
        c.withState {
            c.clip(list.viewport)
            for i in list.visibleRows {
                let r = list.rect(of: i), marker = rows[i]
                DockedPanelDraw.rowFill(c, r, selected: selectedID == marker.id, hovered: false)
                c.fillRect(CanvasRect(x: 6, y: r.y + 8, width: 4, height: 28), .documentColor(marker.color))
                let editing = editingID == marker.id
                let label = editing ? "\(["Name", "Time (seconds)", "Color", "Note"][field]): \(fields[field]) ▏" : marker.name
                PanelDraw.text(c, label, in: CanvasRect(x: 16, y: r.y, width: max(0, r.width - 24), height: 24), font: PanelTheme.font(12), color: PanelTheme.text0)
                let detail = editing ? "Tab: field · Enter: save · Esc: cancel" : String(format: "%.3f s", marker.time) + (marker.note.isEmpty ? "" : " · " + marker.note)
                PanelDraw.text(c, detail, in: CanvasRect(x: 16, y: r.y + 24, width: max(0, r.width - 24), height: 18), font: PanelTheme.font(10), color: PanelTheme.text4)
            }
        }
        PanelScrollbar.draw(c, track: list.viewport, offset: list.scrollY, content: list.contentHeight, hovered: false)
    }
    public func pointerDown(_ p: CanvasPoint, shift: Bool) -> Bool {
        guard let row = list.row(at: p), rows.indices.contains(row) else { return false }
        let marker = rows[row], time = now()
        selectedID = marker.id
        if let last = lastPress, last.0 == marker.id, time >= last.1, time - last.1 <= 0.4 {
            lastPress = nil; return beginEditing(marker.id)
        }
        lastPress = (marker.id, time); editingID = nil; onJump?(marker.time); return true
    }
    public func scroll(dy: Double) -> Bool { list.scroll(by: dy) }
    public func keyDown(_ k: EditorKey) -> Bool {
        if editingID != nil {
            switch k.code {
            case .escape: editingID = nil
            case .enter: _ = commitEditing()
            case .tab: field = (field + (k.shift ? 3 : 1)) % 4; replaceText = true
            case .backspace, .delete:
                if replaceText { fields[field] = "" } else if !fields[field].isEmpty { fields[field].removeLast() }; replaceText = false
            case .char(let ch) where !k.command && !k.alt:
                if replaceText { fields[field] = "" }; fields[field].append(ch); replaceText = false
            case .space:
                if replaceText { fields[field] = "" }; fields[field].append(" "); replaceText = false
            default: break
            }
            return true // Text editing must never fall through to global M/Delete/undo shortcuts.
        }
        guard !k.command && !k.alt else { return false }
        let rows = self.rows
        switch k.code {
        case .up, .down:
            guard !rows.isEmpty else { return true }
            let old = rows.firstIndex(where: { $0.id == selectedID }) ?? (k.code == .down ? -1 : rows.count)
            let i = max(0, min(rows.count - 1, old + (k.code == .down ? 1 : -1)))
            selectedID = rows[i].id; list.reveal(i); onJump?(rows[i].time); return true
        case .enter:
            guard let marker = rows.first(where: { $0.id == selectedID }) else { return false }
            onJump?(marker.time); return true
        case .function(2): return selectedID.map(beginEditing) ?? false
        case .delete, .backspace:
            guard let id = selectedID else { return true }
            _ = editor?.deleteMarker(id); selectedID = nil; return true
        default: return false
        }
    }
    public var hint: String? { "M: add marker · Click: jump · Double-click / F2: edit · Delete: remove" }
}
