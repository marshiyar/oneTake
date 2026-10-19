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
        let entries = TimelineClipMenu.entries(kind: c.kind, splitEnabled: t > c.start && t < c.end, thumbnails: thumbs,
                                               muted: c.muted, canReattach: canReattach, canDetach: canDetach, canMute: c.canMute)
        var m = TimelineClipMenu(x: x, y: y, clipId: id, entries: entries)
        let fh = TimelineClipMenu.flipHeight(thumbnails: c.kind == .video || c.kind == .image,
                                             canMute: (c.kind == .video || c.kind == .audio) && c.canMute, audioAction: canReattach || canDetach)
        if m.x + TimelineClipMenu.width > viewport.width { m.x -= TimelineClipMenu.width }
        if m.y + fh > viewport.height { m.y = max(0, m.y - fh) }
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
        case .split:
            let frame = (playback.currentTime * editor.fps).rounded()
            guard let a = editor.address(clipId: id) else { return false }
            return editor.apply(.split(address: a, splitFrame: frame))
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
