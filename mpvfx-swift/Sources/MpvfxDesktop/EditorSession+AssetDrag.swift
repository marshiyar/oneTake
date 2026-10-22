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
import MpvfxPanels
import MpvfxTimeline
import MpvfxDesktopCore

/// Dragging a bin asset out of the left sidebar (AssetCard drag): over the stage the player highlights the drop and a
/// drop inserts at the playhead (PlayerController.assetDragMoved / dropAsset / assetDragEnded, player-local points);
/// over the timeline a drop inserts at the time and track under the pointer (TimelineEditor.insertClip).
final class BinAssetDrag: CrossPaneDrag {
    unowned let panels: SessionPanels
    private var window: CanvasPoint?
    private var overPlayer = false
    /// Over the timeline's tracks: the tracks area gets the drop outline (isDragOver).
    private(set) var overTimeline = false
    /// A file drag from the desktop is over the timeline's tracks (same outline).
    private(set) var fileDragOverTimeline = false

    init(_ panels: SessionPanels) { self.panels = panels }

    var session: EditorSession { panels.session }

    func isDragging(from region: EditorShellRouter.Region) -> Bool {
        region == .left && panels.left.draggingAssetId != nil
    }

    func dragMoved(over region: EditorShellRouter.Region?, local: CanvasPoint, window: CanvasPoint) {
        self.window = window
        overTimeline = region == .timeline && local.y >= TimelineToolbar.height
        if region == .player {
            overPlayer = session.player.assetDragMoved(x: local.x, y: local.y)
        } else if overPlayer {
            overPlayer = false
            session.player.assetDragEnded()
        }
    }

    func dragEnded(over region: EditorShellRouter.Region?, local: CanvasPoint) {
        defer { window = nil; overPlayer = false; overTimeline = false; session.player.assetDragEnded() }
        guard let path = panels.left.lastDraggedAssetId else { return }
        if let look = TextLookPreset.draggedPreset(path) {
            if region == .player || region == .timeline && local.y >= TimelineToolbar.height { session.addTextLook(look) }
            return
        }
        switch region {
        case .player?: dropOnStage(path, local)
        case .timeline?: dropOnTimeline(path, local)
        default: break
        }
    }

    private func dropOnStage(_ path: String, _ p: CanvasPoint) {
        guard session.player.assetDragMoved(x: p.x, y: p.y) else { return }
        let kind = panels.assetKind(path: path)
        if let kind, let assetId = session.editor.document.assets.first(where: { $0.source == path && $0.kind == kind })?.id {
            if session.player.dropAsset(assetId, x: p.x, y: p.y) != nil {
                session.playback.duration = session.editor.duration
                panels.syncItems()
            }
        } else {
            // Not in the document yet: add it with its probed duration, at the playhead (what dropAsset does).
            panels.addToTimeline(path: path, at: nil)
        }
    }

    private func dropOnTimeline(_ path: String, _ p: CanvasPoint) {
        guard let place = timelinePlacement(p, kind: panels.assetKind(path: path)) else { return }
        panels.addToTimeline(path: path, at: place.time, trackId: place.trackId)
    }

    /// Where a drop at a timeline-local point lands: the time under it and, when the kind fits and the track is
    /// unlocked, the track under it (nil: the editor picks or makes one). Nil above the tracks.
    func timelinePlacement(_ p: CanvasPoint, kind: NativeProjectAssetKind?) -> (time: Double, trackId: String?)? {
        guard session.timelineRegion != nil else { return nil }
        let view = session.timeline.view
        let y = p.y - TimelineToolbar.height
        guard y >= 0 else { return nil }
        let time = max(0, view.time(forX: p.x))
        var trackId: String?
        if !view.tracks.isEmpty, let kind {
            let track = view.tracks[min(max(0, view.trackIndex(nearY: y)), view.tracks.count - 1)]
            let wants: [String] = kind == .audio ? ["audio", "mixed"] : ["video", "mixed"]
            if wants.contains(track.kind), !track.locked { trackId = track.id }
        }
        return (time, trackId)
    }

