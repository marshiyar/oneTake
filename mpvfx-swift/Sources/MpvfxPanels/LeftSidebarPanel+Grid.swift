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

/// The search row (field, filter button, the active filter's line) and the scrolling grid of sections.
extension LeftSidebarPanel {
    /// Anything to search: project files, or library files and exports in the shown library.
    var hasContent: Bool {
        !items.isEmpty || !(activeLibrary?.exports.isEmpty ?? true) || activeLibrary?.assets.contains { $0.eventId == activeEvent?.id } == true
    }

    func drawSearchRow(_ c: CanvasContext, top: Double) -> Double {
        guard hasContent else { return top }
        let x0 = M.inset, x1 = size.width - M.inset
        let fb = CanvasRect(x: x1 - M.control, y: top, width: M.control, height: M.control)
        drawSearchField(c, CanvasRect(x: x0, y: top, width: max(0, fb.x - M.controlGap - x0), height: M.control))
        drawIconButton(c, fb, icon: .filter, hit: .filter, active: !filter.isDefault)
        let y = top + M.control + M.rowGap
        return filter.isDefault ? y : drawFilterSummary(c, top: y)
    }

    func drawSearchField(_ c: CanvasContext, _ sr: CanvasRect) {
        c.fillRoundedRect(sr, radius: PanelTheme.radiusMd, PanelTheme.panelInput)
        drawMagnifier(c, CanvasRect(x: sr.x + 10, y: sr.midY - 6, width: 12, height: 12))
        let editing = search != nil, text = search?.draft ?? searchQuery, font = PanelTheme.font(PanelTheme.textXs)
        let tr = CanvasRect(x: sr.x + 28, y: sr.y, width: max(0, sr.width - 28 - 28), height: sr.height)
        PanelDraw.text(c, text.isEmpty && !editing ? "Search media…" : text, in: tr, font: font, color: text.isEmpty ? PanelTheme.text2 : PanelTheme.text0)
        if editing {
            PanelDraw.focusRing(c, sr, radius: PanelTheme.radiusMd)
            let tw = min(tr.width, c.measureText(text, font: font).width)
            c.fillRect(CanvasRect(x: tr.x + tw + 1, y: sr.midY - 7, width: 1, height: 14), PanelTheme.text1)
        }
        hits.add(sr, .search)
        guard !text.isEmpty else { return }
        let cr = CanvasRect(x: sr.maxX - 2 - M.tileAction, y: sr.midY - M.tileAction / 2, width: M.tileAction, height: M.tileAction)
        PanelIcon.close.draw(c, in: cr.insetBy(7), color: hovered == .clearSearch ? PanelTheme.text1 : PanelTheme.text3)
        hits.add(cr, .clearSearch)
    }

    /// "Video · Not in the timeline" and Clear, while the filter is not the default.
    func drawFilterSummary(_ c: CanvasContext, top: Double) -> Double {
        let x0 = M.inset, x1 = size.width - M.inset, font = PanelTheme.font(11), h = M.tileAction
        let clearW = c.measureText("Clear", font: font).width + 16
        let clear = CanvasRect(x: x1 - clearW, y: top, width: clearW, height: h)
        PanelDraw.text(c, filter.summary.joined(separator: " · "), in: CanvasRect(x: x0, y: top, width: max(0, clear.x - 8 - x0), height: h),
                       font: font, color: PanelTheme.text2)
        PanelDraw.text(c, "Clear", in: clear, font: PanelTheme.font(11, .medium), color: hovered == .clearFilters ? PanelTheme.text1 : PanelTheme.accent, align: .center)
        hits.add(clear, .clearFilters)
        return top + h + M.rowGap
    }

    /// SearchInput's glyph: 256 view box, circle (116,116) r76 and a round-capped line to (232,232), stroke 22.
    func drawMagnifier(_ c: CanvasContext, _ r: CanvasRect) {
        c.strokeSVG(["M192 116a76 76 0 1 0-152 0 76 76 0 1 0 152 0Z"], viewBox: 256, in: r, PanelTheme.text3, width: 22, round: false)
        c.strokeSVG(["M170 170 232 232"], viewBox: 256, in: r, PanelTheme.text3, width: 22)
    }

    // MARK: Grid

