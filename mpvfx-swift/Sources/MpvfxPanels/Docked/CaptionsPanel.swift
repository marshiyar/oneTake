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
import MpvfxTheme
import MpvfxTimeline

/// The caption list (docs/TIMELINE.md "Caption list"): every cue as a row with its in and out time and its text, for fast
/// correction from the keyboard.
///
/// ↑/↓ move between cues and put the playhead on the cue; Enter edits the text in place (Enter saves, ⇧Enter adds a line,
/// Esc cancels); ⌥[ nudges the in point one frame earlier and ⌥] the out point one frame later (add ⇧ to go the other way);
/// ⌘Enter splits the cue at the text caret and the playhead; ⌘J joins it with the next cue. ⌘F opens find, ⌥⌘F find and
/// replace (Tab switches field, Enter finds the next cue, ⌥C toggles case-sensitive, ⌥⌘Enter replaces all in one undo step).
/// A row read faster than the reading-rate limit shows a badge.
public final class CaptionsPanel: DockedPanelView {
    public var editor: TimelineEditor?
    /// Puts the playhead at a time in seconds.
    public var onJump: ((Double) -> Void)?
    /// The playhead in milliseconds, where a split cuts.
    public var playheadMs: () -> Int = { 0 }
    /// Characters per second above which a row is badged (Settings; the editor's choice, not a standard).
    public var readingRateLimit = NATIVE_CAPTION_READING_RATE_DEFAULT
    public var now: () -> Double = { Date().timeIntervalSinceReferenceDate }
    public private(set) var list = PanelRowList(rowHeight: 44)
    public private(set) var selectedID: String?
    public private(set) var editingID: String?
    /// The text being edited and the caret in it (a character offset).
    public private(set) var draft = ""
    public private(set) var caret = 0
    private var lastPress: (String, Double)?

    /// Find and replace.
    public private(set) var findOpen = false
    public private(set) var replaceOpen = false
    public private(set) var findText = ""
    public private(set) var replaceText = ""
    public private(set) var caseSensitive = false
    /// 0 types in the find field, 1 in the replace field.
    public private(set) var findField = 0
    /// What the last Replace all did, shown under the fields.
    public private(set) var status: String?
    private static let barRowHeight = 26.0
    private var caseRect = CanvasRect(x: 0, y: 0, width: 0, height: 0)
    private var replaceAllRect = CanvasRect(x: 0, y: 0, width: 0, height: 0)

    public init() {}

    public var rows: [NativeCaptionCue] { editor?.captionCues ?? [] }

    /// The cues that hold the find text, with their match counts.
    public var matches: [(cueId: String, count: Int)] {
        guard findOpen, let track = editor?.document.sequence.captions else { return [] }
        return findCaptionMatches(track, find: findText, caseSensitive: caseSensitive)
    }

    // MARK: Text editing

    @discardableResult public func beginEditing(_ id: String) -> Bool {
        guard let cue = rows.first(where: { $0.id == id }) else { return false }
        selectedID = id; editingID = id; draft = cue.text; caret = cue.text.count
        return true
    }

    @discardableResult public func commitEditing() -> Bool {
        guard let id = editingID, let editor else { return false }
        if nativeCaptionTextProblem(draft) != nil { return false }   // stays open: the row names the problem
        editingID = nil
        _ = editor.setCaptionText(id, to: draft)
        return true
    }

    private func insert(_ text: String) {
        var chars = Array(draft)
        chars.insert(contentsOf: text, at: min(caret, chars.count))
        draft = String(chars); caret = min(caret, chars.count) + text.count
    }

    // MARK: Cue actions

    private func select(_ cue: NativeCaptionCue, jump: Bool = true) {
        selectedID = cue.id
        if jump { onJump?(Double(cue.startMs) / 1000) }
        if let i = rows.firstIndex(where: { $0.id == cue.id }) { list.reveal(i) }
    }

    /// Moves the selection by `step` cues and puts the playhead on the new one.
    @discardableResult public func moveSelection(_ step: Int) -> Bool {
        let rows = self.rows
        guard !rows.isEmpty else { return true }
        let old = rows.firstIndex(where: { $0.id == selectedID }) ?? (step > 0 ? -1 : rows.count)
        select(rows[max(0, min(rows.count - 1, old + step))])
        return true
    }

