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
import MpvfxAudioGraph
import MpvfxShared
import MpvfxTimeline

/// Why an effect did not go onto a clip.
public enum EffectApplyResult: Equatable {
    case applied(clipId: String)
    case noClip
    /// The clip cannot take this kind of effect (a video effect on a sound clip, an audio effect on a picture).
    case wrongKind(String)
    case locked
    case failed
}

/// The Effects browser (dock id `effects`): the video and audio effects in groups, a search field and a preview tile
/// per video effect (the selected clip's frame with the effect on it). Return applies the highlighted effect to the
/// selected clip, a double click does too, and dragging a tile onto a clip in the timeline drops it there; each is one
/// undo step.
public final class EffectsPanel: DockedPanelView {
    public var editor: TimelineEditor?
    /// The clip an apply goes to when none is named.
    public var selectedClip: () -> String? = { nil }
    /// The playhead in seconds (keyed grade values are read and written there).
    public var time: () -> Double = { 0 }
    /// The inspector's tile renderer: the clip's frame (else a sample picture) with the grade in the request.
    public var effectPreview: ((EffectPreviewRequest) -> PresetPreviewState)?
    /// After a document edit from this panel (the host saves and redraws).
    public var onEdited: (() -> Void)?
    /// Seconds, for double-click timing.
    public var now: () -> Double = { Date().timeIntervalSince1970 }

    public private(set) var query = ""
    public private(set) var searchFocused = false
    public private(set) var highlighted: String?
    /// What the last apply said, shown under the search field.
    public private(set) var status: String?
    /// The tile being dragged out of the panel, and the last one dragged (the host reads it when the drag ends).
    public private(set) var draggingEntry: EffectEntry?
    public private(set) var lastDraggedEntry: EffectEntry?

    struct Placed { var entry: EffectEntry; var rect: CanvasRect }
    struct Header { var title: String; var rect: CanvasRect }
    private(set) var tiles: [Placed] = []
    private var headers: [Header] = []
    private(set) var scrollY = 0.0
    private var contentHeight = 0.0
    private var viewport = CanvasRect(x: 0, y: 0, width: 0, height: 0)
    private var searchRect = CanvasRect(x: 0, y: 0, width: 0, height: 0)
    private var pressed: (entry: EffectEntry, at: CanvasPoint)?
    private var lastClick: (id: String, at: Double)?
    private var hoveredId: String?

    static let pad = 8.0, gap = 6.0, minTileWidth = 96.0, searchHeight = 28.0, headerHeight = 22.0, labelHeight = 24.0

    public init() {}

    public var entries: [EffectEntry] { EffectsCatalog.entries(matching: query) }

    // MARK: Search

    public func setQuery(_ text: String) {
        query = String(text.prefix(80))
        scrollY = 0
        if let h = highlighted, !entries.contains(where: { $0.id == h }) { highlighted = nil }
    }

    // MARK: Applying

    /// Puts `entry` on a clip (the selected one by default) as one undo step.
    @discardableResult
    public func apply(_ entry: EffectEntry, toClip named: String? = nil) -> EffectApplyResult {
        guard let editor, let clipId = named ?? selectedClip(), let (_, clip) = editor.clip(clipId) else {
            status = "Select a clip to apply \(entry.label)."
            return .noClip
        }
        let asset = editor.document.assets.first { $0.id == clip.assetId }
        guard !editor.isClipLocked(clipId) else { status = "The clip is locked."; return .locked }
        let result: EffectApplyResult
        switch entry.kind {
        case .video:
            guard let asset, asset.kind == .video || asset.kind == .image, let spec = EffectSpecs.spec(entry.key) else {
                status = "\(entry.label) is a picture effect; this clip has no picture."
                return .wrongKind("no picture")
            }
            result = applyVideo(spec, editor: editor, clipId: clipId)
        case .audio:
            guard let asset, asset.kind == .video || asset.kind == .audio else {
                status = "\(entry.label) is a sound effect; this clip has no sound."
                return .wrongKind("no sound")
            }
            result = applyAudio(entry, editor: editor, clipId: clipId, clip: clip)
        }
        switch result {
        case .applied: status = "Added \(entry.label)."; onEdited?()
        case .failed: status = "Could not add \(entry.label)."
        default: break
        }
        return result
    }

    private func applyVideo(_ spec: EffectSpecs.Spec, editor: TimelineEditor, clipId: String) -> EffectApplyResult {
        let t = time()
        let shown = editor.gradeShown(clipId: clipId, time: t)
        var next = shown
        for (k, v) in EffectSpecs.applyDefaults[spec.key] ?? [:] { next.effects[k] = v }
        next.effectsEnabled = true
        let ok = editor.withHistory("Add \(spec.label)") { editor.commitGrade(clipId: clipId, time: t, shown: shown, next: next) }
        return ok ? .applied(clipId: clipId) : .failed
    }

