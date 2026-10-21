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

/// What the host knows about a grade's LUT file: its grid size once read, or why it could not be read.
public enum LutStatus: Equatable, Sendable {
    case loaded(size: Int)
    case failed(String)
}

/// The Grade group's Custom LUT section (issue #182): a disclosure, open by default while the clip has a LUT; a
/// "LUT" select that opens the right panel's dropdown (None, every `.cube` in the project, Import LUT…) beside a
/// Remove button; a status line with the LUT's grid size or the reason it could not be read; the strength slider.
/// Every pick is one undo step through the grade's commit. The picks are also addressable buttons
/// (`lut.pick.<value>`, `lut.remove`) for scripted drives and tests.
extension InspectorPanel {
    static let lutRowId = "lut:pick"
    static let lutNone = "lut:none", lutImport = "lut:import"

    /// Open while the user has not closed it, and by default while the clip has a LUT.
    func lutSectionOpen(_ g: ColorGrading) -> Bool { grade.lutOpen ?? (g.lut != nil) }

    /// The dropdown's options: None, every `.cube` in the project by file name, then Import LUT….
    func lutOptions() -> [PanelDropdown.Option] {
        [PanelDropdown.Option(value: Self.lutNone, label: "None")]
            + lutAssets().map { PanelDropdown.Option(value: $0, label: Self.lutName($0)) }
            + [PanelDropdown.Option(value: Self.lutImport, label: "Import LUT…")]
    }

    static func lutName(_ src: String) -> String { (src as NSString).lastPathComponent }

    /// The status line: the grid size ("33³ grid"), or the parser's reason the file could not be read.
    static func lutStatusText(_ src: String, _ status: LutStatus?) -> String? {
        switch status {
        case .loaded(let n)?: "\(n)³ grid"
        case .failed(let why)?: "LUT '\(lutName(src))' could not be read: \(why)"
        case nil: nil
        }
    }

    /// None removes the LUT, Import asks the host for files, a file sets it and keeps the strength. Picking the LUT
    /// already set is no edit.
    func pickLut(_ value: String, _ g: ColorGrading, commit: (ColorGrading) -> Void) {
        if value == Self.lutImport { onImportLut?(); return }
        let src: String? = value == Self.lutNone ? nil : value
        guard src != g.lut?.src else { return }
        var n = g
        n.lut = src.map { ColorGrading.Lut(src: $0, intensity: g.lut?.intensity ?? 1) }
        commit(n)
    }

    func lutRows(_ g: ColorGrading, commit: @escaping (ColorGrading) -> Void) -> [InspectorRow] {
        var rows: [InspectorRow] = [.init(.custom(lutToggleRow(g)))]
        guard lutSectionOpen(g) else { return rows }
        let current = g.lut?.src ?? Self.lutNone
        let picks = lutOptions().map { o in
            InspectorRow.Button(key: "lut.pick.\(o.value)", label: o.label, style: o.value == current ? .chipActive : .chip,
                                action: { [weak self] in self?.pickLut(o.value, g, commit: commit) })
        }
        let remove = InspectorRow.Button(key: "lut.remove", label: "Remove", style: .muted,
                                         action: { [weak self] in self?.pickLut(Self.lutNone, g, commit: commit) }, disabled: g.lut == nil)
        rows.append(.init(.custom(lutPickRow(g, commit: commit)), controls: [.init(.buttons(picks + [remove]))]))
        guard let lut = g.lut else {
            if lutAssets().isEmpty { rows.append(.init(.custom(lutStatusRow("Choose Import LUT… in the list to add a .cube file.", failed: false)))) }
            return rows
        }
        let status = lutStatus(lut.src)
        if let text = Self.lutStatusText(lut.src, status) {
            var failed = false
            if case .failed? = status { failed = true }
            rows.append(.init(.custom(lutStatusRow(text, failed: failed))))
        }
        rows.append(.init(.slider(.init(key: "lut:strength", label: "LUT strength", position: lut.intensity * 100, min: 0, max: 100,
                                        display: "\(Int((lut.intensity * 100).rounded()))%", format: { "\(Int($0.rounded()))%" },
                                        tier: lut.intensity == 1 ? .default : .explicitCustom,
                                        commit: { v in var n = g; n.lut?.intensity = v / 100; commit(n) },
                                        reset: { var n = g; n.lut?.intensity = 1; commit(n) }))))
        return rows
    }

