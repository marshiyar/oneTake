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
import MpvfxPlayer
import MpvfxRuntime
import MpvfxShared
import MpvfxTimeline

/// CanvasInput adapter for a docked panel's pane (region-local coordinates): events go to the panel, and the window
/// is redrawn when the panel says it changed.
final class DockedPanelInput: CanvasInput {
    let panel: DockedPanelView
    let redraw: () -> Void
    private var last = CanvasPoint(0, 0)
    init(_ panel: DockedPanelView, redraw: @escaping () -> Void) { self.panel = panel; self.redraw = redraw }
    private func changed(_ b: Bool) { if b { redraw() } }
    func pointerDown(x: Double, y: Double, shift: Bool) { last = .init(x, y); changed(panel.pointerDown(last, shift: shift)) }
    func pointerMove(x: Double, y: Double) { last = .init(x, y); changed(panel.pointerMove(last)) }
    func pointerUp(x: Double, y: Double) { last = .init(x, y); changed(panel.pointerUp(last)) }
    func secondaryClick(x: Double, y: Double) {}
    func scroll(dx: Double, dy: Double, x: Double, ctrl: Bool, shift: Bool) { changed(panel.scroll(dy: dy)) }
    func keyDown(_ k: EditorKey) -> Bool { let h = panel.keyDown(k); changed(h); return h }
    func keyUp(_ k: EditorKey) {}
    func resized(_ size: CanvasSize) {}
}

extension EditorSession {
    /// Puts a panel's content in the pane of its dock id (the id must be in `DockPanels.builtIn`).
    @discardableResult
    func installDockedPanel(_ router: EditorShellRouter, id: DockPanelID, panel: DockedPanelView,
                            beforePaint: @escaping () -> Void = {}) -> DockedPanelInput {
        let input = DockedPanelInput(panel) { [weak self] in self?.redraw() }
        shellInputs.append(input)
        let pane = ShellPane(input: input) { c, size in beforePaint(); panel.draw(c, size: size) }
        pane.hint = { [weak panel] in panel?.hint }
        router.panes[.of(id)] = pane
        return input
    }

    /// The panels that read the document: History, and the ones added next to it.
    func installDocumentPanels(_ router: EditorShellRouter) {
        let markers = MarkersPanel()
        markers.editor = editor
        markers.onJump = { [weak self] time in
            guard let self else { return }
            self.timeline.playback.seek(time); self.timeline.syncFromPlayback()
        }
        installDockedPanel(router, id: DockPanels.markers, panel: markers)

        let mixer = MixerPanel()
        mixer.editor = editor
        installDockedPanel(router, id: DockPanels.mixer, panel: mixer) { [weak self, weak mixer] in
            guard let self, let mixer else { return }
            mixer.meters = self.playback.isPlaying ? (self.graph?.meters ?? [:]).mapValues { ($0.peak, $0.rms) } : [:]
        }
        let history = HistoryPanel()
        history.editor = editor
        installDockedPanel(router, id: DockPanels.history, panel: history)
        let feed = ClipInfoFeed(self)
        feed.panel.onCopy = { [weak self] text in self?.panels?.copyToClipboard?(text) }
        installDockedPanel(router, id: DockPanels.info, panel: feed.panel) { [weak feed] in feed?.refresh() }
        clipInfoFeed = feed
        installEffectsPanel(router)
        let scopes = ScopesPanel(layout: router.layout)
        let program = ProgramScopeRenderer(compositor: compositor)
        let refresh: () -> Void = { [weak self] in self?.postToUI { [weak self] in self?.redraw() } }
        program.onReady = refresh
        scopes.worker.onReady = refresh
        scopes.onChange = { [weak self] in self?.redraw() }
        scopes.programFrame = { [weak self] width, height in
            guard let self else { return .unavailable }
            return PresetPreviewState(program.frame(at: self.playback.currentTime, pixelWidth: width, pixelHeight: height))
        }
        installDockedPanel(router, id: DockPanels.scopes, panel: scopes)
    }
    /// The first selected clip in document order (the panels that act on "the selected clip" use it).
    func selectedClipId() -> String? {
        let ids = timeline.view.selection
        guard !ids.isEmpty else { return nil }
        return editor.document.sequence.tracks.lazy.flatMap(\.clips).first { ids.contains($0.id) }?.id
    }

    /// The Effects browser: tiles from the inspector's preview renderer, Return / double click / drop apply to a clip.
    private func installEffectsPanel(_ router: EditorShellRouter) {
        let effects = EffectsPanel()
        effects.editor = editor
        effects.selectedClip = { [weak self] in self?.selectedClipId() }
        effects.time = { [weak self] in self?.playback.currentTime ?? 0 }
        effects.effectPreview = { [weak self] req in self?.panels?.right.inspector.effectPreview?(req) ?? .unavailable }
        effects.onEdited = { [weak self] in self?.redraw() }
        installDockedPanel(router, id: DockPanels.effects, panel: effects)
        let drag = EffectDrag(self, panel: effects)
        var drags: [CrossPaneDrag] = []
        if let existing = router.crossPaneDrag { drags.append(existing) }
        drags.append(drag)
        let group = CrossPaneDragGroup(drags)
        crossPaneDrags = group
        router.crossPaneDrag = group
    }
}