    func drawGrid(_ c: CanvasContext, _ r: CanvasRect) {
        binRect = r
        hits.add(r, .binArea)
        tileFrames = []
        auditionBars = [:]
        let list = sections
        c.withState {
            c.clip(r)
            guard !list.isEmpty else { drawEmpty(c, r); return }
            var y = r.y - binScroll
            for (i, s) in list.enumerated() { y = drawSection(c, s, top: y + (i == 0 ? 0 : M.sectionGap), clip: r) }
            binMax = max(0, y + binScroll - r.maxY + M.rowGap)
            binScroller.clamp(max: binMax)
        }
        if list.isEmpty { binMax = 0; binScroller.clamp(max: 0) }
        if let ref = pendingReveal, tileFrames.contains(where: { $0.0 == ref }) {
            pendingReveal = nil
            scrollIntoView(ref)
            onChange?()
        }
        // The grid scrolls under the search row: a hairline marks the edge only while something is under it.
        if binScroll > 0.5 { PanelDraw.hline(c, x0: 0, x1: r.maxX, y: r.y, PanelTheme.panelHairline) }
        PanelScrollbar.draw(c, track: r, offset: binScroll, content: r.height + binMax, hovered: false, opacity: binScroller.barOpacity)
    }

    /// Title and count, then the tiles (a grid) or rows (audio, fonts). Returns the y under the section.
    func drawSection(_ c: CanvasContext, _ s: MediaSection, top: Double, clip: CanvasRect) -> Double {
        let x0 = M.inset, w = size.width - 2 * M.inset
        let t = PanelDraw.text(c, s.title, in: CanvasRect(x: x0, y: top, width: w, height: M.sectionHeader), font: PanelTheme.font(PanelTheme.textXs, .semibold),
                               color: PanelTheme.text1)
        PanelDraw.text(c, "\(s.tiles.count)", in: CanvasRect(x: x0 + t.width + 6, y: top, width: 48, height: M.sectionHeader), font: PanelTheme.font(11),
                       color: PanelTheme.text2)
        var y = top + M.sectionHeader
        guard s.layout == .grid else {
            for ref in s.tiles { y = drawRow(c, ref, CanvasRect(x: x0, y: y, width: w, height: M.row), clip: clip) }
            return y
        }
        let cols = M.columns(w), tw = M.tileWidth(w, columns: cols), th = M.tileHeight(tw)
        for (i, ref) in s.tiles.enumerated() {
            let col = i % cols, row = i / cols
            drawTile(c, ref, CanvasRect(x: x0 + Double(col) * (tw + M.tileGap), y: y + Double(row) * (th + M.tileGap), width: tw, height: th), clip: clip)
        }
        let rows = (s.tiles.count + cols - 1) / cols
        return y + Double(rows) * th + Double(max(0, rows - 1)) * M.tileGap
    }

    /// Records where a tile is in the content (for the arrows and scrolling it into view), then whether it shows.
    func place(_ ref: MediaTileRef, _ r: CanvasRect, clip: CanvasRect) -> Bool {
        tileFrames.append((ref, CanvasRect(x: r.x, y: r.y + binScroll - clip.y, width: r.width, height: r.height)))
        return r.maxY > clip.y && r.y < clip.maxY
    }

    func isLit(_ ref: MediaTileRef) -> Bool {
        hovered == .tile(ref) || hovered == .tileAction(ref) || hovered == .tileAudition(ref) || hovered == .auditionBar(ref) || menu?.target == ref
    }

    func drawTile(_ c: CanvasContext, _ ref: MediaTileRef, _ r: CanvasRect, clip: CanvasRect) {
        guard place(ref, r, clip: clip) else { return }
        let thumb = CanvasRect(x: r.x, y: r.y, width: r.width, height: r.width * M.thumbAspect)
        let lit = isLit(ref), sel = selected == ref
        c.fillRoundedRect(thumb, radius: PanelTheme.radiusMd, PanelTheme.neutral900)
        drawThumbContent(c, ref, thumb)
        drawBadges(c, ref, thumb)
        if sel { c.strokeRoundedRect(thumb.insetBy(1), radius: PanelTheme.radiusMd - 1, PanelTheme.accent, width: 2) }
        else if lit { c.strokeRoundedRect(thumb.insetBy(0.5), radius: PanelTheme.radiusMd, PanelTheme.text4, width: 1) }
        drawTileName(c, ref, CanvasRect(x: r.x, y: thumb.maxY + M.nameTop, width: r.width, height: M.nameLine * Double(M.nameLines)), lit: lit || sel)
        addClipped(r, .tile(ref), to: clip)
        if lit || sel, let icon = actionIcon(ref) {
            let a = CanvasRect(x: thumb.maxX - M.badgeInset - M.tileAction, y: thumb.y + M.badgeInset, width: M.tileAction, height: M.tileAction)
            drawTileAction(c, a, icon: icon, hot: hovered == .tileAction(ref))
            addClipped(a, .tileAction(ref), to: clip)
        }
        drawGridAudition(c, ref, thumb, lit: lit || sel, clip: clip)
    }