    // MARK: Files dragged in from the desktop (AssetsTab drop zone / timeline file drop)

    /// A file drag from the file manager moved over the window (window points; nil: it left).
    func filesDragged(over window: CanvasPoint?) {
        let over = window.flatMap { session.shell?.hit($0.x, $0.y) }
        let next = over.map { $0.region == .timeline && $0.local.y >= TimelineToolbar.height } ?? false
        if next != fileDragOverTimeline { fileDragOverTimeline = next; session.redraw() }
    }

    /// Files dropped from the file manager: imported into the project (the bin lists them); over the timeline's
    /// tracks each imported clip is also placed from the drop time on, one after another. False without a project.
    @discardableResult
    func dropFiles(_ paths: [String], at window: CanvasPoint) -> Bool {
        fileDragOverTimeline = false
        guard !paths.isEmpty, session.project != nil else { session.redraw(); return false }
        let hit = session.shell?.hit(window.x, window.y)
        let start: CanvasPoint? = hit?.region == .timeline ? hit?.local : nil
        session.importMedia(paths: paths) { [weak self] result in
            guard let self, let start else { return }
            self.placeImported(result.media, from: start)
        }
        return true
    }

    func placeImported(_ media: [DesktopImportedMedia], from p: CanvasPoint) {
        let editor = session.editor
        var at: Double?
        var placed: String?
        for m in media {
            let kind: NativeProjectAssetKind
            switch m.kind { case "video": kind = .video; case "audio": kind = .audio; case "image": kind = .image; default: continue }
            guard let assetId = editor.document.assets.first(where: { $0.source == m.path && $0.kind == kind })?.id,
                  let place = timelinePlacement(p, kind: kind) else { continue }
            let t = at ?? place.time
            guard let clipId = editor.insertClip(assetId: assetId, at: t, trackId: place.trackId),
                  let c = editor.clip(clipId)?.clip else { continue }
            at = (c.startFrame + c.durationFrames) / editor.fps
            placed = clipId
        }
        guard let placed else { return }
        session.timeline.view.selection = [placed]
        session.playback.duration = editor.duration
        session.syncStage(); panels.syncItems(); session.redraw()
    }

    /// The drop outline over the timeline's tracks, then a chip with the asset's name under the pointer.
    func drawDrag(_ c: CanvasContext) {
        let assetOver = window != nil && panels.left.draggingAssetId != nil && overTimeline
        if assetOver || fileDragOverTimeline, let router = session.shell, let f = router.frames {
            AssetDropOutline.draw(c, timeline: router.rect(.timeline, f))
        }
        guard let w = window, let id = panels.left.draggingAssetId else { return }
        let name = TextLookPreset.draggedPreset(id)?.name ?? panels.left.items.first { $0.id == id }?.name ?? (id as NSString).lastPathComponent
        let font = PanelTheme.font(11, .medium)
        let width = min(220, c.measureText(name, font: font).width + 16)
        let r = CanvasRect(x: w.x + 10, y: w.y + 10, width: width, height: 22)
        c.fillRoundedRect(r, radius: 4, PanelTheme.neutral900.withAlpha(0.92))
        c.strokeRoundedRect(r.insetBy(0.5), radius: 3.5, PanelTheme.panelBorderInput, width: 1)
        PanelDraw.text(c, name, in: CanvasRect(x: r.x + 8, y: r.y, width: r.width - 16, height: r.height), font: font, color: PanelTheme.text1)
    }
}

extension SessionPanels {
    func assetKind(path: String) -> NativeProjectAssetKind? {
        switch media.first(where: { $0.path == path })?.category {
        case .video?: return .video
        case .audio?: return .audio
        case .images?: return .image
        default: return nil
        }
    }
}
