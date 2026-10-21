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
import MpvfxTheme

/// The colour picker's rows, under the field it edits: saturation/value square, hue bar, alpha bar (Fill only),
/// hex field, recent colours, then Sample from frame and Done. Drags show the colour live in the picker and write
/// it once, on release; every other change writes at once. Every part takes Tab focus; arrows move the focused
/// square or bar, Escape closes.
extension InspectorPanel {
    static let pickerSquareHeight = 120.0, pickerBarHeight = 24.0

    func pickerRows(_ f: ColorFieldSpec) -> [InspectorRow] {
        guard var cp = colorPicker else { return [] }
        if cp.source != f.value && !cp.dragging, let c = PickerColor(hex: f.value ?? f.placeholder) {
            cp.color = c; cp.source = f.value   // the stored value changed under the picker (undo, another edit)
        }
        cp.commit = { [weak self] hex, coalesce in
            guard let self, let editor = self.editor else { return }
            if editor.withHistory(f.historyLabel, coalesceKey: coalesce, { f.apply(hex) }) { self.onEdited?() }
        }
        colorPicker = cp
        var rows = [pickerSquareRow(), pickerBarRow(id: "picker:hue", label: "Hue")]
        if cp.allowAlpha { rows.append(pickerBarRow(id: "picker:alpha", label: "Opacity")) }
        rows.append(InspectorRow(.number(pickerHexField(cp)), rail: true))
        if colorFieldError == "picker:hex" { rows.append(InspectorRow(colorHintRow("picker:hex").kind, rail: true)) }
        rows.append(pickerRecentRow())
        rows += pickerSampleRows()
        rows.append(InspectorRow(.buttons([
            InspectorRow.Button(key: "picker:sample", label: cp.framePending ? "Capturing frame" : "Sample from frame", style: .chip) { [weak self] in
                self?.colorPicker?.frame = nil; self?.colorPicker?.frameError = false; self?.capturePickerFrame()
            },
            InspectorRow.Button(key: "picker:done", label: "Done", style: .chip) { [weak self] in self?.closeColorPicker() },
        ]), rail: true))
        return rows
    }

    func pickerHexField(_ cp: ColorPickerState) -> InspectorRow.Number {
        InspectorRow.Number(key: "picker:hex", label: "Hex", text: cp.color.hex(allowAlpha: cp.allowAlpha), tier: .explicitCustom,
                            commit: { [weak self] text in
            guard let self else { return }
            guard let c = PickerColor(hex: text) else { self.colorFieldError = "picker:hex"; self.onEdited?(); return }
            self.colorFieldError = nil
            let keepAlpha = self.colorPicker?.allowAlpha == true
            self.colorPicker?.color = keepAlpha ? c : PickerColor(hue: c.hue, saturation: c.saturation, value: c.value)
            self.commitPickerColor()
        })
    }

    // MARK: Square and bars