    /// The hover button's icon: add for media and library files, save for a finished export; none otherwise.
    func actionIcon(_ ref: MediaTileRef) -> PanelIcon? {
        switch ref {
        case .media(let id): return mediaItem(id)?.category == .fonts ? nil : .plus
        case .library(let id): return libraryAsset(id)?.available == true ? .plus : nil
        case .export(let id): return export(id)?.status == "complete" ? .download : nil
        }
    }

    func drawTileAction(_ c: CanvasContext, _ a: CanvasRect, icon: PanelIcon, hot: Bool) {
        c.fillRoundedRect(a, radius: a.height / 2, hot ? PanelTheme.primaryFill : PanelTheme.neutral950.withAlpha(0.85))
        icon.draw(c, in: a.insetBy(6), color: hot ? PanelTheme.onAccent : PanelTheme.text1, lineWidth: 2.5)
    }

    /// The picture fills the 16:9 tile (cut to its middle) for every shape of media, so the grid reads as one
    /// even surface; without a picture, the kind's glyph.
    func drawThumbContent(_ c: CanvasContext, _ ref: MediaTileRef, _ thumb: CanvasRect) {
        if case .media(let id) = ref, let img = thumbnail(id) {
            c.withState {
                c.clip(.roundedRect(thumb, radius: PanelTheme.radiusMd))
                c.drawImage(img, in: MediaTileDraw.fill(CanvasSize(Double(img.width), Double(img.height)), in: thumb))
            }
            return
        }
        glyph(ref).draw(c, in: CanvasRect(x: thumb.midX - 10, y: thumb.midY - 10, width: 20, height: 20), color: PanelTheme.text3, lineWidth: 1.75)
    }

    func glyph(_ ref: MediaTileRef) -> PanelIcon {
        switch ref {
        case .media(let id): return MediaTileDraw.glyph(kind: mediaItem(id)?.category.rawValue ?? "")
        case .library(let id): return MediaTileDraw.glyph(kind: libraryAsset(id)?.kind ?? "")
        case .export: return .download
        }
    }

    /// Top left: a check when the file is in the timeline, or "Missing" for a library file whose original is gone.
    /// Bottom right: the duration.
    func drawBadges(_ c: CanvasContext, _ ref: MediaTileRef, _ thumb: CanvasRect) {
        let corner = CanvasPoint(thumb.x + M.badgeInset, thumb.y + M.badgeInset)
        switch ref {
        case .media(let id):
            guard let item = mediaItem(id) else { return }
            if item.used { MediaTileDraw.checkBadge(c, at: corner) }
            if let d = item.duration, let s = Self.binDuration(d) { MediaTileDraw.badge(c, s, right: thumb.maxX - M.badgeInset, bottom: thumb.maxY - M.badgeInset) }
        case .library(let id):
            if libraryAsset(id)?.available == false { MediaTileDraw.badge(c, "Missing", left: corner.x, top: corner.y, color: PanelTheme.red400) }
        case .export: break
        }
    }

    /// Two end-truncated lines (the full name is in the tooltip); an export's second line is its status.
    func drawTileName(_ c: CanvasContext, _ ref: MediaTileRef, _ r: CanvasRect, lit: Bool) {
        let font = PanelTheme.font(11), color = lit ? PanelTheme.text1 : PanelTheme.text2
        if case .export(let id) = ref, let e = export(id) {
            let first = MediaTileText.lines(c, e.label, font: font, width: r.width, maxLines: 1)
            if first.truncated { truncatedNames.insert(ref) }
            PanelDraw.text(c, first.lines.first ?? "", in: CanvasRect(x: r.x, y: r.y, width: r.width, height: M.nameLine), font: font, color: color)
            PanelDraw.text(c, e.status.capitalized, in: CanvasRect(x: r.x, y: r.y + M.nameLine, width: r.width, height: M.nameLine), font: font, color: PanelTheme.text2)
            return
        }
        let wrapped = MediaTileText.lines(c, fullName(ref), font: font, width: r.width, maxLines: M.nameLines)
        if wrapped.truncated { truncatedNames.insert(ref) }
        for (i, line) in wrapped.lines.enumerated() {
            PanelDraw.text(c, line, in: CanvasRect(x: r.x, y: r.y + Double(i) * M.nameLine, width: r.width, height: M.nameLine), font: font, color: color)
        }
    }

