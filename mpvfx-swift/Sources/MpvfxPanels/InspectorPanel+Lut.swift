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

/// What the host knows about a grade's LUT file: why it could not be read, or its grid size once read.
public enum LutStatus: Equatable, Sendable {
    /// The file could not be read: the parser's reason, or that the file is missing.
    case failed(String)
    /// The file was read: its grid has `size`³ entries.
    case loaded(size: Int)
}

/// The Grade group's Custom LUT section (issue #182): a disclosure, open by default while the clip has a LUT; a
/// "LUT" select that opens the right panel's dropdown (None, every `.cube` in the project, Import LUT…) beside a
/// Remove button; a status line with the LUT's grid size or the reason it could not be read; the strength slider.
/// Every pick is one undo step through the grade's commit. The picks are also addressable buttons
/// (`lut.pick.<value>`, `lut.remove`) for scripted drives and tests.
extension InspectorPanel {
    internal static let lutRowId: String = "lut:pick"
    internal static let lutNone: String = "lut:none"
    internal static let lutImport: String = "lut:import"

    /// The file name of a LUT's `src` (after the last `/` or `\`).
    internal static func lutName(_ src: String) -> String {
        src.split { $0 == "/" || $0 == "\\" }.last.map(String.init) ?? src
    }

    /// The status line: the grid size ("33³ grid"), or the parser's reason the file could not be read.
    internal static func lutStatusText(_ src: String, _ status: LutStatus?) -> String? {
        switch status {
        case .loaded(let size):
            return "\(size)³ grid"

        case .failed(let reason):
            return "LUT '\(lutName(src))' could not be read: \(reason)"

        case nil:
            return nil
        }
    }

    /// Open while the user has not closed it, and by default while the clip has a LUT.
    internal func lutSectionOpen(_ grading: ColorGrading) -> Bool {
        grade.lutOpen ?? (grading.lut != nil)
    }

    /// The dropdown's options: None, every `.cube` in the project by file name, then Import LUT….
    internal func lutOptions() -> [PanelDropdown.Option] {
        let files: [PanelDropdown.Option] = lutAssets().map { path in
            PanelDropdown.Option(value: path, label: Self.lutName(path))
        }
        return [PanelDropdown.Option(value: Self.lutNone, label: "None")]
            + files
            + [PanelDropdown.Option(value: Self.lutImport, label: "Import LUT…")]
    }

    /// None removes the LUT, Import asks the host for files, a file sets it and keeps the strength. Picking the LUT
    /// already set is no edit.
    internal func pickLut(_ value: String, _ grading: ColorGrading, commit: (ColorGrading) -> Void) {
        if value == Self.lutImport {
            onImportLut?()
            return
        }
        let src: String? = value == Self.lutNone ? nil : value
        guard src != grading.lut?.src else {
            return
        }
        var next: ColorGrading = grading
        next.lut = src.map { ColorGrading.Lut(src: $0, intensity: grading.lut?.intensity ?? 1) }
        commit(next)
    }

    internal func lutRows(_ grading: ColorGrading, commit: @escaping (ColorGrading) -> Void) -> [InspectorRow] {
        var rows: [InspectorRow] = [InspectorRow(.custom(lutToggleRow(grading)))]
        guard lutSectionOpen(grading) else {
            return rows
        }
        let pick: InspectorCustomRow = lutPickRow(grading, commit: commit)
        rows.append(InspectorRow(.custom(pick), controls: lutPickControls(grading, commit: commit)))
        guard let lut = grading.lut else {
            if lutAssets().isEmpty {
                let hint: String = "Choose Import LUT… in the list to add a .cube file."
                rows.append(InspectorRow(.custom(lutStatusRow(hint, failed: false))))
            }
            return rows
        }
        let status: LutStatus? = lutStatus(lut.src)
        if let text = Self.lutStatusText(lut.src, status) {
            rows.append(InspectorRow(.custom(lutStatusRow(text, failed: isFailure(status)))))
        }
        rows.append(InspectorRow(.slider(lutStrengthSlider(grading, lut, commit: commit))))
        return rows
    }

    private func isFailure(_ status: LutStatus?) -> Bool {
        if case .failed = status {
            return true
        }
        return false
    }