/// Several cross-pane drags behind the router's one slot: the one whose source pane has the press gets the events.
final class CrossPaneDragGroup: CrossPaneDrag {
    let drags: [CrossPaneDrag]
    private var active: CrossPaneDrag?
    init(_ drags: [CrossPaneDrag]) { self.drags = drags }
    func isDragging(from region: EditorShellRouter.Region) -> Bool {
        if let d = drags.first(where: { $0.isDragging(from: region) }) { active = d; return true }
        return false
    }
    func dragMoved(over region: EditorShellRouter.Region?, local: CanvasPoint, window: CanvasPoint) {
        active?.dragMoved(over: region, local: local, window: window)
    }
    func dragEnded(over region: EditorShellRouter.Region?, local: CanvasPoint) {
        active?.dragEnded(over: region, local: local)
        active = nil
    }
    func drawDrag(_ c: CanvasContext) { for d in drags { d.drawDrag(c) } }
}

/// Dragging an effect tile out of the Effects panel onto a clip in the timeline.
final class EffectDrag: CrossPaneDrag {
    unowned let session: EditorSession
    let panel: EffectsPanel
    private var window: CanvasPoint?
    private(set) var overClip: String?

    init(_ session: EditorSession, panel: EffectsPanel) { self.session = session; self.panel = panel }

    func isDragging(from region: EditorShellRouter.Region) -> Bool {
        region == .of(DockPanels.effects) && panel.draggingEntry != nil
    }

    func dragMoved(over region: EditorShellRouter.Region?, local: CanvasPoint, window: CanvasPoint) {
        self.window = window
        overClip = region == .timeline ? clip(atTimelinePoint: local) : nil
    }

    func dragEnded(over region: EditorShellRouter.Region?, local: CanvasPoint) {
        defer { window = nil; overClip = nil }
        guard region == .timeline, let entry = panel.lastDraggedEntry, let id = clip(atTimelinePoint: local) else { return }
        if panel.apply(entry, toClip: id) != .noClip { session.timeline.view.selection = [id] }
        session.redraw()
    }

    /// The clip under a timeline-local point, nil over the toolbar, a gap or no clip.
    func clip(atTimelinePoint p: CanvasPoint) -> String? {
        let view = session.timeline.view
        let y = p.y - TimelineToolbar.height
        guard y >= 0, !view.tracks.isEmpty else { return nil }
        let track = view.tracks[min(max(0, view.trackIndex(nearY: y)), view.tracks.count - 1)]
        let t = view.time(forX: p.x)
        return track.clips.first { t >= $0.start && t < $0.start + $0.duration }?.id
    }

    func drawDrag(_ c: CanvasContext) {
        guard let w = window, let e = panel.draggingEntry else { return }
        let font = PanelTheme.font(11, .medium)
        let width = min(220, c.measureText(e.label, font: font).width + 16)
        let r = CanvasRect(x: w.x + 10, y: w.y + 10, width: width, height: 22)
        c.fillRoundedRect(r, radius: 4, PanelTheme.neutral900.withAlpha(0.92))
        c.strokeRoundedRect(r.insetBy(0.5), radius: 3.5, overClip != nil ? PanelTheme.accent : PanelTheme.panelBorderInput, width: 1)
        PanelDraw.text(c, e.label, in: CanvasRect(x: r.x + 8, y: r.y, width: r.width - 16, height: r.height), font: font, color: PanelTheme.text1)
    }
}

/// Resolves the timeline selection to a source file and reads its facts off the UI thread (once per file).
final class ClipInfoFeed {
    unowned let session: EditorSession
    let panel = ClipInfoPanel()
    private var cache: [String: Result<ClipInfo, ClipInfoFailure>] = [:]
    private var inflight: Set<String> = []

    init(_ session: EditorSession) { self.session = session }

    /// The first selected clip (document order) with its asset's name and source.
    func selected() -> (name: String, source: String?)? {
        let ids = session.timeline.view.selection
        guard !ids.isEmpty else { return nil }
        let doc = session.editor.document
        let assets = Dictionary(doc.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for track in doc.sequence.tracks {
            for clip in track.clips where ids.contains(clip.id) {
                let asset = assets[clip.assetId]
                return (asset?.name ?? clip.assetId, asset?.source)
            }
        }
        return nil
    }

    /// Called before each paint: sets `panel.content` for the current selection.
    func refresh() {
        guard let (name, source) = selected() else { panel.content = .none; return }
        guard let source, !source.isEmpty else {
            panel.content = .failed(name: name, message: "This clip has no source file."); return
        }
        let dir = session.projectDir?.path ?? ""
        if let known = cache[source] {
            switch known {
            case .failure(let f): panel.content = .failed(name: name, message: f.message); return
            case .success(let info):
                // A file that was offline is checked again, so restoring it shows up without reselecting.
                if !(info.offline && FileManager.default.fileExists(atPath: info.path)) { panel.content = .info(name: name, info); return }
                cache[source] = nil
            }
        }
        panel.content = .loading(name: name)
        guard inflight.insert(source).inserted else { return }
        let post = { [weak session] (body: @escaping () -> Void) in session?.postToUI(body) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try readProjectClipInfo(dir, source) }
            post {
                guard let self else { return }
                self.inflight.remove(source)
                self.cache[source] = result.mapError { ClipInfoFailure(message: "\($0)") }
                self.session.redraw()
            }
        }
    }
}

struct ClipInfoFailure: Error, Equatable { let message: String }
