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

public extension TimelineController {
    /// U: expand/collapse property lanes of the selected clips (ShortcutsPanel "Expand / collapse properties").
    /// Note: the original lists U but never wires it (TimelineToolbar omits onToggleExpand).
    @discardableResult func toggleExpandSelection() -> Bool {
        let ids = view.selection.filter { id in view.tracks.flatMap(\.clips).contains { $0.id == id && !$0.lanes.isEmpty } }
        guard !ids.isEmpty else { return false }
        if ids.allSatisfy({ view.expandedClips.contains($0) }) { view.expandedClips.subtract(ids) } else { view.expandedClips.formUnion(ids) }
        clampScroll(); needsDisplay?(); return true
    }

    /// ⌘K: key every keyframeable property of the selected clips at the playhead; ⇧⌘K only the animated ones.
    /// One undo step. Handled (true) whenever a clip is selected, so the key never reaches playback.
    @discardableResult func keySelectedProperties(animatedOnly: Bool) -> Bool {
        guard let editor, !view.selection.isEmpty else { return false }
        if editor.keyProperties(clipIds: view.selection.sorted(), time: playback.currentTime, animatedOnly: animatedOnly) { needsDisplay?() }
        return true
    }

    /// ⌘= / ⌘+ zoom in, ⌘- out, ⌘0 fit.
    internal func zoomKey(_ ch: Character) -> Bool {
        if ch == "0" { zoomToFit() } else { zoom(in: ch != "-") }
        return true
    }

    func toggleGroup(_ id: String) {
        if view.collapsedGroups.contains(id) { view.collapsedGroups.remove(id) } else { view.collapsedGroups.insert(id) }
        if let e = editor { reload(from: e) }
        needsDisplay?()
    }

    internal func openClipMenu(_ id: String, x: Double, y: Double) {
        guard let (_, c) = clip(id) else { return }
        if !view.selection.contains(id) { view.selection = [id] }
        let t = playback.currentTime
        let thumbs = view.thumbnailsEnabled
        let canReattach = c.kind == .audio && c.audioDetachedFrom != nil
        let canDetach = !canReattach && c.canDetachAudio
        // The pitch option goes with the clip that plays the sound (a detached video's lives on its audio clip).
        let sounds = c.kind == .audio || (c.kind == .video && c.canMute)
        let entries = TimelineClipMenu.entries(kind: c.kind, splitEnabled: t > c.start && t < c.end, thumbnails: thumbs,
                                               muted: c.muted, canReattach: canReattach, canDetach: canDetach, canMute: c.canMute,
                                               canPaste: clipboard != nil, canPasteGrade: gradeClipboard != nil,
                                               gradePasteReason: gradeClipboard == nil ? "Copy a grade before pasting" : nil,
                                               keepsPitch: sounds ? editor?.preservesPitch(clipId: id) : nil)
        var m = TimelineClipMenu(x: x, y: y, clipId: id, entries: entries)
        if m.x + TimelineClipMenu.width > viewport.width { m.x -= TimelineClipMenu.width }
        if m.y + m.height > viewport.height { m.y = max(0, m.y - m.height) }
        view.clipMenu = m
    }

    internal func clipMenuClick(x: Double, y: Double) {
        guard let m = view.clipMenu else { return }
        guard let item = m.item(atX: x, y: y) else {
            if !m.rect.contains(x: x, y: y) { view.clipMenu = nil; needsDisplay?() }
            return
        }
        guard item.enabled else { return }
        view.clipMenu = nil
        runClipMenu(item.action, clipId: m.clipId)
        needsDisplay?()
    }

    @discardableResult func runClipMenu(_ action: TimelineClipMenu.Action, clipId id: String) -> Bool {
        guard let editor, let (_, c) = clip(id) else { return false }
        switch action {
        case .revealSource, .showSourceFile:
            guard let onRevealSource else { return false }
            onRevealSource(id, action == .showSourceFile)
            return true
        case .split:
            let frame = (playback.currentTime * editor.fps).rounded()
            guard let a = editor.address(clipId: id) else { return false }
            return editor.apply(.split(address: a, splitFrame: frame))
        case .cut, .copy:
            // A clip in the selection acts with the rest of it, like the keys of the diamond menu.
            if !view.selection.contains(id) { view.selection = [id] }
            guard copySelection() else { return false }
            return action == .copy || deleteSelection()
        case .paste:
            return pasteClipboard(onto: editor.address(clipId: id)?.trackId)
        case .copyGrade:
            view.selection = [id]; return copyGradeSelection()
        case .pasteGrade:
            if !view.selection.contains(id) { view.selection = [id] }
            return pasteGradeSelection()
        case .duplicate:
            view.selection = [id]
            return duplicateSelection()
        case .keepPitch: return editor.setPreservesPitch(clipId: id, !editor.preservesPitch(clipId: id))
        case .thumbnails:
            setThumbnailsEnabled(!view.thumbnailsEnabled)   // thumbnailMode is timeline-wide (adaptive / hidden)
            return true
        case .mute: return editor.setMuted(clipId: id, !c.muted)
        case .detachAudio, .reattachAudio:
            // useNativeAudioActions: the host probes the file for an audio stream and reports failures.
            if let onNativeAudioAction { onNativeAudioAction(id, action == .detachAudio ? .detach : .reattach); return true }
            return action == .detachAudio ? editor.detachAudio(clipId: id, hasAudioStream: hasAudioStream(id))
                                          : editor.reattachAudio(clipId: id)
        case .delete:
            guard let a = editor.address(clipId: id) else { return false }
            view.selection.remove(id)
            return editor.apply(.delete(address: a))
        }
    }
}

extension CanvasRect {
    func contains(x px: Double, y py: Double) -> Bool { px >= x && px <= maxX && py >= y && py <= maxY }
}
