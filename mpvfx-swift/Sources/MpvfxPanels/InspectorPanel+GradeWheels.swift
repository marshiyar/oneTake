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
import MpvfxTimeline

/// One set of colour wheels in the Grade group: the Lift / Gamma / Gain / Offset balance (issue #176), or the older
/// Shadows / Midtones / Highlights tonal wheels that contract 2 grades carry.
struct GradeWheelSet {
    var id: String
    var keys: [String]
    var labels: [String]
    var read: (ColorGrading, String) -> ColorGrading.Wheel
    /// Writes one wheel (nil = back to neutral).
    var write: (inout ColorGrading, String, ColorGrading.Wheel?) -> Void

    static let balance = GradeWheelSet(id: "grade:balance", keys: GradeValues.balanceKeys, labels: ["Lift", "Gamma", "Gain", "Offset"],
                                       read: { $0.balanceWheel($1) }, write: { g, k, w in g.balance[k] = w })
    static let tonal = GradeWheelSet(id: "grade:wheels", keys: ColorGrading.wheelKeys, labels: ["Shadows", "Midtones", "Highlights"],
                                     read: { $0.wheel($1) }, write: { g, k, w in g.wheels[k] = w })

    /// The number fields under a wheel: key suffix, label, unit.
    static let fields: [(key: String, label: String)] = [("hue", "Hue"), ("amount", "Amount"), ("level", "Level")]
    func fieldKey(_ wheel: String, _ field: String) -> String { "\(id):\(wheel):\(field)" }
}

/// The wheel cell's geometry, shared by the row height, the draw and the pointer.
struct GradeWheelLayout {
    static let gap = 8.0, rowGap = 12.0, labelH = 15.0, levelH = 20.0, fieldLabelH = 14.0, fieldH = 24.0
    var columns: Int, cellW: Double, wheel: Double
    init(width: Double, count: Int) {
        columns = count >= 4 ? 2 : max(1, count)
        cellW = max(1, (width - Self.gap * Double(columns - 1)) / Double(columns))
        wheel = min(cellW, 112)
    }
    var cellH: Double { Self.labelH + 6 + wheel + 6 + Self.levelH + 4 + Self.fieldLabelH + Self.fieldH }
    func rows(_ count: Int) -> Int { (count + columns - 1) / columns }
    func height(_ count: Int) -> Double { Double(rows(count)) * cellH + Double(max(0, rows(count) - 1)) * Self.rowGap }
    func cell(_ i: Int, in r: CanvasRect) -> CanvasRect {
        CanvasRect(x: r.x + Double(i % columns) * (cellW + Self.gap), y: r.y + Double(i / columns) * (cellH + Self.rowGap), width: cellW, height: cellH)
    }
    func wheelRect(_ cell: CanvasRect) -> CanvasRect {
        CanvasRect(x: cell.x + (cell.width - wheel) / 2, y: cell.y + Self.labelH + 6, width: wheel, height: wheel)
    }
    func levelRect(_ cell: CanvasRect) -> CanvasRect {
        CanvasRect(x: cell.x, y: wheelRect(cell).maxY + 6, width: cell.width, height: Self.levelH)
    }
    func fieldRect(_ cell: CanvasRect, _ j: Int) -> CanvasRect {
        let w = (cell.width - 8) / 3
        return CanvasRect(x: cell.x + Double(j) * (w + 4), y: levelRect(cell).maxY + 4, width: w, height: Self.fieldLabelH + Self.fieldH)
    }
    /// The puck sits at 46% of the inner radius times the amount, so a pointer at that distance means amount 1.
    static func puckRadius(_ wheel: Double) -> Double { 0.46 * (wheel - 2) }
}

extension InspectorPanel {
    /// The wheels as a bespoke row: each cell holds its label and reset, the wheel (hue ring, puck at the hue and
    /// amount), a level slider and Hue / Amount / Level number fields that take typing, scrubbing and Tab.
    /// Hit parts: wheel `i`, level `10 + i`, reset `20 + i`. Keyboard: a focused wheel turns with Left/Right (1°,
    /// Shift 10°) and changes amount with Up/Down (1%, Shift 10%); a focused level moves with Left/Right; Enter and
    /// Space never change either (issue #171).
    func colorWheels(_ g: ColorGrading, _ set: GradeWheelSet, commit: @escaping (ColorGrading) -> Void) -> InspectorCustomRow {
        let layout = GradeWheelLayout(width: bodyContentWidth, count: set.keys.count)
        var row = InspectorCustomRow(id: set.id, height: layout.height(set.keys.count), draw: { [weak self] c, r, panel in
            guard let self else { return }
            let l = GradeWheelLayout(width: r.width, count: set.keys.count)
            for (i, k) in set.keys.enumerated() {
                self.drawWheelCell(c, l, l.cell(i, in: r), index: i, set: set, wheel: self.wheelValue(g, set, k), panel)
            }
        }, pointer: { [weak self] part, p, phase in
            self?.wheelPointer(g, set, part: part, p, phase, commit: commit)
        })
        row.keyPress = { [weak self] part, k in self?.wheelKey(g, set, part: part, k, commit: commit) ?? false }
        return row
    }

