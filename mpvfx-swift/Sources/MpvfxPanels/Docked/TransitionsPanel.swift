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

/// The Transitions browser (dock id `transitions`): every transition in groups, a search field and a star that keeps
/// favourites at the top. Each tile plays the transition on the two clips around the selected cut (two neutral
/// colour cards with none) while the pointer is on it or it is highlighted. Return, a double click or a drop on a cut
/// in the timeline applies the highlighted one; each is one undo step.
public final class TransitionsPanel: DockedPanelView {
    public var editor: TimelineEditor?
    /// The selected clips; "the selected cut" is derived from them (`TimelineEditor.cuts(forSelection:)`).
    public var selection: () -> Set<String> = { [] }
    /// The host's tile renderer for a clip's own picture (the Effects tiles' renderer): a request for `clipId` with no
    /// grade changes. Without one, or while a picture renders, the tile shows the neutral cards.
    public var clipPicture: ((EffectPreviewRequest) -> PresetPreviewState)?
    /// After a document edit from this panel (the host saves and redraws).
    public var onEdited: (() -> Void)?
    /// Asks the host to call `tick` (~60 Hz) until it returns false; `animating` is the host's flag that it is.
    public var onAnimate: (() -> Void)?
    public var animating = false
    /// Called with the favourites after each star change (the host saves them in the panel preferences).
    public var onFavouritesChange: (([String]) -> Void)?
    /// Seconds, for double-click timing.
    public var now: () -> Double = { Date().timeIntervalSince1970 }

    public private(set) var query = ""
    public private(set) var searchFocused = false
    public private(set) var highlighted: String?
    /// What the last apply or the highlighted tile says, under the search field.
    public private(set) var status: String?
    /// Starred entry ids, in the order starred.
    public private(set) var favourites: [String]
    public private(set) var draggingEntry: TransitionEntry?
    public private(set) var lastDraggedEntry: TransitionEntry?
    /// Where the playing tile is in its loop (0...1), and the entry that plays.
    public private(set) var phase = 0.0
    public private(set) var hoveredId: String?

    struct Placed { var entry: TransitionEntry; var rect: CanvasRect; var thumb: CanvasRect; var star: CanvasRect }
    struct Header { var title: String; var rect: CanvasRect }
    private(set) var tiles: [Placed] = []
    private var headers: [Header] = []
    private(set) var scrollY = 0.0
    private var contentHeight = 0.0
    private var viewport = CanvasRect(x: 0, y: 0, width: 0, height: 0)
    private var searchRect = CanvasRect(x: 0, y: 0, width: 0, height: 0)
    private var pressed: (entry: TransitionEntry, at: CanvasPoint)?
    private var lastClick: (id: String, at: Double)?

    static let pad = 8.0, gap = 6.0, minTileWidth = 120.0, searchHeight = 28.0, headerHeight = 22.0, labelHeight = 24.0, starSize = 18.0
    static let favouritesGroup = "Favourites"

    public init(favourites: [String] = []) { self.favourites = TransitionCatalog.favourites(favourites).map(\.id) }

    /// The entries as shown: the starred ones first (in the order starred), then the others in catalogue order, all
    /// filtered by the search.
    public var entries: [TransitionEntry] {
        let matching = TransitionCatalog.entries(matching: query)
        let starred = favourites.compactMap { id in matching.first { $0.id == id } }
        return starred + matching.filter { !favourites.contains($0.id) }
    }

    func group(of e: TransitionEntry) -> String { favourites.contains(e.id) ? Self.favouritesGroup : e.group }

    // MARK: Search and favourites

    public func setQuery(_ text: String) {
        query = String(text.prefix(80))
        scrollY = 0
        if let h = highlighted, !entries.contains(where: { $0.id == h }) { highlighted = nil }
    }

    public func isFavourite(_ e: TransitionEntry) -> Bool { favourites.contains(e.id) }

    /// Stars or unstars `e`; the host is told so it can save the list.
    public func toggleFavourite(_ e: TransitionEntry) {
        if let i = favourites.firstIndex(of: e.id) { favourites.remove(at: i) } else { favourites.append(e.id) }
        onFavouritesChange?(favourites)
    }

    // MARK: Applying

    /// The cuts an apply goes to now.
    public var selectedCuts: [TimelineCut] { editor.map { $0.cuts(forSelection: selection()) } ?? [] }

    /// Puts `entry` on the selected cut(s) as one undo step; says why when it could not.
    @discardableResult
    public func apply(_ entry: TransitionEntry) -> [TransitionApplyOutcome] {
        guard let editor else { return [] }
        let cuts = selectedCuts
        guard !cuts.isEmpty else { status = "Select a clip next to a cut, or two clips that touch, to apply \(entry.label)."; return [] }
        return apply(entry, to: cuts, editor: editor)
    }