    /// An audio or font row: the kind's glyph, the name, then duration, timeline use and level bars (audio) or
    /// the extension (fonts); the add button at the right end while lit.
    func drawRow(_ c: CanvasContext, _ ref: MediaTileRef, _ r: CanvasRect, clip: CanvasRect) -> Double {
        guard place(ref, r, clip: clip), case .media(let id) = ref, let item = mediaItem(id) else { return r.maxY }
        let lit = isLit(ref) || selected == ref
        drawRowChrome(c, ref, r, lit: lit)
        let action = lit ? actionIcon(ref) : nil
        let tile = CanvasRect(x: r.x + 6, y: r.midY - 16, width: 32, height: 32)
        let tx = tile.maxX + 10, right = r.maxX - 8 - (action == nil ? 0 : M.tileAction + 4)
        PanelDraw.text(c, item.name, in: CanvasRect(x: tx, y: r.y + 7, width: max(0, right - tx), height: 16), font: PanelTheme.font(PanelTheme.textXs, .medium),
                       color: lit ? PanelTheme.text0 : PanelTheme.text1)
        drawRowDetail(c, item, CanvasRect(x: tx, y: r.y + 25, width: max(0, right - tx), height: 16))
        addClipped(r, .tile(ref), to: clip)
        if let action {
            let a = CanvasRect(x: r.maxX - 4 - M.tileAction, y: r.midY - M.tileAction / 2, width: M.tileAction, height: M.tileAction)
            drawTileAction(c, a, icon: action, hot: hovered == .tileAction(ref))
            addClipped(a, .tileAction(ref), to: clip)
        }
        drawRowAudition(c, ref, r, lit: lit, hasAction: action != nil, clip: clip)
        return r.maxY
    }

    /// The row's hover or selection wash and ring, and its kind glyph.
    func drawRowChrome(_ c: CanvasContext, _ ref: MediaTileRef, _ r: CanvasRect, lit: Bool) {
        if lit { c.fillRoundedRect(r, radius: PanelTheme.radiusMd, PanelTheme.panelHover.withAlpha(0.6)) }
        if selected == ref { c.strokeRoundedRect(r.insetBy(1), radius: PanelTheme.radiusMd - 1, PanelTheme.accent, width: 2) }
        let tile = CanvasRect(x: r.x + 6, y: r.midY - 16, width: 32, height: 32)
        c.fillRoundedRect(tile, radius: PanelTheme.radius, PanelTheme.neutral900)
        glyph(ref).draw(c, in: tile.insetBy(9), color: PanelTheme.text3, lineWidth: 1.75)
    }

    func drawRowDetail(_ c: CanvasContext, _ item: MediaBinItem, _ r: CanvasRect) {
        let ext = (item.name as NSString).pathExtension.uppercased()
        var parts = [item.category == .fonts ? ext : (item.duration.flatMap(Self.binDuration) ?? ext)]
        if item.used { parts.append("In the timeline") }
        let font = PanelTheme.font(10)
        let t = PanelDraw.text(c, parts.joined(separator: " · "), in: r, font: font, color: PanelTheme.text2)
        guard item.category == .audio, let levels = bars(item.id), !levels.isEmpty else { return }
        MediaTileDraw.levels(c, levels, in: CanvasRect(x: r.x + t.width + 8, y: r.y + 2, width: max(0, r.width - t.width - 8), height: r.height - 3))
    }