    /// The number rows behind the wheel fields, so typing, scrubbing and Tab reach them like any other field.
    func wheelFieldControls(_ g: ColorGrading, _ set: GradeWheelSet, commit: @escaping (ColorGrading) -> Void) -> [InspectorRow] {
        set.keys.flatMap { k in
            GradeWheelSet.fields.map { f in
                let w = set.read(g, k), v = Self.wheelFieldValue(w, f.key)
                let apply: (Double) -> Void = { x in var n = g; set.write(&n, k, Self.wheel(w, setting: f.key, to: x)); commit(n) }
                let number = InspectorRow.Number(key: set.fieldKey(k, f.key), label: f.label, text: Self.wheelFieldText(v, f.key),
                                                 tier: abs(v) > 1e-9 ? .explicitCustom : .default,
                                                 commit: { text in if let x = Self.parseWheelField(text) { apply(x) } },
                                                 reset: nil, keyframe: nil,
                                                 scrub: (value: v, step: 1, apply: apply, format: { Self.wheelFieldText($0, f.key) }))
                return InspectorRow(.number(number))
            }
        }
    }

    func wheelValue(_ g: ColorGrading, _ set: GradeWheelSet, _ k: String) -> ColorGrading.Wheel {
        if let d = grade.wheelDraft, d.key == "\(set.id):\(k)" { return d.wheel }
        return set.read(g, k)
    }

    // MARK: Field values (shown in degrees and percent)

    static func wheelFieldValue(_ w: ColorGrading.Wheel, _ field: String) -> Double {
        switch field { case "hue": w.hue; case "amount": w.amount * 100; default: w.level * 100 }
    }
    static func wheelFieldText(_ v: Double, _ field: String) -> String {
        let n = Int(v.rounded())
        switch field { case "hue": return "\(n)°"; case "amount": return "\(n)%"; default: return n > 0 ? "+\(n)" : "\(n)" }
    }
    /// A typed value: digits with an optional sign and unit ("12", "-30", "45°", "60%"); nil for anything else.
    static func parseWheelField(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "°%"))
        guard let v = Double(t.trimmingCharacters(in: .whitespaces)), v.isFinite else { return nil }
        return v
    }
    /// The wheel with one field set from its shown value: hue wraps, amount and level are clamped.
    static func wheel(_ w: ColorGrading.Wheel, setting field: String, to v: Double) -> ColorGrading.Wheel {
        var n = w
        switch field {
        case "hue": n.hue = ((v.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) * 10).rounded() / 10
        case "amount": n.amount = (min(1, max(0, v / 100)) * 1000).rounded() / 1000
        default: n.level = (min(1, max(-1, v / 100)) * 100).rounded() / 100
        }
        return n
    }

    // MARK: Pointer and keys

    func wheelPointer(_ g: ColorGrading, _ set: GradeWheelSet, part: Int, _ p: CanvasPoint, _ phase: Int, commit: (ColorGrading) -> Void) {
        let index = part % 10
        guard set.keys.indices.contains(index), let rect = hits.rect(where: { $0 == .custom(set.id, part) }) else { return }
        let k = set.keys[index], draftKey = "\(set.id):\(k)"
        if part >= 20 { if phase == 0 { var n = g; set.write(&n, k, nil); commit(n) }; return }
        if phase != 0, grade.wheelDraft?.key != draftKey { return }   // a press outside the wheel's circle drags nothing
        var w = wheelValue(g, set, k)
        if part < 10 {
            let dx = p.x - rect.midX, dy = rect.midY - p.y   // y up, hue counter-clockwise from +x
            if phase == 0 && hypot(dx, dy) > rect.width / 2 { return }
            var hue = atan2(dy, dx) * 180 / .pi; if hue < 0 { hue += 360 }; if hue >= 360 { hue -= 360 }
            w.hue = (hue * 10).rounded() / 10
            w.amount = (min(1, hypot(dx, dy) / max(1, GradeWheelLayout.puckRadius(rect.width))) * 1000).rounded() / 1000
        } else {
            w.level = ((max(0, min(1, (p.x - rect.x) / max(1, rect.width))) * 2 - 1) * 100).rounded() / 100
        }
        grade.wheelDraft = (draftKey, w)
        if phase == 2 { grade.wheelDraft = nil; var n = g; set.write(&n, k, w); commit(n) }
    }

    func wheelKey(_ g: ColorGrading, _ set: GradeWheelSet, part: Int, _ k: EditorKey, commit: (ColorGrading) -> Void) -> Bool {
        let index = part % 10
        guard part < 20, set.keys.indices.contains(index) else { return false }
        if k.code == .enter || k.code == .space { return true }   // a press never moves the puck or the level
        var w = set.read(g, set.keys[index])
        let big = k.shift
        switch (k.code, part < 10) {
        case (.left, true), (.right, true): w = Self.wheel(w, setting: "hue", to: w.hue + (k.code == .right ? 1 : -1) * (big ? 10 : 1))
        case (.up, true), (.down, true): w = Self.wheel(w, setting: "amount", to: w.amount * 100 + (k.code == .up ? 1 : -1) * (big ? 10 : 1))
        case (.left, false), (.right, false): w = Self.wheel(w, setting: "level", to: w.level * 100 + (k.code == .right ? 1 : -1) * (big ? 10 : 1))
        default: return false
        }
        var n = g; set.write(&n, set.keys[index], w); commit(n)
        return true
    }
}