    /// Puts `entry` on `cut` (a drop on a cut in the timeline) as one undo step.
    @discardableResult
    public func apply(_ entry: TransitionEntry, to cut: TimelineCut) -> [TransitionApplyOutcome] {
        guard let editor else { return [] }
        return apply(entry, to: [cut], editor: editor)
    }

    private func apply(_ entry: TransitionEntry, to cuts: [TimelineCut], editor: TimelineEditor) -> [TransitionApplyOutcome] {
        let outcomes = editor.applyTransition(entry.kind, direction: entry.direction, color: entry.color, to: cuts)
        let done = outcomes.filter(\.applied).count
        if done > 0 { onEdited?() }
        if done == 0, case .refused(let why)? = outcomes.first { status = why; return outcomes }
        var message = done == 1 ? "Added \(entry.label)." : "Added \(entry.label) to \(done) cuts."
        if let length = outcomes.lazy.compactMap(\.shortenedLength).first {
            message += " Shortened to \(Self.frames(length)): the media allows no more than that."
        }
        if done < outcomes.count { message += " \(outcomes.count - done) could not take it." }
        status = message
        return outcomes
    }

    static func frames(_ n: Double) -> String { n == 1 ? "1 frame" : "\(PanelFormat.number(n, decimals: 0)) frames" }

    // MARK: Drawing

    public func draw(_ c: CanvasContext, size: CanvasSize) {
        DockedPanelDraw.background(c, size: size)
        let pad = Self.pad
        searchRect = CanvasRect(x: pad, y: pad, width: max(0, size.width - 2 * pad), height: Self.searchHeight)
        c.fillRoundedRect(searchRect, radius: PanelTheme.radius, PanelTheme.panelInput)
        c.strokeRoundedRect(searchRect.insetBy(0.5), radius: PanelTheme.radius, searchFocused ? PanelTheme.accent : PanelTheme.panelBorderInput, width: 1)
        let shown = query.isEmpty ? "Search transitions" : query + (searchFocused ? "|" : "")
        PanelDraw.text(c, shown, in: searchRect.insetX(8), font: PanelTheme.font(12), color: query.isEmpty ? PanelTheme.text4 : PanelTheme.text1)

        var top = searchRect.maxY + 6
        let note = status ?? hint(for: hoveredId ?? highlighted)
        if let note {
            PanelDraw.text(c, note, in: CanvasRect(x: pad, y: top, width: size.width - 2 * pad, height: 16), font: PanelTheme.font(10), color: PanelTheme.text3)
            top += 18
        }
        viewport = CanvasRect(x: 0, y: top, width: size.width, height: max(0, size.height - top))
        layoutTiles(width: size.width, origin: top)
        scrollY = min(max(0, scrollY), max(0, contentHeight - viewport.height))

        if entries.isEmpty {
            DockedPanelDraw.empty(c, size: size, title: "No transitions match", detail: "Try a shorter search.")
            return
        }
        c.save()
        c.clip(viewport)
        let cut = selectedCuts.first
        let sides = cut.map { cutPictures(for: $0, thumb: tiles.first?.thumb ?? .init(x: 0, y: 0, width: 160, height: 90), scale: c.deviceScale) }
        let playing = hoveredId ?? highlighted
        for h in headers where h.rect.maxY - scrollY > viewport.y && h.rect.y - scrollY < viewport.maxY {
            PanelDraw.tracked(c, h.title.uppercased(), in: h.rect.shifted(dy: -scrollY), font: PanelTheme.mono(9), tracking: 0.225, color: PanelTheme.text2)
        }
        for t in tiles {
            let r = t.rect.shifted(dy: -scrollY)
            guard r.maxY > viewport.y, r.y < viewport.maxY else { continue }
            drawTile(c, t, shifted: -scrollY, cut: cut, pictures: sides, playing: t.entry.id == playing)
        }
        c.restore()
        PanelScrollbar.draw(c, track: viewport, offset: scrollY, content: contentHeight, hovered: false)
    }

    /// The two clips' pictures at the tile's size, nil until both are ready.
    private func cutPictures(for cut: TimelineCut, thumb: CanvasRect, scale: Double) -> (from: TransitionTile.Side, to: TransitionTile.Side)? {
        guard let clipPicture else { return nil }
        let px = InspectorPanel.tilePixels(thumb, scale: scale)
        func side(_ id: String) -> TransitionTile.Side? {
            if case .ready(let image) = clipPicture(EffectPreviewRequest(key: "transition-tile", grade: NativeJSONObject(), clipId: id, pixelWidth: px.width, pixelHeight: px.height)) {
                return .image(image)
            }
            return nil
        }
        guard let a = side(cut.fromClipId), let b = side(cut.toClipId) else { return nil }
        return (a, b)
    }