    /// ⌥[ and ⌥]: one frame on an end of the selected cue.
    @discardableResult public func nudge(_ edge: NativeCaptionEdge, frames: Int) -> Bool {
        guard let id = selectedID else { return false }
        return editor?.nudgeCaptionCue(id, edge: edge, byFrames: frames) ?? false
    }

    /// ⌘Enter: splits the selected cue at the playhead and at the caret. Without an open text edit there is no caret, so the
    /// cue breaks at the space nearest to the playhead's share of the cue's length.
    @discardableResult public func splitAtPlayhead() -> Bool {
        guard let id = selectedID, let editor, let cue = rows.first(where: { $0.id == id }) else { return false }
        let at = playheadMs()
        if editingID == id {
            guard let newId = editor.splitCaptionCue(id, atMs: at, caret: caret, text: draft) else { return false }
            editingID = nil; select(rows.first { $0.id == newId } ?? cue, jump: false); return true
        }
        let share = Double(at - cue.startMs) / Double(max(1, cue.endMs - cue.startMs))
        let chars = Array(cue.text)
        let wanted = Int((share * Double(chars.count)).rounded())
        let spaces = chars.indices.filter { chars[$0] == " " || chars[$0] == "\n" }
        let cut = spaces.min { abs($0 - wanted) < abs($1 - wanted) } ?? wanted
        guard let newId = editor.splitCaptionCue(id, atMs: at, caret: cut) else { return false }
        select(rows.first { $0.id == newId } ?? cue, jump: false)
        return true
    }

    /// ⌘J: joins the selected cue with the next.
    @discardableResult public func joinWithNext() -> Bool {
        guard let id = selectedID else { return false }
        editingID = nil
        return editor?.joinCaptionCue(id) ?? false
    }

    // MARK: Find and replace

    public func openFind(replace: Bool) {
        findOpen = true; replaceOpen = replace; findField = 0; status = nil
        if !replace { replaceText = "" }
    }

    public func closeFind() { findOpen = false; replaceOpen = false; status = nil }

    public func toggleCaseSensitive() { caseSensitive.toggle() }

    /// Selects the next cue after the selected one that holds the find text, wrapping round.
    @discardableResult public func findNext() -> Bool {
        let hits = Set(matches.map(\.cueId))
        let rows = self.rows
        guard !hits.isEmpty, !rows.isEmpty else { return false }
        let start = rows.firstIndex { $0.id == selectedID } ?? -1
        for step in 1...rows.count {
            let cue = rows[(start + step + rows.count) % rows.count]
            if hits.contains(cue.id) { select(cue); return true }
        }
        return false
    }

    /// Replaces in every cue in one undo step.
    @discardableResult public func replaceAll() -> Bool {
        guard let result = editor?.replaceAllCaptions(find: findText, with: replaceText, caseSensitive: caseSensitive) else {
            status = findText.isEmpty ? nil : "No cue to change"; return false
        }
        status = "Replaced \(result.replacements) in \(result.cuesChanged) " + (result.cuesChanged == 1 ? "cue" : "cues")
            + (result.skipped.isEmpty ? "" : "; \(result.skipped.count) left alone")
        return true
    }

    // MARK: Drawing

    public static func clock(_ ms: Int) -> String {
        let t = max(0, ms)
        return String(format: "%d:%02d:%02d.%03d", t / 3_600_000, t / 60_000 % 60, t / 1000 % 60, t % 1000)
    }

    private var barHeight: Double { findOpen ? Self.barRowHeight * (replaceOpen ? 2 : 1) + (status == nil ? 8 : 24) : 0 }