    private func applyAudio(_ entry: EffectEntry, editor: TimelineEditor, clipId: String, clip: NativeProjectClip) -> EffectApplyResult {
        let chain = (try? clip.audioFxChain.map(AudioFx.parseChain)) ?? nil ?? FxChain()
        let node: FxNode
        if entry.key.hasPrefix("job:"), let job = AudioFxJobs.all.first(where: { "job:\($0.id)" == entry.key }) {
            node = AudioFxJobs.node(job, joining: chain)
        } else if entry.key.hasPrefix("add:") {
            let type = String(entry.key.dropFirst(4))
            guard AudioFx.definition(type) != nil else { return .failed }
            node = AudioFxJobs.effectNode(type, joining: chain)
        } else { return .failed }
        let next = FxChain(nodes: chain.nodes + [node])
        let ok = editor.withHistory("Add \(entry.label)") { editor.setClipFxChain(clipId: clipId, AudioFx.serializeChain(next)) }
        return ok ? .applied(clipId: clipId) : .failed
    }

    // MARK: Drawing

    public func draw(_ c: CanvasContext, size: CanvasSize) {
        DockedPanelDraw.background(c, size: size)
        let pad = Self.pad
        searchRect = CanvasRect(x: pad, y: pad, width: max(0, size.width - 2 * pad), height: Self.searchHeight)
        c.fillRoundedRect(searchRect, radius: PanelTheme.radius, PanelTheme.panelInput)
        c.strokeRoundedRect(searchRect.insetBy(0.5), radius: PanelTheme.radius, searchFocused ? PanelTheme.accent : PanelTheme.panelBorderInput, width: 1)
        let shown = query.isEmpty ? "Search effects" : query + (searchFocused ? "|" : "")
        PanelDraw.text(c, shown, in: searchRect.insetX(8), font: PanelTheme.font(12), color: query.isEmpty ? PanelTheme.text4 : PanelTheme.text1)

        var top = searchRect.maxY + 6
        if let status {
            PanelDraw.text(c, status, in: CanvasRect(x: pad, y: top, width: size.width - 2 * pad, height: 16), font: PanelTheme.font(10), color: PanelTheme.text3)
            top += 18
        }
        viewport = CanvasRect(x: 0, y: top, width: size.width, height: max(0, size.height - top))
        layoutTiles(width: size.width, origin: top)
        scrollY = min(max(0, scrollY), max(0, contentHeight - viewport.height))

        let list = entries
        if list.isEmpty {
            DockedPanelDraw.empty(c, size: size, title: "No effects match", detail: "Try a shorter search.")
            return
        }
        c.save()
        c.clip(viewport)
        let clipId = selectedClip()
        let base = clipId.flatMap { editor?.gradeShown(clipId: $0, time: time()) }
        for h in headers where h.rect.maxY - scrollY > viewport.y && h.rect.y - scrollY < viewport.maxY {
            PanelDraw.tracked(c, h.title.uppercased(), in: h.rect.shifted(dy: -scrollY), font: PanelTheme.mono(9), tracking: 0.225, color: PanelTheme.text2)
        }
        for t in tiles {
            let r = t.rect.shifted(dy: -scrollY)
            guard r.maxY > viewport.y, r.y < viewport.maxY else { continue }
            drawTile(c, t.entry, r, base: base, clipId: clipId)
        }
        c.restore()
        PanelScrollbar.draw(c, track: viewport, offset: scrollY, content: contentHeight, hovered: false)
    }

    private func drawTile(_ c: CanvasContext, _ e: EffectEntry, _ r: CanvasRect, base: ColorGrading?, clipId: String?) {
        let on = e.id == highlighted
        if on { c.fillRect(r, PanelTheme.accent.withAlpha(0.1)) }
        let sw = CanvasRect(x: r.x + 1, y: r.y + 1, width: r.width - 2, height: (r.width - 2) * 9 / 16)
        switch e.kind {
        case .video:
            if let spec = EffectSpecs.spec(e.key), let effectPreview {
                let demo = InspectorPanel.effectDemo(spec, base: base ?? ColorGrading(), clipId: clipId)
                let px = InspectorPanel.tilePixels(sw, scale: c.deviceScale)
                let state = effectPreview(EffectPreviewRequest(key: demo.key, grade: demo.grade, clipId: demo.clipId, pixelWidth: px.width, pixelHeight: px.height))
                InspectorPanel.drawPreviewFrame(c, sw, state)
            } else { InspectorPanel.drawPreviewFrame(c, sw, .failed(.noRenderer)) }
        case .audio:
            c.fillRect(sw, PanelTheme.panelSurface)
            PanelDraw.text(c, "AUDIO", in: sw, font: PanelTheme.mono(10), color: PanelTheme.audioViolet, align: .center)
        }
        let hov = e.id == hoveredId
        PanelDraw.text(c, e.label, in: CanvasRect(x: r.x + 6, y: sw.maxY + 4, width: r.width - 12, height: 16), font: PanelTheme.font(10),
                       color: on || hov ? PanelTheme.text1 : PanelTheme.text3)
        c.strokeRect(r.insetBy(0.5), on ? PanelTheme.accent : (hov ? PanelTheme.panelBorderInput : PanelTheme.panelHairline), width: 1)
    }

