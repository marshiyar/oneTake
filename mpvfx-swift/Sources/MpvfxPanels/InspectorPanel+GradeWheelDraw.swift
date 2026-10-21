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
import MpvfxTheme
import MpvfxShared

/// Drawing of one colour-wheel cell (see `colorWheels`).
extension InspectorPanel {
    func drawWheelCell(_ c: CanvasContext, _ l: GradeWheelLayout, _ cell: CanvasRect, index i: Int, set: GradeWheelSet,
                       wheel w: ColorGrading.Wheel, _ panel: InspectorPanel) {
        let id = set.id
        PanelDraw.text(c, set.labels[i], in: CanvasRect(x: cell.x, y: cell.y, width: cell.width - 24, height: GradeWheelLayout.labelH),
                       font: PanelTheme.font(10, .medium), color: PanelTheme.text2)
        // The reset glyph (10 px) at the cell's top right, inside a 24 pt target that stays out of the wheel.
        let reset = CanvasRect(x: cell.maxX - 10, y: cell.y + 2.5, width: 10, height: 10)
        PanelIcon.reset.draw(c, in: reset, color: panel.hovered == .custom(id, 20 + i) ? PanelTheme.text1 : (w.isNeutral ? PanelTheme.text5 : PanelTheme.text4))
        panel.addHit(CanvasRect(x: cell.maxX - 24, y: cell.y - 4.5, width: 24, height: 24), .custom(id, 20 + i))
        let wr = l.wheelRect(cell)
        drawWheel(c, wr, w)
        panel.addHit(wr, .custom(id, i))
        if panel.focus.visible, panel.focus.current == .custom(id, i) { PanelDraw.focusRing(c, wr, radius: wr.width / 2) }
        let lt = l.levelRect(cell)
        Self.drawLevel(c, lt, level: w.level)
        panel.addHit(lt, .custom(id, 10 + i))
        if panel.focus.visible, panel.focus.current == .custom(id, 10 + i) { PanelDraw.focusRing(c, lt, radius: 3) }
        for (j, f) in GradeWheelSet.fields.enumerated() {
            drawWheelField(c, l.fieldRect(cell, j), key: set.fieldKey(set.keys[i], f.key), label: f.label,
                           text: Self.wheelFieldText(Self.wheelFieldValue(w, f.key), f.key), panel)
        }
    }

    /// The hue ring under a grey centre, a 1 px rim and the white-ringed puck at the hue, amount out from the centre.
    func drawWheel(_ c: CanvasContext, _ wr: CanvasRect, _ w: ColorGrading.Wheel) {
        let size = wr.width
        c.withState {
            c.clip(.roundedRect(wr, radius: size / 2))
            c.drawImage(HueWheelImage.image(), in: wr)
        }
        c.stroke(.roundedRect(wr.insetBy(0.5), radius: size / 2 - 0.5), PanelTheme.panelBorderInput, StrokeStyle(width: 1))
        let hr = w.hue * .pi / 180, d = w.amount * GradeWheelLayout.puckRadius(size)
        let px = wr.midX + cos(hr) * d, py = wr.midY - sin(hr) * d
        c.stroke(.roundedRect(CanvasRect(x: px - 4, y: py - 4, width: 8, height: 8), radius: 4), PanelTheme.white, StrokeStyle(width: 2))
    }

    /// The level as the inspector's slider (FlatSlider): a 2 px track, a centre tick, the fill from the centre and the
    /// knob (8 px white off zero, 7 px text-4 at zero).
    static func drawLevel(_ c: CanvasContext, _ r: CanvasRect, level: Double) {
        let lineY = r.midY - 1, f = (max(-1, min(1, level)) + 1) / 2
        c.fillRoundedRect(CanvasRect(x: r.x, y: lineY, width: r.width, height: 2), radius: 1, PanelTheme.panelHover)
        c.fillRect(CanvasRect(x: r.midX - 0.5, y: lineY - 1, width: 1, height: 4), PanelTheme.text5)
        let x = r.x + r.width * f, custom = abs(level) > 1e-9
        if custom { c.fillRect(CanvasRect(x: min(x, r.midX), y: lineY, width: abs(x - r.midX), height: 2), PanelTheme.text5) }
        let k = custom ? 8.0 : 7.0
        c.fill(.roundedRect(CanvasRect(x: x - k / 2, y: r.midY - k / 2, width: k, height: k), radius: k / 2), custom ? PanelTheme.white : PanelTheme.text4)
    }

    /// A number field: its 10 px label (scrubs the value when dragged) over the mono value on an underline; a click on
    /// the value types into it.
    func drawWheelField(_ c: CanvasContext, _ r: CanvasRect, key: String, label: String, text: String, _ panel: InspectorPanel) {
        let labelRect = CanvasRect(x: r.x, y: r.y, width: r.width, height: GradeWheelLayout.fieldLabelH)
        PanelDraw.text(c, label, in: labelRect, font: PanelTheme.font(10), color: PanelTheme.text5)
        panel.addHit(labelRect, .scrub(key))
        let box = CanvasRect(x: r.x, y: labelRect.maxY, width: r.width, height: GradeWheelLayout.fieldH)
        let editing = panel.field?.key == key
        var shown = editing ? (panel.field?.draft ?? text) : text
        if let s = panel.scrub, s.key == key, let fmt = panel.number(key)?.scrub?.format { shown = fmt(s.current) }
        if editing { c.fillRect(CanvasRect(x: box.x, y: box.y + 2, width: box.width, height: box.height - 4), PanelTheme.panelInput) }
        PanelDraw.text(c, shown, in: CanvasRect(x: box.x, y: box.midY - 7, width: box.width - 2, height: 14), font: PanelTheme.mono(10),
                       color: editing ? PanelTheme.text0 : PanelTheme.text2, align: .right)
        let hot = panel.hovered == .field(key)
        c.fillRect(CanvasRect(x: box.x, y: box.maxY - 3, width: box.width, height: 1).snapped,
                   editing ? PanelTheme.accent : PanelTheme.panelBorderInput.withAlpha(hot ? 1 : 0.5))
        panel.addHit(box, .field(key))
    }
}