    /// `border-t border-panel-hairline pt-1.5` over a `min-h-[30px]` button: 11px label, the 10px caret
    /// `M2 3l3 4 3-4z` in text-5 (turned 90° when open).
    func lutToggleRow(_ g: ColorGrading) -> InspectorCustomRow {
        let open = lutSectionOpen(g)
        return InspectorCustomRow(id: "lut:toggle", height: 37, draw: { c, r, panel in
            c.fillRect(CanvasRect(x: r.x, y: r.y, width: r.width, height: 1).snapped, PanelTheme.panelHairline)
            let row = CanvasRect(x: r.x, y: r.y + 7, width: r.width, height: 30)
            PanelDraw.text(c, "Custom LUT", in: CanvasRect(x: row.x, y: row.midY - 8.25, width: row.width - 16, height: 16.5),
                           font: PanelTheme.font(11), color: PanelTheme.text2)
            let caret = CanvasRect(x: row.maxX - 10, y: row.midY - 5, width: 10, height: 10)
            c.withState {
                if open { c.translate(caret.midX, caret.midY); c.rotate(.pi / 2); c.translate(-caret.midX, -caret.midY) }
                c.fillSVG(["M2 3l3 4 3-4z"], viewBox: 10, in: caret, PanelTheme.text5)
            }
            panel.addHit(row, .custom("lut:toggle", 0))
        }, pointer: { [weak self] _, _, phase in if phase == 0 { self?.grade.lutOpen = !open } })
    }

    /// "LUT" (86 wide), the select (PanelSelect, 28 tall: part 0) and, while a LUT is set, a "Remove" button
    /// 24 tall (part 1).
    func lutPickRow(_ g: ColorGrading, commit: @escaping (ColorGrading) -> Void) -> InspectorCustomRow {
        let name = g.lut.map { Self.lutName($0.src) } ?? "None", set = g.lut != nil
        return InspectorCustomRow(id: Self.lutRowId, height: 30, draw: { c, r, panel in
            panel.drawLutPick(c, r, name: name, removable: set)
        }, pointer: { [weak self] part, _, phase in
            guard phase == 0, let self else { return }
            if part == 1 { self.pickLut(Self.lutNone, g, commit: commit) } else { self.openLutDropdown(g, commit: commit) }
        })
    }

    func drawLutPick(_ c: CanvasContext, _ r: CanvasRect, name: String, removable: Bool) {
        PanelDraw.text(c, "LUT", in: CanvasRect(x: r.x, y: r.midY - 8.25, width: 86, height: 16.5),
                       font: PanelTheme.font(11), color: PanelTheme.rowLabel)
        var right = r.maxX
        if removable {
            let font = PanelTheme.font(11)
            let w = c.measureText("Remove", font: font).width + 16
            let button = CanvasRect(x: right - w, y: r.midY - 12, width: w, height: 24)
            let hot = hovered == .custom(Self.lutRowId, 1)
            c.fillRoundedRect(button, radius: PanelTheme.radiusMd, hot ? PanelTheme.panelHover : PanelTheme.panelSurface)
            PanelDraw.text(c, "Remove", in: button, font: font, color: PanelTheme.text1, align: .center)
            addHit(button, .custom(Self.lutRowId, 1))
            right = button.x - 6
        }
        let field = CanvasRect(x: r.x + 96, y: r.midY - 14, width: max(0, right - r.x - 96), height: 28)
        PanelSelect.draw(c, field, text: name, hovered: hovered == .custom(Self.lutRowId, 0))
        addHit(field, .custom(Self.lutRowId, 0))
    }

    /// Opens the dropdown under the select drawn last, with the current LUT (or None) marked.
    func openLutDropdown(_ g: ColorGrading, commit: @escaping (ColorGrading) -> Void) {
        guard let anchor = hits.rect(where: { $0 == .custom(Self.lutRowId, 0) }) else { return }
        onOpenDropdown?("lut", lutOptions(), g.lut?.src ?? Self.lutNone, anchor) { [weak self] v in
            self?.pickLut(v, g, commit: commit)
        }
    }

    /// The status or hint under the select, 11px, wrapped: the label grey, a load failure in the error red.
    func lutStatusRow(_ text: String, failed: Bool) -> InspectorCustomRow {
        let lines = Self.wrap(text, perLine: 40)
        return InspectorCustomRow(id: "lut:status", height: PanelGrid.lineHeight * Double(max(1, lines.count)), draw: { c, r, _ in
            for (i, line) in lines.enumerated() {
                PanelDraw.text(c, line, in: CanvasRect(x: r.x + 96, y: r.y + Double(i) * PanelGrid.lineHeight, width: r.width - 96,
                                                       height: PanelGrid.lineHeight),
                               font: PanelTheme.font(11), color: failed ? PanelTheme.red400 : PanelTheme.rowLabel)
            }
        })
    }
}