    /// Places headers and tiles in content coordinates (y from the viewport's top, before scrolling).
    private func layoutTiles(width: Double, origin: Double) {
        tiles = []; headers = []
        let pad = Self.pad, gap = Self.gap
        let avail = max(1, width - 2 * pad)
        let cols = max(1, Int(((avail + gap) / (Self.minTileWidth + gap)).rounded(.down)))
        let w = (avail - gap * Double(cols - 1)) / Double(cols)
        let h = 2 + (w - 2) * 9 / 16 + Self.labelHeight
        var y = origin + 2
        var group: String?
        var col = 0
        for e in entries {
            if e.group != group {
                if col != 0 { y += h + gap; col = 0 }
                group = e.group
                headers.append(Header(title: e.group, rect: CanvasRect(x: pad, y: y, width: avail, height: Self.headerHeight)))
                y += Self.headerHeight
            }
            tiles.append(Placed(entry: e, rect: CanvasRect(x: pad + Double(col) * (w + gap), y: y, width: w, height: h)))
            col += 1
            if col == cols { col = 0; y += h + gap }
        }
        if col != 0 { y += h + gap }
        contentHeight = y - origin + pad
    }

    // MARK: Input

    private func tile(at p: CanvasPoint) -> EffectEntry? {
        guard viewport.contains(p) else { return nil }
        return tiles.last { $0.rect.shifted(dy: -scrollY).contains(p) }?.entry
    }

    public func pointerDown(_ p: CanvasPoint, shift: Bool) -> Bool {
        if searchRect.contains(p) { searchFocused = true; return true }
        let wasFocused = searchFocused
        searchFocused = false
        guard let e = tile(at: p) else { return wasFocused }
        highlighted = e.id
        pressed = (e, p)
        let t = now()
        if let last = lastClick, last.id == e.id, t - last.at < 0.45 {
            lastClick = nil
            apply(e)
        } else { lastClick = (e.id, t) }
        return true
    }

    public func pointerMove(_ p: CanvasPoint) -> Bool {
        if let pressed, draggingEntry == nil, hypot(p.x - pressed.at.x, p.y - pressed.at.y) > 5 {
            draggingEntry = pressed.entry
            lastDraggedEntry = pressed.entry
            lastClick = nil
            return true
        }
        let next = tile(at: p)?.id
        defer { hoveredId = next }
        return draggingEntry != nil || next != hoveredId
    }

    public func pointerUp(_ p: CanvasPoint) -> Bool {
        defer { pressed = nil }
        let was = draggingEntry != nil
        draggingEntry = nil
        return was
    }

    public func scroll(dy: Double) -> Bool {
        let next = min(max(0, scrollY + dy), max(0, contentHeight - viewport.height))
        defer { scrollY = next }
        return next != scrollY
    }

    public func keyDown(_ k: EditorKey) -> Bool {
        switch k.code {
        case .enter:
            guard let e = highlighted.flatMap(EffectsCatalog.entry(id:)) ?? (query.isEmpty ? nil : entries.first) else { return false }
            highlighted = e.id
            apply(e)
            return true
        case .up, .down, .left, .right:
            guard searchFocused || highlighted != nil else { return false }
            let list = entries
            guard !list.isEmpty else { return true }
            let cols = max(1, Int(((viewport.width - 2 * Self.pad + Self.gap) / (Self.minTileWidth + Self.gap)).rounded(.down)))
            let step: Int
            switch k.code { case .left: step = -1; case .right: step = 1; case .up: step = -cols; default: step = cols }
            let i = highlighted.flatMap { id in list.firstIndex { $0.id == id } } ?? (step > 0 ? -1 : list.count)
            let j = min(max(0, i + step), list.count - 1)
            highlighted = list[j].id
            reveal(list[j])
            return true
        case .escape:
            guard searchFocused || !query.isEmpty else { return false }
            if query.isEmpty { searchFocused = false } else { setQuery("") }
            return true
        case .backspace where searchFocused:
            setQuery(String(query.dropLast()))
            return true
        case .char(let ch) where searchFocused && !k.command && !k.alt:
            setQuery(query + String(ch))
            return true
        case .space where searchFocused:
            setQuery(query + " ")
            return true
        default: return false
        }
    }

    private func reveal(_ e: EffectEntry) {
        guard let t = tiles.first(where: { $0.entry == e }) else { return }
        if t.rect.y - 4 < viewport.y + scrollY { scrollY = max(0, t.rect.y - viewport.y - 4) }
        else if t.rect.maxY > viewport.maxY + scrollY { scrollY = t.rect.maxY - viewport.maxY + 4 }
    }

    public var hint: String? { "Double-click, press Return or drag an effect onto a clip to apply it" }
}

private extension CanvasRect {
    func shifted(dy: Double) -> CanvasRect { CanvasRect(x: x, y: y + dy, width: width, height: height) }
    func insetX(_ d: Double) -> CanvasRect { CanvasRect(x: x + d, y: y, width: width - 2 * d, height: height) }
}