    private func neutral() -> (from: TransitionTile.Side, to: TransitionTile.Side) {
        (.color(PanelTheme.neutral600), .color(PanelTheme.accent))
    }

    /// The length a tile plays for: the transition's fitted length on the selected cut, else the default.
    private func length(of e: TransitionEntry, cut: TimelineCut?) -> Double {
        cut.flatMap { editor?.transitionFit(e.kind, on: $0)?.length } ?? TimelineEditor.defaultTransitionFrames
    }

    private func drawTile(_ c: CanvasContext, _ t: Placed, shifted dy: Double, cut: TimelineCut?,
                          pictures: (from: TransitionTile.Side, to: TransitionTile.Side)?, playing: Bool) {
        let e = t.entry
        let r = t.rect.shifted(dy: dy), thumb = t.thumb.shifted(dy: dy)
        let on = e.id == highlighted
        if on { c.fillRect(r, PanelTheme.accent.withAlpha(0.1)) }
        let sides = pictures ?? neutral()
        let p = playing ? TransitionTile.progress(phase: phase, lengthFrames: length(of: e, cut: cut)) : 0.5
        TransitionTile.draw(c, thumb, entry: e, progress: p, from: sides.from, to: sides.to)
        if let cut, let fit = editor?.transitionFit(e.kind, on: cut), fit.length < fit.wanted {
            PanelDraw.text(c, "\(PanelFormat.number(fit.length, decimals: 0))f", in: CanvasRect(x: thumb.x + 4, y: thumb.y + 2, width: 40, height: 14),
                           font: PanelTheme.mono(9), color: PanelTheme.stageInk)
        }
        drawStar(c, t.star.shifted(dy: dy), on: isFavourite(e))
        let hov = e.id == hoveredId
        PanelDraw.text(c, e.label, in: CanvasRect(x: r.x + 6, y: thumb.maxY + 4, width: r.width - 12, height: 16), font: PanelTheme.font(10),
                       color: on || hov ? PanelTheme.text1 : PanelTheme.text3)
        c.strokeRect(r.insetBy(0.5), on ? PanelTheme.accent : (hov ? PanelTheme.panelBorderInput : PanelTheme.panelHairline), width: 1)
    }

    /// A five-point star: filled when starred, an outline otherwise, on a dark scrim so it reads over any picture.
    private func drawStar(_ c: CanvasContext, _ r: CanvasRect, on: Bool) {
        c.fillRoundedRect(r, radius: 3, PanelTheme.stageScrim)
        let cx = r.x + r.width / 2, cy = r.y + r.height / 2 + 0.5, outer = r.width * 0.36, inner = outer * 0.42
        var path = CanvasPath()
        for i in 0..<10 {
            let radius = i % 2 == 0 ? outer : inner
            let a = -Double.pi / 2 + Double(i) * Double.pi / 5
            let pt = CanvasPoint(cx + radius * cos(a), cy + radius * sin(a))
            if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
        }
        path.close()
        if on { c.fill(path, PanelTheme.stageInk) }
        else { c.stroke(path, PanelTheme.stageInk.withAlpha(0.8), StrokeStyle(width: 1)) }
    }

    private func hint(for id: String?) -> String? {
        guard let id, let e = TransitionCatalog.entry(id: id) else { return nil }
        guard let cut = selectedCuts.first, let fit = editor?.transitionFit(e.kind, on: cut) else { return nil }
        return fit.length < fit.wanted ? "\(e.label): shortened to \(Self.frames(fit.length)) by the media." : nil
    }

    /// Places headers and tiles in content coordinates (y from the viewport's top, before scrolling).
    private func layoutTiles(width: Double, origin: Double) {
        tiles = []; headers = []
        let pad = Self.pad, gap = Self.gap
        let avail = max(1, width - 2 * pad)
        let cols = max(1, Int(((avail + gap) / (Self.minTileWidth + gap)).rounded(.down)))
        let w = (avail - gap * Double(cols - 1)) / Double(cols)
        let thumbH = (w - 2) * 9 / 16
        let h = 2 + thumbH + Self.labelHeight
        var y = origin + 2
        var current: String?
        var col = 0
        for e in entries {
            let g = group(of: e)
            if g != current {
                if col != 0 { y += h + gap; col = 0 }
                current = g
                headers.append(Header(title: g, rect: CanvasRect(x: pad, y: y, width: avail, height: Self.headerHeight)))
                y += Self.headerHeight
            }
            let rect = CanvasRect(x: pad + Double(col) * (w + gap), y: y, width: w, height: h)
            let thumb = CanvasRect(x: rect.x + 1, y: rect.y + 1, width: w - 2, height: thumbH)
            let star = CanvasRect(x: thumb.maxX - Self.starSize - 3, y: thumb.y + 3, width: Self.starSize, height: Self.starSize)
            tiles.append(Placed(entry: e, rect: rect, thumb: thumb, star: star))
            col += 1
            if col == cols { col = 0; y += h + gap }
        }
        if col != 0 { y += h + gap }
        contentHeight = y - origin + pad
    }