    /// assetHelpers.formatDuration: MM:SS of the rounded seconds; nothing for non-positive or non-finite values.
    static func binDuration(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let t = Int(seconds.rounded())
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    /// Nothing to show: the drop zone, or, when a search or filter hides everything, the way back.
    func drawEmpty(_ c: CanvasContext, _ list: CanvasRect) {
        guard hasContent else {
            let ic = CanvasRect(x: list.midX - 12, y: list.midY - 30, width: 24, height: 24)
            PanelIcon.upload.draw(c, in: ic, color: PanelTheme.text3)
            PanelDraw.text(c, "Drop media files here", in: CanvasRect(x: list.x, y: ic.maxY + 10, width: list.width, height: 16),
                           font: PanelTheme.font(PanelTheme.textXs), color: PanelTheme.text1, align: .center)
            PanelDraw.text(c, "or use Import", in: CanvasRect(x: list.x, y: ic.maxY + 28, width: list.width, height: 14),
                           font: PanelTheme.font(11), color: PanelTheme.text2, align: .center)
            return
        }
        let searching = !searchQuery.isEmpty, label = searching ? "Clear search" : "Clear filters"
        PanelDraw.text(c, searching ? "No media matches “\(searchQuery)”" : "No media matches the filter",
                       in: CanvasRect(x: M.inset, y: list.y + 40, width: list.width - 2 * M.inset, height: 16), font: PanelTheme.font(PanelTheme.textXs),
                       color: PanelTheme.text2, align: .center)
        let bw = c.measureText(label, font: PanelTheme.font(11, .medium)).width + 24
        let b = CanvasRect(x: list.midX - bw / 2, y: list.y + 64, width: bw, height: M.control)
        let hit: Hit = searching ? .clearSearch : .clearFilters
        c.fillRoundedRect(b, radius: PanelTheme.radiusMd, hovered == hit ? PanelTheme.panelHover : PanelTheme.panelInput)
        PanelDraw.text(c, label, in: b, font: PanelTheme.font(11, .medium), color: PanelTheme.text1, align: .center)
        hits.add(b, hit)
    }

    // MARK: Tooltip and status line

    /// A truncated tile name or the switcher's context, in a bubble under the control.
    func drawTooltip(_ c: CanvasContext) {
        guard let (text, anchor) = tooltipTarget else { return }
        let font = PanelTheme.font(11), maxW = size.width - 2 * M.inset
        let lines = MediaTileText.lines(c, text, font: font, width: maxW - 16, maxLines: 3).lines
        let w = min(maxW, (lines.map { c.measureText($0, font: font).width }.max() ?? 0) + 16), h = Double(lines.count) * 15 + 8
        let x = max(M.inset, min(size.width - M.inset - w, anchor.midX - w / 2))
        let below = anchor.maxY + 6, y = below + h > size.height - 4 ? max(4, anchor.y - 6 - h) : below
        let bubble = CanvasRect(x: x, y: y, width: w, height: h)
        c.fillRoundedRect(bubble, radius: PanelTheme.radius, PanelTheme.neutral900)
        c.strokeRoundedRect(bubble.insetBy(0.5), radius: PanelTheme.radius, PanelTheme.neutral700, width: 1)
        for (i, line) in lines.enumerated() {
            PanelDraw.text(c, line, in: CanvasRect(x: x + 8, y: y + 4 + Double(i) * 15, width: w - 16, height: 15), font: font, color: PanelTheme.neutral200)
        }
    }

    var tooltipTarget: (String, CanvasRect)? {
        switch hovered {
        case .switcher?: return hits.rect { $0 == .switcher }.map { (switcherContext, $0) }
        case .tile(let ref)? where truncatedNames.contains(ref): return hits.rect { $0 == .tile(ref) }.map { (fullName(ref), $0) }
        default: return nil
        }
    }

    /// What the status line says for the control under the pointer.
    public var hint: String? {
        switch hovered {
        case .tile(let ref)?, .tileAction(let ref)?: return tileHint(ref)
        case .switcher?: return switcherContext
        case let h?: return Self.chromeHints[h]
        case nil: return nil
        }
    }

    static let chromeHints: [Hit: String] = [
        .importMedia: "Import media files into the project", .hideSidebar: "Hide the panel", .showSidebar: "Show the panel",
        .panelMenu: "Panel menu", .more: "Library and project actions", .filter: "Filter and sort the media", .search: "Search media by name",
    ]

    func tileHint(_ ref: MediaTileRef) -> String {
        let name = fullName(ref)
        switch ref {
        case .media(let id):
            if mediaItem(id)?.category == .fonts { return "\(name) · right-click for more" }
            return "\(name) · Enter or double-click adds it at the playhead · drag it onto the timeline · right-click for more"
        case .library(let id):
            if libraryAsset(id)?.available == false { return "\(name) · missing from the library · right-click to relink" }
            return "\(name) · in the library, not in this project · Enter adds it to the timeline"
        case .export(let id):
            return export(id)?.status == "complete" ? "\(name) · Enter saves a copy" : "\(name) · \(export(id)?.status ?? "")"
        }
    }
}
