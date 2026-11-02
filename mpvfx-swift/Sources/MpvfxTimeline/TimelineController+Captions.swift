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
// Pointer and key handling for the caption lane (TimelineView+Captions.swift): select a cue, drag it to move it, drag a
// handle to trim it, double-click (or Enter / F2 on the selected cue) to retype it, "+" to add one at the playhead.
// A drag only changes the view's preview; the release commits one edit, so each gesture is one undo step.
import Foundation
import MpvfxCanvas
import MpvfxShared

/// A press on a cue that may grow into a move (the block) or a trim (a handle).
struct TimelineCaptionGesture {
    var cueId: String
    /// nil moves the whole cue; otherwise the end being trimmed.
    var edge: NativeCaptionEdge?
    var downX: Double
    var original: NativeCaptionCue
    var moved = false
}

/// The controller's caption state: the gesture in progress and the last body press (for double-click).
struct TimelineCaptionControllerState {
    var gesture: TimelineCaptionGesture?
    var lastPress: (cueId: String, at: Double)?
    /// Clock for double-click timing (seconds); injectable for tests.
    var now: () -> Double = { Date().timeIntervalSince1970 }
    static let doubleClickInterval = 0.4
}

extension TimelineController {
    // MARK: Pointer

    /// A press on the caption lane or its text field. True when it was handled here.
    func captionPointerDown(x: Double, y: Double) -> Bool {
        if let edit = view.captions.edit {
            if edit.confirmRect.contains(x: x, y: y) { _ = commitCaptionEdit() }
            else if edit.cancelRect.contains(x: x, y: y) || !edit.rect.contains(x: x, y: y) { view.captions.edit = nil; needsDisplay?() }
            return true
        }
        guard view.captions.isShown, tool == .select, y >= TimelineLayout.rulerHeight else { return false }
        if let add = view.captionAddButtonRect, add.contains(x: x, y: y) { _ = addCaptionAtPlayhead(); return true }
        guard let hit = view.captionCueHit(x: x, y: y), let cue = view.captions.cues.first(where: { $0.id == hit.id }) else {
            if view.captions.selectedCueId != nil { view.captions.selectedCueId = nil; needsDisplay?() }
            return false
        }
        view.selection = []; view.selectedKeyframes = []
        view.captions.selectedCueId = cue.id
        let now = captionState.now()
        if hit.edge == nil, let last = captionState.lastPress, last.cueId == cue.id,
           now - last.at <= TimelineCaptionControllerState.doubleClickInterval {
            captionState.lastPress = nil
            _ = requestEditCaption(cue.id)
            return true
        }
        if hit.edge == nil { captionState.lastPress = (cue.id, now) } else { captionState.lastPress = nil }
        captionState.gesture = TimelineCaptionGesture(cueId: cue.id, edge: hit.edge, downX: x, original: cue)
        needsDisplay?()
        return true
    }

    /// A drag of a pressed cue: shows where it would land, clamped against its neighbours. True while a gesture is on.
    func captionPointerMove(x: Double) -> Bool {
        guard var g = captionState.gesture else { return false }
        if !g.moved {
            guard abs(x - g.downX) >= Self.dragThresholdPx else { return true }
            g.moved = true
        }
        let deltaMs = Int(((x - g.downX) / max(view.pixelsPerSecond, 1e-9) * 1000).rounded())
        if let track = editor?.document.sequence.captions, let fps = editor?.fps {
            let planned: NativeCaptionTrack?
            switch g.edge {
            case nil: planned = try? planCaptionMove(track, cueId: g.cueId, toStartMs: g.original.startMs + deltaMs)
            case .start?: planned = try? planCaptionTrim(track, cueId: g.cueId, edge: .start, toMs: g.original.startMs + deltaMs, frameRate: fps)
            case .end?: planned = try? planCaptionTrim(track, cueId: g.cueId, edge: .end, toMs: g.original.endMs + deltaMs, frameRate: fps)
            }
            view.captions.preview = planned?.cues.first { $0.id == g.cueId }
        }
        captionState.gesture = g
        needsDisplay?()
        return true
    }

    /// The release of a cue gesture: one edit when it moved. True when a gesture was on.
    func captionPointerUp() -> Bool {
        guard let g = captionState.gesture else { return false }
        let preview = view.captions.preview
        captionState.gesture = nil; view.captions.preview = nil
        defer { needsDisplay?() }
        guard g.moved, let preview else { return true }
        captionState.lastPress = nil
        switch g.edge {
        case nil: _ = editor?.moveCaptionCue(g.cueId, toStartMs: preview.startMs)
        case .start?: _ = editor?.trimCaptionCue(g.cueId, edge: .start, toMs: preview.startMs)
        case .end?: _ = editor?.trimCaptionCue(g.cueId, edge: .end, toMs: preview.endMs)
        }
        return true
    }