    /// The picks and Remove as plain buttons: what keyboard drives and tests press by key.
    private func lutPickControls(_ grading: ColorGrading, commit: @escaping (ColorGrading) -> Void) -> [InspectorRow] {
        let current: String = grading.lut?.src ?? Self.lutNone
        let picks: [InspectorRow.Button] = lutOptions().map { option in
            InspectorRow.Button(
                key: "lut.pick.\(option.value)",
                label: option.label,
                style: option.value == current ? .chipActive : .chip
            ) { [weak self] in
                self?.pickLut(option.value, grading, commit: commit)
            }
        }
        let remove = InspectorRow.Button(
            key: "lut.remove",
            label: "Remove",
            style: .muted,
            action: { [weak self] in self?.pickLut(Self.lutNone, grading, commit: commit) },
            disabled: grading.lut == nil
        )
        return [InspectorRow(.buttons(picks + [remove]))]
    }

    private func lutStrengthSlider(
        _ grading: ColorGrading,
        _ lut: ColorGrading.Lut,
        commit: @escaping (ColorGrading) -> Void
    ) -> InspectorRow.Slider {
        InspectorRow.Slider(
            key: "lut:strength",
            label: "LUT strength",
            position: lut.intensity * LutLayout.percent,
            min: 0,
            max: LutLayout.percent,
            display: "\(Int((lut.intensity * LutLayout.percent).rounded()))%",
            format: { "\(Int($0.rounded()))%" },
            tier: lut.intensity == 1 ? .default : .explicitCustom,
            commit: { value in
                var next: ColorGrading = grading
                next.lut?.intensity = value / LutLayout.percent
                commit(next)
            },
            reset: {
                var next: ColorGrading = grading
                next.lut?.intensity = 1
                commit(next)
            }
        )
    }

    /// `border-t border-panel-hairline pt-1.5` over a `min-h-[30px]` button: 11px label, the 10px caret
    /// `M2 3l3 4 3-4z` in text-5 (turned 90° when open).
    internal func lutToggleRow(_ grading: ColorGrading) -> InspectorCustomRow {
        let open: Bool = lutSectionOpen(grading)
        return InspectorCustomRow(
            id: "lut:toggle",
            height: LutLayout.toggleHeight,
            draw: { canvas, rect, panel in panel.drawLutToggle(canvas, rect, open: open) },
            pointer: { [weak self] _, _, phase in
                if phase == 0 {
                    self?.grade.lutOpen = !open
                }
            }
        )
    }

    internal func drawLutToggle(_ canvas: CanvasContext, _ rect: CanvasRect, open: Bool) {
        let rule = CanvasRect(x: rect.x, y: rect.y, width: rect.width, height: 1)
        canvas.fillRect(rule.snapped, PanelTheme.panelHairline)
        let row = CanvasRect(
            x: rect.x,
            y: rect.y + LutLayout.ruleGap,
            width: rect.width,
            height: LutLayout.rowHeight
        )
        let label = CanvasRect(
            x: row.x,
            y: row.midY - LutLayout.textHalf,
            width: row.width - LutLayout.padding,
            height: LutLayout.textHeight
        )
        let font: CanvasFont = PanelTheme.font(LutLayout.fontSize)
        PanelDraw.text(canvas, "Custom LUT", in: label, font: font, color: PanelTheme.text2)
        let caret = CanvasRect(
            x: row.maxX - LutLayout.caretSize,
            y: row.midY - LutLayout.caretHalf,
            width: LutLayout.caretSize,
            height: LutLayout.caretSize
        )
        canvas.withState {
            if open {
                canvas.translate(caret.midX, caret.midY)
                canvas.rotate(LutLayout.quarterTurn)
                canvas.translate(-caret.midX, -caret.midY)
            }
            canvas.fillSVG(["M2 3l3 4 3-4z"], viewBox: LutLayout.caretSize, in: caret, PanelTheme.text5)
        }
        addHit(row, .custom("lut:toggle", 0))
    }

    /// "LUT" (86 wide), the select (PanelSelect, 28 tall: part 0) and, while a LUT is set, a "Remove" button
    /// 24 tall (part 1).
    internal func lutPickRow(_ grading: ColorGrading, commit: @escaping (ColorGrading) -> Void) -> InspectorCustomRow {
        let name: String = grading.lut.map { Self.lutName($0.src) } ?? "None"
        let removable: Bool = grading.lut != nil
        return InspectorCustomRow(
            id: Self.lutRowId,
            height: LutLayout.rowHeight,
            draw: { canvas, rect, panel in panel.drawLutPick(canvas, rect, name: name, removable: removable) },
            pointer: { [weak self] part, _, phase in
                guard phase == 0, let self else {
                    return
                }
                if part == 1 {
                    pickLut(Self.lutNone, grading, commit: commit)
                } else {
                    openLutDropdown(grading, commit: commit)
                }
            }
        )
    }