    func pickerSquareRow() -> InspectorRow {
        InspectorRow(.custom(InspectorCustomRow(id: "picker:sv", height: Self.pickerSquareHeight, draw: { [weak self] c, r, panel in
            guard let self, let cp = self.colorPicker else { return }
            let img = self.svImage(hue: cp.color.hue)
            c.drawImage(img, in: r)
            c.strokeRect(r.insetBy(0.5), PanelTheme.panelBorderInput)
            let p = CanvasPoint(r.x + cp.color.saturation * r.width, r.y + (1 - cp.color.value) * r.height)
            Self.drawPickerMark(c, CanvasRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
            panel.addHit(r, .custom("picker:sv", 0))
        }, pointer: { [weak self] _, p, phase in self?.pickerPointer("picker:sv", p, phase) })), rail: true)
    }

    func pickerBarRow(id: String, label: String) -> InspectorRow {
        InspectorRow(.custom(InspectorCustomRow(id: id, height: Self.pickerBarHeight, draw: { [weak self] c, r, panel in
            guard let self, let cp = self.colorPicker else { return }
            let bar = CanvasRect(x: r.x, y: r.midY - 6, width: r.width, height: 12)
            if id == "picker:alpha" { Self.drawChecker(c, bar) }
            c.drawImage(id == "picker:hue" ? Self.hueStrip : Self.alphaStrip(cp.color), in: bar)
            c.strokeRect(bar.insetBy(0.5), PanelTheme.panelBorderInput)
            let t = id == "picker:hue" ? cp.color.hue / 360 : cp.color.alpha
            Self.drawPickerMark(c, CanvasRect(x: bar.x + t * bar.width - 3, y: r.y + 2, width: 6, height: r.height - 4))
            panel.addHit(r, .custom(id, 0))
        }, pointer: { [weak self] _, p, phase in self?.pickerPointer(id, p, phase) })), rail: true)
    }

    /// Down and drag move the colour in the picker only; release writes it (one undo step per drag).
    func pickerPointer(_ id: String, _ p: CanvasPoint, _ phase: Int) {
        guard colorPicker != nil, let r = hits.rect(where: { $0 == .custom(id, 0) }), r.width > 0, r.height > 0 else { return }
        let x = min(1, max(0, (p.x - r.x) / r.width)), y = min(1, max(0, (p.y - r.y) / r.height))
        switch id {
        case "picker:sv": colorPicker?.color.saturation = x; colorPicker?.color.value = 1 - y
        case "picker:hue": colorPicker?.color.hue = min(359.999, x * 360)
        default: colorPicker?.color.alpha = x
        }
        colorPicker?.dragging = phase != 2
        if phase == 2 { commitPickerColor() }
    }

    static func drawPickerMark(_ c: CanvasContext, _ r: CanvasRect) {
        let radius = min(r.width, r.height) / 2
        c.strokeRoundedRect(r.insetBy(-1), radius: radius + 1, CanvasColor(ThemeTokens.stageScrim).withAlpha(0.6), width: 1)
        c.strokeRoundedRect(r, radius: radius, CanvasColor(ThemeTokens.stageInk), width: 2)
    }

    /// A transparent colour's backdrop: 4 pt squares of the two checker tokens.
    static func drawChecker(_ c: CanvasContext, _ r: CanvasRect) {
        c.fillRect(r, PanelTheme.checkerLight)
        let cell = 4.0
        c.withState {
            c.clip(r)
            var y = r.y, row = 0
            while y < r.maxY {
                var x = r.x + (row % 2 == 0 ? 0 : cell)
                while x < r.maxX { c.fillRect(CanvasRect(x: x, y: y, width: cell, height: cell), PanelTheme.checkerDark); x += 2 * cell }
                y += cell; row += 1
            }
        }
    }

    // MARK: Picture strips (the colour space itself, not chrome: computed, never tokens)

    func svImage(hue: Double) -> CanvasImage {
        if let m = colorPicker?.svImage, m.hue == hue { return m.image }
        let w = 64, h = 48
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let (r, g, b) = PickerColor.rgb(hue: hue, saturation: Double(x) / Double(w - 1), value: 1 - Double(y) / Double(h - 1))
            let i = (y * w + x) * 4
            px[i] = UInt8(PickerColor.byte(r)); px[i + 1] = UInt8(PickerColor.byte(g)); px[i + 2] = UInt8(PickerColor.byte(b))
        } }
        let img = CanvasImage(width: w, height: h, rgba: px)
        colorPicker?.svImage = (hue, img)
        return img
    }

    static let hueStrip: CanvasImage = {
        let w = 180
        var px = [UInt8](repeating: 255, count: w * 4)
        for x in 0..<w {
            let (r, g, b) = PickerColor.rgb(hue: Double(x) * 2, saturation: 1, value: 1)
            px[x * 4] = UInt8(PickerColor.byte(r)); px[x * 4 + 1] = UInt8(PickerColor.byte(g)); px[x * 4 + 2] = UInt8(PickerColor.byte(b))
        }
        return CanvasImage(width: w, height: 1, rgba: px)
    }()

    static func alphaStrip(_ color: PickerColor) -> CanvasImage {
        let w = 64, (r, g, b) = color.rgb
        var px = [UInt8](repeating: 0, count: w * 4)
        for x in 0..<w {
            px[x * 4] = UInt8(PickerColor.byte(r)); px[x * 4 + 1] = UInt8(PickerColor.byte(g)); px[x * 4 + 2] = UInt8(PickerColor.byte(b))
            px[x * 4 + 3] = UInt8(PickerColor.byte(Double(x) / Double(w - 1)))
        }
        return CanvasImage(width: w, height: 1, rgba: px)
    }
}