    public func draw(_ c: CanvasContext, size: CanvasSize) {
        DockedPanelDraw.background(c, size: size)
        let rows = self.rows
        if let id = editingID, !rows.contains(where: { $0.id == id }) { editingID = nil }
        let bar = barHeight
        list.layout(viewport: CanvasRect(x: 0, y: bar, width: size.width, height: max(0, size.height - bar)), count: rows.count)
        if findOpen { drawBar(c, width: size.width) }
        guard !rows.isEmpty else {
            DockedPanelDraw.empty(c, size: CanvasSize(size.width, max(0, size.height - bar)), title: "No captions",
                                  detail: editor?.document.sequence.captions == nil
                                      ? "Add a caption track by importing an SRT file or turning speech into captions."
                                      : "Add a caption at the playhead with + in the timeline's caption lane.")
            return
        }
        let hits = Dictionary(uniqueKeysWithValues: matches.map { ($0.cueId, $0.count) })
        c.withState {
            c.clip(list.viewport)
            for i in list.visibleRows {
                let r = list.rect(of: i), cue = rows[i]
                DockedPanelDraw.rowFill(c, r, selected: selectedID == cue.id, hovered: false)
                if hits[cue.id] != nil { c.fillRect(CanvasRect(x: 0, y: r.y + 4, width: 3, height: r.height - 8), PanelTheme.accent) }
                let times = "\(Self.clock(cue.startMs))  →  \(Self.clock(cue.endMs))"
                PanelDraw.text(c, times, in: CanvasRect(x: 12, y: r.y + 4, width: max(0, r.width - 80), height: 16), font: PanelTheme.font(10),
                               color: PanelTheme.text4)
                let editing = editingID == cue.id
                let shown = (editing ? draft : cue.text).replacingOccurrences(of: "\n", with: "⏎")
                let text = editing ? String(shown.prefix(caret)) + "▏" + String(shown.dropFirst(caret)) : shown
                PanelDraw.text(c, text, in: CanvasRect(x: 12, y: r.y + 22, width: max(0, r.width - 20), height: 18), font: PanelTheme.font(12),
                               color: PanelTheme.text0)
                if nativeCaptionExceedsReadingRate(cue, limit: readingRateLimit) {
                    let rate = Int(nativeCaptionReadingRate(cue).rounded())
                    let badge = CanvasRect(x: r.maxX - 62, y: r.y + 4, width: 54, height: 16)
                    c.fillRoundedRect(badge, radius: 8, CanvasColor(ThemeTokens.red500Pair.now))
                    PanelDraw.text(c, "\(rate) cps", in: badge.insetBy(3), font: PanelTheme.font(10), color: CanvasColor(ThemeTokens.white))
                }
            }
        }
        PanelScrollbar.draw(c, track: list.viewport, offset: list.scrollY, content: list.contentHeight, hovered: false)
    }

    private func drawBar(_ c: CanvasContext, width: Double) {
        let h = Self.barRowHeight
        func field(_ y: Double, _ label: String, _ text: String, active: Bool) {
            let r = CanvasRect(x: 8, y: y + 2, width: max(0, width - 16 - 150), height: h - 4)
            c.fillRoundedRect(r, radius: 3, PanelTheme.panelInput)
            if active { c.strokeRoundedRect(r.insetBy(0.5), radius: 3, PanelTheme.accent, width: 1) }
            PanelDraw.text(c, label + (active ? text + "▏" : text), in: r.insetBy(4), font: PanelTheme.font(11), color: PanelTheme.text0)
        }
        field(4, "Find: ", findText, active: findField == 0)
        caseRect = CanvasRect(x: max(0, width - 8 - 140), y: 6, width: 36, height: h - 8)
        c.fillRoundedRect(caseRect, radius: 3, caseSensitive ? PanelTheme.accent.withAlpha(0.5) : PanelTheme.panelInput)
        PanelDraw.text(c, "Aa", in: caseRect.insetBy(4), font: PanelTheme.font(11), color: PanelTheme.text0)
        if replaceOpen {
            field(4 + h, "Replace: ", replaceText, active: findField == 1)
            replaceAllRect = CanvasRect(x: max(0, width - 8 - 140), y: 4 + h + 2, width: 140, height: h - 4)
            c.fillRoundedRect(replaceAllRect, radius: 3, PanelTheme.panelInput)
            PanelDraw.text(c, "Replace all", in: replaceAllRect.insetBy(4), font: PanelTheme.font(11), color: PanelTheme.text0)
        } else {
            replaceAllRect = CanvasRect(x: 0, y: 0, width: 0, height: 0)
        }
        if let status {
            PanelDraw.text(c, status, in: CanvasRect(x: 8, y: barHeight - 20, width: width - 16, height: 16), font: PanelTheme.font(10), color: PanelTheme.text4)
        }
    }