    // MARK: Commands

    /// Adds a cue at the playhead (2 s, or up to the next cue) and selects it. False, with a notice, when no frame fits there.
    @discardableResult public func addCaptionAtPlayhead() -> Bool {
        guard let editor else { return false }
        guard let id = editor.addCaptionCue(atMs: Int((playback.currentTime * 1000).rounded())) else {
            editor.onNotice?("There is no room for a caption at the playhead")
            return false
        }
        view.selection = []
        view.captions.selectedCueId = id
        needsDisplay?()
        return true
    }

    /// Opens the text field on a cue.
    @discardableResult public func requestEditCaption(_ id: String) -> Bool {
        guard let cue = view.captions.cues.first(where: { $0.id == id }) else { return false }
        let width = max(220, min(420, viewport.width - 16))
        view.clipMenu = nil
        view.captions.selectedCueId = id
        view.captions.edit = TimelineCueEdit(cueId: id, draft: cue.text, cursor: cue.text.count,
            rect: CanvasRect(x: max(8, (viewport.width - width) / 2), y: 12, width: width, height: 116))
        needsDisplay?()
        return true
    }

    /// Saves the text field: one undo step. A text a cue cannot hold stays open with the reason under the field.
    @discardableResult func commitCaptionEdit() -> Bool {
        guard var edit = view.captions.edit, let editor else { return false }
        let text = edit.draft.replacingOccurrences(of: "\r\n", with: "\n")
        if let problem = nativeCaptionTextProblem(text) {
            edit.problem = problem; view.captions.edit = edit; needsDisplay?(); return false
        }
        view.captions.edit = nil
        let changed = editor.setCaptionText(edit.cueId, to: text)
        needsDisplay?()
        return changed
    }

    // MARK: Keys

    /// Keys for the caption lane, or nil when the key is not for it. The text field takes every key while it is open.
    func captionKeyDown(_ k: EditorKey) -> Bool? {
        if view.captions.edit != nil { return captionEditKey(k) }
        if captionState.gesture != nil, k.code == .escape {
            captionState.gesture = nil; view.captions.preview = nil; needsDisplay?(); return true
        }
        guard let id = view.captions.selectedCueId, view.selection.isEmpty, !k.command, !k.alt else { return nil }
        switch k.code {
        case .enter, .function(2): return requestEditCaption(id)
        default: return nil
        }
    }

    private func captionEditKey(_ key: EditorKey) -> Bool {
        guard var edit = view.captions.edit else { return false }
        defer { needsDisplay?() }
        switch key.code {
        case .escape: view.captions.edit = nil; return true
        case .enter:
            if key.shift { insertCaptionText("\n", into: &edit) } else { _ = commitCaptionEdit(); return true }
        case .char(let ch) where key.command && ch.lowercased() == "a":
            edit.selectedAll = true
        case .left:
            edit.cursor = edit.selectedAll ? 0 : max(0, edit.cursor - 1); edit.selectedAll = false
        case .right:
            edit.cursor = edit.selectedAll ? edit.draft.count : min(edit.draft.count, edit.cursor + 1); edit.selectedAll = false
        case .home: edit.cursor = 0; edit.selectedAll = false
        case .end: edit.cursor = edit.draft.count; edit.selectedAll = false
        case .backspace, .delete:
            var chars = Array(edit.draft)
            if edit.selectedAll { chars = []; edit.cursor = 0 }
            else if key.code == .backspace, edit.cursor > 0 { chars.remove(at: edit.cursor - 1); edit.cursor -= 1 }
            else if key.code == .delete, edit.cursor < chars.count { chars.remove(at: edit.cursor) }
            edit.draft = String(chars); edit.selectedAll = false
        case .char(let ch) where !key.command && !key.alt:
            insertCaptionText(String(ch), into: &edit)
        case .space where !key.command && !key.alt:
            insertCaptionText(" ", into: &edit)
        default: break
        }
        edit.problem = nil
        view.captions.edit = edit
        return true
    }

    private func insertCaptionText(_ text: String, into edit: inout TimelineCueEdit) {
        var chars = edit.selectedAll ? [] : Array(edit.draft)
        if edit.selectedAll { edit.cursor = 0 }
        chars.insert(contentsOf: text, at: edit.cursor)
        edit.cursor += text.count
        edit.draft = String(chars); edit.selectedAll = false
    }
}