    // MARK: Input

    private func tile(at p: CanvasPoint) -> Placed? {
        guard viewport.contains(p) else { return nil }
        return tiles.last { $0.rect.shifted(dy: -scrollY).contains(p) }
    }

    public func pointerDown(_ p: CanvasPoint, shift: Bool) -> Bool {
        if searchRect.contains(p) { searchFocused = true; return true }
        let wasFocused = searchFocused
        searchFocused = false
        guard let t = tile(at: p) else { return wasFocused }
        highlighted = t.entry.id
        status = nil
        if t.star.shifted(dy: -scrollY).contains(p) { toggleFavourite(t.entry); lastClick = nil; return true }
        pressed = (t.entry, p)
        let when = now()
        if let last = lastClick, last.id == t.entry.id, when - last.at < 0.45 {
            lastClick = nil
            apply(t.entry)
        } else { lastClick = (t.entry.id, when) }
        return true
    }

    public func pointerMove(_ p: CanvasPoint) -> Bool {
        if let pressed, draggingEntry == nil, hypot(p.x - pressed.at.x, p.y - pressed.at.y) > 5 {
            draggingEntry = pressed.entry
            lastDraggedEntry = pressed.entry
            lastClick = nil
            return true
        }
        let next = tile(at: p)?.entry.id
        let changed = next != hoveredId
        hoveredId = next
        if changed { phase = 0; if next != nil { onAnimate?() } }
        return draggingEntry != nil || changed
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

    /// Moves the playing tile on by `dt` seconds; true while a tile plays (the host keeps ticking).
    public func tick(_ dt: Double) -> Bool {
        guard let id = hoveredId ?? highlighted, let e = TransitionCatalog.entry(id: id) else { return false }
        phase = (phase + dt / TransitionTile.loopSeconds(lengthFrames: length(of: e, cut: selectedCuts.first))).truncatingRemainder(dividingBy: 1)
        return true
    }

    public func keyDown(_ k: EditorKey) -> Bool {
        switch k.code {
        case .enter:
            guard let e = highlighted.flatMap(TransitionCatalog.entry(id:)) ?? (query.isEmpty ? nil : entries.first) else { return false }
            highlighted = e.id
            apply(e)
            return true
        case .up, .down, .left, .right:
            let list = entries
            guard !list.isEmpty else { return true }
            let cols = max(1, Int(((viewport.width - 2 * Self.pad + Self.gap) / (Self.minTileWidth + Self.gap)).rounded(.down)))
            let step: Int
            switch k.code { case .left: step = -1; case .right: step = 1; case .up: step = -cols; default: step = cols }
            let i = highlighted.flatMap { id in list.firstIndex { $0.id == id } } ?? (step > 0 ? -1 : list.count)
            let j = min(max(0, i + step), list.count - 1)
            highlighted = list[j].id
            status = nil; phase = 0
            reveal(list[j])
            onAnimate?()
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
        case .char(let ch) where !searchFocused && !k.command && !k.alt && ch.lowercased() == "f":
            guard let e = highlighted.flatMap(TransitionCatalog.entry(id:)) else { return false }
            toggleFavourite(e)
            return true
        case .space where searchFocused:
            setQuery(query + " ")
            return true
        default: return false
        }
    }

    private func reveal(_ e: TransitionEntry) {
        guard let t = tiles.first(where: { $0.entry == e }) else { return }
        if t.rect.y - 4 < viewport.y + scrollY { scrollY = max(0, t.rect.y - viewport.y - 4) }
        else if t.rect.maxY > viewport.maxY + scrollY { scrollY = t.rect.maxY - viewport.maxY + 4 }
    }

    public var hint: String? { "Double-click, press Return or drag a transition onto a cut to apply it; F stars it" }
}

private extension CanvasRect {
    func shifted(dy: Double) -> CanvasRect { CanvasRect(x: x, y: y + dy, width: width, height: height) }
    func insetX(_ d: Double) -> CanvasRect { CanvasRect(x: x + d, y: y, width: width - 2 * d, height: height) }
}
