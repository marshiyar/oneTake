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

/// The header row: the library ▸ event switcher (left, flexible), Import (the one primary button) and the "…"
/// menu; under it, only while needed, the name row of New event / New project and the library's error.
extension LeftSidebarPanel {
    typealias M = MediaPanelMetrics

    /// "Untitled" for "Untitled.mpvfxlibrary": the switcher shows the name people gave the library.
    static func displayName(_ library: String) -> String {
        library.lowercased().hasSuffix(".mpvfxlibrary") ? String(library.dropLast(".mpvfxlibrary".count)) : library
    }

    /// Laid out right to left (the "…" button, Import, then the switcher takes the rest), drawn left to right so
    /// the hit regions, and with them the Tab order, read the way the row does.
    func drawHeader(_ c: CanvasContext, top: Double) -> Double {
        let x0 = M.inset, x1 = size.width - M.inset
        let more = CanvasRect(x: x1 - M.control, y: top, width: M.control, height: M.control)
        let (imp, label) = importLayout(c, right: showsLibrary ? more.x - M.controlGap : x1, top: top)
        if showsLibrary { drawSwitcher(c, CanvasRect(x: x0, y: top, width: max(0, imp.x - M.controlGap - x0), height: M.control)) }
        drawImport(c, imp, label: label)
        if showsLibrary { drawIconButton(c, more, icon: .panelMenu, hit: .more) }
        var y = top + M.control + M.rowGap
        if let cr = creating { y = drawNameRow(c, cr, top: y) }
        if let err = library.error { y = drawError(c, err, top: y) }
        return y
    }

    /// Import's rect ending at `right`: labelled while the switcher keeps `minSwitcher`, else only its plus (no label).
    func importLayout(_ c: CanvasContext, right: Double, top: Double) -> (CanvasRect, String?) {
        let label = importing ? "Importing…" : "Import", labelled = importWidth(c, label)
        let roomy = !showsLibrary || right - labelled - M.controlGap - M.inset >= M.minSwitcher
        let w = roomy ? labelled : M.control
        return (CanvasRect(x: right - w, y: top, width: w, height: M.control), roomy ? label : nil)
    }

    static var importFont: CanvasFont { PanelTheme.font(PanelTheme.textXs, .semibold) }

    /// Plus, 6 pt, label, with 10 pt padding each side.
    func importWidth(_ c: CanvasContext, _ label: String) -> Double {
        10 + 12 + 6 + c.measureText(label, font: Self.importFont).width + 10
    }

    /// Import: the panel's one primary button (filled; white text at 4.5:1 or more in both modes).
    func drawImport(_ c: CanvasContext, _ r: CanvasRect, label: String?) {
        let hov = hovered == .importMedia && !importing
        c.fillRoundedRect(r, radius: PanelTheme.radiusMd, hov ? PanelTheme.primaryFillHover : PanelTheme.primaryFill)
        let color = importing ? PanelTheme.onAccent.withAlpha(0.7) : PanelTheme.onAccent
        let gx = label == nil ? r.midX - 6 : r.x + 10
        PanelIcon.plus.draw(c, in: CanvasRect(x: gx, y: r.midY - 6, width: 12, height: 12), color: color, lineWidth: 2.5)
        if let label {
            // One point of slack: the button is exactly as wide as the label, which rounding would end-truncate.
            PanelDraw.text(c, label, in: CanvasRect(x: gx + 18, y: r.y, width: r.maxX - 9 - gx - 18, height: r.height), font: Self.importFont, color: color)
        }
        if !importing { hits.add(r, .importMedia) }
    }

    /// A 28 pt square icon button with the input fill (the "…" menu, the filter).
    func drawIconButton(_ c: CanvasContext, _ r: CanvasRect, icon: PanelIcon, hit: Hit, active: Bool = false) {
        let open = dropdown.key == "\(hit)"
        c.fillRoundedRect(r, radius: PanelTheme.radiusMd, hovered == hit || open ? PanelTheme.panelHover : PanelTheme.panelInput)
        let color = active ? PanelTheme.accent : (hovered == hit || open ? PanelTheme.text1 : PanelTheme.text3)
        icon.draw(c, in: CanvasRect(x: r.midX - 7, y: r.midY - 7, width: 14, height: 14), color: color, lineWidth: 2)
        hits.add(r, hit)
    }

    /// The switcher reads "Library ▸ Event" and opens the menu of libraries and events; a spinner replaces its caret
    /// while a library command runs.
    func drawSwitcher(_ c: CanvasContext, _ r: CanvasRect) {
        guard r.width >= M.control else { return }
        let open = dropdown.key == "\(Hit.switcher)"
        c.fillRoundedRect(r, radius: PanelTheme.radiusMd, hovered == .switcher || open ? PanelTheme.panelHover : PanelTheme.panelInput)
        let glyph = CanvasRect(x: r.maxX - 8 - 10, y: r.midY - 5, width: 10, height: 10)
        (library.busy ? PanelIcon.spinnerArc : PanelIcon.selectCaret).draw(c, in: glyph, color: PanelTheme.text3, lineWidth: 2)
        drawSwitcherLabel(c, CanvasRect(x: r.x + 10, y: r.y, width: max(0, glyph.x - 6 - r.x - 10), height: r.height))
        hits.add(r, .switcher)
    }