    // MARK: Input

    private static func contains(_ r: CanvasRect, _ p: CanvasPoint) -> Bool { p.x >= r.x && p.x <= r.maxX && p.y >= r.y && p.y <= r.maxY }

    public func pointerDown(_ p: CanvasPoint, shift: Bool) -> Bool {
        if findOpen {
            if Self.contains(caseRect, p) { toggleCaseSensitive(); return true }
            if replaceOpen, Self.contains(replaceAllRect, p) { _ = replaceAll(); return true }
            if p.y < barHeight { findField = replaceOpen && p.y > 4 + Self.barRowHeight ? 1 : 0; return true }
        }
        guard let row = list.row(at: p), rows.indices.contains(row) else { return false }
        let cue = rows[row], time = now()
        selectedID = cue.id
        if let last = lastPress, last.0 == cue.id, time >= last.1, time - last.1 <= 0.4 {
            lastPress = nil; return beginEditing(cue.id)
        }
        lastPress = (cue.id, time); editingID = nil; onJump?(Double(cue.startMs) / 1000); return true
    }

    public func scroll(dy: Double) -> Bool { list.scroll(by: dy) }

    public func keyDown(_ k: EditorKey) -> Bool {
        if editingID != nil, let handled = editKey(k) { return handled }
        if findOpen, let handled = findKey(k) { return handled }
        if k.command, case .char(let ch) = k.code, ch.lowercased() == "f" { openFind(replace: k.alt); return true }
        if k.command, case .char(let ch) = k.code, ch.lowercased() == "j" { return joinWithNext() }
        if k.command, k.code == .enter { return splitAtPlayhead() }
        if k.alt, !k.command, case .char(let ch) = k.code {
            switch ch {
            case "[": return nudge(.start, frames: k.shift ? 1 : -1)
            case "]": return nudge(.end, frames: k.shift ? -1 : 1)
            default: return false
            }
        }
        guard !k.command && !k.alt else { return false }
        switch k.code {
        case .up: return moveSelection(-1)
        case .down: return moveSelection(1)
        case .enter, .function(2): return selectedID.map(beginEditing) ?? false
        default: return false
        }
    }

    /// Keys while a cue's text is open. Always handled, so typing never reaches a global shortcut.
    private func editKey(_ k: EditorKey) -> Bool? {
        if k.command, k.code == .enter { return splitAtPlayhead() }
        if k.command { return nil }
        switch k.code {
        case .escape: editingID = nil
        case .enter: if k.shift { insert("\n") } else { _ = commitEditing() }
        case .left: caret = max(0, caret - 1)
        case .right: caret = min(draft.count, caret + 1)
        case .home: caret = 0
        case .end: caret = draft.count
        case .backspace:
            if caret > 0 { var chars = Array(draft); chars.remove(at: caret - 1); draft = String(chars); caret -= 1 }
        case .delete:
            if caret < draft.count { var chars = Array(draft); chars.remove(at: caret); draft = String(chars) }
        case .char(let ch) where !k.alt: insert(String(ch))
        case .space: insert(" ")
        default: break
        }
        return true
    }

    /// Keys while the find bar is open: typing goes to the focused field.
    private func findKey(_ k: EditorKey) -> Bool? {
        if k.command, k.alt, k.code == .enter { return replaceAll() }
        if k.alt, !k.command, case .char(let ch) = k.code, ch.lowercased() == "c" { toggleCaseSensitive(); return true }
        if k.command { return nil }
        switch k.code {
        case .escape: closeFind()
        case .enter: _ = findNext()
        case .tab: if replaceOpen { findField = 1 - findField }
        case .backspace:
            if findField == 0 { if !findText.isEmpty { findText.removeLast() } } else if !replaceText.isEmpty { replaceText.removeLast() }
        case .char(let ch) where !k.alt:
            if findField == 0 { findText.append(ch) } else { replaceText.append(ch) }
        case .space:
            if findField == 0 { findText.append(" ") } else { replaceText.append(" ") }
        default: return nil
        }
        return true
    }

    public var hint: String? {
        "↑↓: cue · Enter: edit · ⌥[ ⌥]: nudge a frame · ⌘Enter: split · ⌘J: join · ⌘F: find · ⌥⌘F: replace"
    }
}