    internal func drawLutPick(_ canvas: CanvasContext, _ rect: CanvasRect, name: String, removable: Bool) {
        let label = CanvasRect(
            x: rect.x,
            y: rect.midY - LutLayout.textHalf,
            width: LutLayout.labelWidth,
            height: LutLayout.textHeight
        )
        PanelDraw.text(canvas, "LUT", in: label, font: PanelTheme.font(LutLayout.fontSize), color: PanelTheme.rowLabel)
        var right: Double = rect.maxX
        if removable {
            let font: CanvasFont = PanelTheme.font(LutLayout.fontSize)
            let width: Double = canvas.measureText("Remove", font: font).width + LutLayout.padding
            let button = CanvasRect(
                x: right - width,
                y: rect.midY - LutLayout.buttonHalf,
                width: width,
                height: LutLayout.buttonHeight
            )
            let hot: Bool = hovered == .custom(Self.lutRowId, 1)
            let fill: CanvasColor = hot ? PanelTheme.panelHover : PanelTheme.panelSurface
            canvas.fillRoundedRect(button, radius: PanelTheme.radiusMd, fill)
            PanelDraw.text(canvas, "Remove", in: button, font: font, color: PanelTheme.text1, align: .center)
            addHit(button, .custom(Self.lutRowId, 1))
            right = button.x - LutLayout.gap
        }
        let field = CanvasRect(
            x: rect.x + LutLayout.fieldInset,
            y: rect.midY - LutLayout.fieldHalf,
            width: max(0, right - rect.x - LutLayout.fieldInset),
            height: LutLayout.fieldHeight
        )
        PanelSelect.draw(canvas, field, text: name, hovered: hovered == .custom(Self.lutRowId, 0))
        addHit(field, .custom(Self.lutRowId, 0))
    }

    /// Opens the dropdown under the select drawn last, with the current LUT (or None) marked.
    internal func openLutDropdown(_ grading: ColorGrading, commit: @escaping (ColorGrading) -> Void) {
        guard let anchor = hits.rect(where: { $0 == .custom(Self.lutRowId, 0) }) else {
            return
        }
        onOpenDropdown?("lut", lutOptions(), grading.lut?.src ?? Self.lutNone, anchor) { [weak self] value in
            self?.pickLut(value, grading, commit: commit)
        }
    }

    /// The status or hint under the select, 11px, wrapped: in the label grey, a load failure in the error red.
    internal func lutStatusRow(_ text: String, failed: Bool) -> InspectorCustomRow {
        let lines: [String] = Self.wrap(text, perLine: LutLayout.statusLineCharacters)
        let height: Double = PanelGrid.lineHeight * Double(max(1, lines.count))
        return InspectorCustomRow(id: "lut:status", height: height) { canvas, rect, _ in
            let color: CanvasColor = failed ? PanelTheme.red400 : PanelTheme.rowLabel
            for (index, line) in lines.enumerated() {
                let top: Double = rect.y + Double(index) * PanelGrid.lineHeight
                let box = CanvasRect(
                    x: rect.x + LutLayout.fieldInset,
                    y: top,
                    width: rect.width - LutLayout.fieldInset,
                    height: PanelGrid.lineHeight
                )
                PanelDraw.text(canvas, line, in: box, font: PanelTheme.font(LutLayout.fontSize), color: color)
            }
        }
    }
}

/// The Custom LUT section's geometry in points: 30 pt rows, an 86 pt label column, fields 96 pt in, 11 px text.
private enum LutLayout {
    /// The 1 pt rule, 6 pt of space, then the 30 pt disclosure row.
    static let toggleHeight: Double = 37
    static let ruleGap: Double = 7
    static let rowHeight: Double = 30
    static let labelWidth: Double = 86
    static let fieldInset: Double = 96
    static let fieldHeight: Double = 28
    static let fieldHalf: Double = 14
    static let buttonHeight: Double = 24
    static let buttonHalf: Double = 12
    static let textHeight: Double = 16.5
    static let textHalf: Double = 8.25
    static let caretSize: Double = 10
    static let caretHalf: Double = 5
    static let quarterTurn: Double = .pi / 2
    static let padding: Double = 16
    static let gap: Double = 6
    static let fontSize: Double = 11
    static let statusLineCharacters: Int = 40
    /// The strength slider runs 0…100 % for an intensity of 0…1.
    static let percent: Double = 100
}