    /// Library name, a small chevron, event name; when both do not fit the event keeps up to 45% and both end-truncate.
    func drawSwitcherLabel(_ c: CanvasContext, _ r: CanvasRect) {
        let font = PanelTheme.font(PanelTheme.textXs, .medium)
        guard let lib = activeLibrary else {
            PanelDraw.text(c, library.available ? "No library" : "Projects", in: r, font: font, color: PanelTheme.text2)
            return
        }
        let name = Self.displayName(lib.name), event = activeEvent?.name ?? "No events", sep = 18.0
        let nameW = c.measureText(name, font: font).width, eventW = c.measureText(event, font: font).width
        let eventRoom = min(eventW, max(r.width * 0.45, r.width - nameW - sep))
        let nameRoom = max(0, r.width - sep - eventRoom)
        let drawn = PanelDraw.text(c, name, in: CanvasRect(x: r.x, y: r.y, width: nameRoom, height: r.height), font: font, color: PanelTheme.text1)
        let cx = r.x + min(drawn.width, nameRoom) + 4
        PanelIcon.chevronRight.draw(c, in: CanvasRect(x: cx, y: r.midY - 5, width: 10, height: 10), color: PanelTheme.text3, lineWidth: 2)
        PanelDraw.text(c, event, in: CanvasRect(x: cx + 14, y: r.y, width: max(0, r.maxX - cx - 14), height: r.height), font: font, color: PanelTheme.text2)
    }

    /// What the switcher's tooltip and the status line say: where new media and projects go, and what is open.
    var switcherContext: String {
        guard let lib = activeLibrary else {
            return "No library yet. Your existing project stays available; create a library to organize projects and shared media."
        }
        var s = "Library \(Self.displayName(lib.name)) · event \(activeEvent?.name ?? "none")"
        if library.isStandalone { s += " · editing the existing standalone project" }
        else if let p = lib.projects.first(where: { $0.id == library.currentProjectId }) { s += " · project \(p.name)" }
        return s
    }

    /// New event / New project: the name field and Create / Cancel, on the header's grid.
    func drawNameRow(_ c: CanvasContext, _ cr: (kind: String, field: PanelTextField), top: Double) -> Double {
        let x0 = M.inset, x1 = size.width - M.inset, font = PanelTheme.font(PanelTheme.textXs)
        let cancelW = c.measureText("Cancel", font: font).width + 20, createW = c.measureText("Create", font: font).width + 20
        let cancel = CanvasRect(x: x1 - cancelW, y: top, width: cancelW, height: M.control)
        let create = CanvasRect(x: cancel.x - M.controlGap - createW, y: top, width: createW, height: M.control)
        let field = CanvasRect(x: x0, y: top, width: max(0, create.x - M.controlGap - x0), height: M.control)
        c.fillRoundedRect(field, radius: PanelTheme.radiusMd, PanelTheme.panelInput)
        PanelDraw.focusRing(c, field, radius: PanelTheme.radiusMd)
        let empty = cr.field.draft.isEmpty
        PanelDraw.text(c, empty ? (cr.kind == "event" ? "Event name" : "Project name") : cr.field.draft, in: field.insetBy(8), font: font,
                       color: empty ? PanelTheme.text2 : PanelTheme.text0)
        hits.add(field, .createField)
        let canCreate = !cr.field.draft.trimmingCharacters(in: .whitespaces).isEmpty
        c.fillRoundedRect(create, radius: PanelTheme.radiusMd, canCreate ? PanelTheme.panelHover : PanelTheme.panelInput)
        PanelDraw.text(c, "Create", in: create, font: font, color: canCreate ? PanelTheme.text1 : PanelTheme.text5, align: .center)
        if canCreate { hits.add(create, .createConfirm) }
        PanelDraw.text(c, "Cancel", in: cancel, font: font, color: hovered == .createCancel ? PanelTheme.text0 : PanelTheme.text2, align: .center)
        hits.add(cancel, .createCancel)
        return top + M.control + M.rowGap
    }

    /// The last library command's error, wrapped, in the danger colour.
    func drawError(_ c: CanvasContext, _ err: String, top: Double) -> Double {
        let w = size.width - 2 * M.inset
        var y = top
        for line in InspectorPanel.wrap(err, perLine: max(20, Int(w / 6.5))) {
            PanelDraw.text(c, line, in: CanvasRect(x: M.inset, y: y, width: w, height: 16), font: PanelTheme.font(11), color: PanelTheme.red400)
            y += 16
        }
        return y + M.rowGap
    }
}
