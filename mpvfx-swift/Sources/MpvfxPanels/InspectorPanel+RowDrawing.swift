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

/// The inspector's row kinds drawn on the `PanelGrid` columns: every label in the label column, every field, track
/// and segmented control from the control column's left edge to one shared value edge, then the reset cell and the
/// keyframe gutter, reserved on every property row whether or not it has them, so values end on one x (issue #187).
/// A row whose controls do not fit beside its label at this width is stacked: the label line on top (with the row's
/// reset and keyframe controls at its right end), the control across the full width below.
extension InspectorPanel {
    /// Space between two segmented options, and each option's padding around its label.
    static let segmentGap = 2.0, segmentPad = 12.0
    /// One keyframe control cell (stopwatch, ‹, ◆, ›): four of them make the gutter.
    static let keyframeCell = 24.0
    static var keyframeGutter: Double { keyframeCell * 4 }
    /// The narrowest a slider's track, its value text, a number field and a pair's field may get before the row stacks.
    static let minTrack = 64.0, sliderValueWidth = 48.0, minField = 56.0, minPairField = 72.0
    /// What every property row reserves at its right end: the reset cell and the keyframe gutter, with their gaps.
    static var accessoryReserve: Double { PanelGrid.minTarget + PanelGrid.itemGap + keyframeGutter + PanelGrid.itemGap }
    static var rowFont: CanvasFont { PanelTheme.font(11) }
    /// A compact field's padding inside its pill (`px-1.5`).
    static let compactPad = 6.0

    /// A property row's trailing controls, right to left: the keyframe gutter, then the reset cell. Both are always
    /// reserved (`accessoryReserve`); these say what is drawn in them.
    struct Accessories {
        var key: String
        var keyframe: InspectorRow.Keyframe?
        /// Whether the reset glyph is drawn, and whether its cell takes presses.
        var resetGlyph: Bool, resetHit: Bool
    }

    // MARK: Layout decisions

    /// The open group laid out for a panel `width` wide, as `draw` lays it out (the layout audit reads its slots).
    func layoutForAudit(width: Double) -> InspectorGroup? {
        guard let editor else { return nil }
        let g = showsComposition ? compositionGroup(editor) : buildGroups().first { $0.id == openGroupId }
        return g.map { laidOut($0, PanelMeasureCanvas(), width: width) }
    }

    /// Whether `kind` must stack in `row` (a row rect of the group's content width): its control does not fit between
    /// the control column and the value edge.
    static func needsStacking(_ c: CanvasContext, _ kind: InspectorRow.Kind, row: CanvasRect) -> Bool {
        let room = PanelGrid.columns(row).control.width - accessoryReserve
        switch kind {
        case .segmented(let s): return segmentsWidth(c, s) > room
        case .slider: return minTrack + 8 + sliderValueWidth > room
        case .number: return minField > room
        case .pair: return (row.width - accessoryReserve - PanelGrid.columnGap) / 2 < minPairField
        default: return false
        }
    }

    /// The value edge of a property row `r`: where fields, slider values and segmented controls end.
    static func valueEdge(_ r: CanvasRect) -> Double { r.maxX - accessoryReserve }

    static func sliderAccessories(_ s: InspectorRow.Slider) -> Accessories {
        let custom = s.tier == .explicitCustom && s.reset != nil
        return Accessories(key: s.key, keyframe: s.keyframe, resetGlyph: custom, resetHit: custom)
    }

    static func numberAccessories(_ n: InspectorRow.Number, hovering: Bool) -> Accessories {
        let slot = n.tier == .explicitCustom && n.reset != nil
        return Accessories(key: n.key, keyframe: n.keyframe, resetGlyph: slot && hovering, resetHit: slot)
    }

    /// The label line and the control line of a stacked row.
    static func stackedLines(_ r: CanvasRect) -> (top: CanvasRect, bottom: CanvasRect) {
        let top = CanvasRect(x: r.x, y: r.y, width: r.width, height: PanelGrid.compactRowHeight)
        return (top, CanvasRect(x: r.x, y: top.maxY, width: r.width, height: max(0, r.height - top.height)))
    }

    // MARK: Rows

    func drawRow(_ c: CanvasContext, _ r: CanvasRect, _ row: InspectorRow) {
        switch row.kind {
        case .number(let n): drawNumber(c, r, n, compact: false, stacked: row.stacked)
        case .pair(let label, let a, let b): drawPair(c, r, label: label, a, b, stacked: row.stacked)
        case .quad(let ns): drawQuad(c, r, ns)
        case .slider(let s): drawSlider(c, r, s, stacked: row.stacked)
        case .toggle(let t): drawToggle(c, r, t)
        case .segmented(let s): drawSegmented(c, r, s, stacked: row.stacked)
        case .fxNode(let n): drawFxNode(c, r, n)
        case .custom(let cr): cr.draw(c, r, self)
        default: drawTextRow(c, r, row.kind)
        }
    }

    /// Headings, section titles, sub-headers, notes and button rows.
    func drawTextRow(_ c: CanvasContext, _ r: CanvasRect, _ kind: InspectorRow.Kind) {
        switch kind {
        case .section(let t):
            c.fillRect(CanvasRect(x: r.x, y: r.y, width: r.width, height: 1).snapped, PanelTheme.panelHairline)
            PanelDraw.tracked(c, t.uppercased(), in: CanvasRect(x: r.x, y: r.y + 1, width: r.width, height: r.height - 1),
                              font: PanelTheme.font(PanelTheme.inspectorSectionSize, .semibold), tracking: 1.08, color: PanelTheme.inspectorText)
        case .heading(let t, let trailing):
            PanelDraw.text(c, t.uppercased(), in: r, font: PanelTheme.font(11, .medium), color: PanelTheme.text2)
            if let trailing { PanelDraw.text(c, trailing, in: r, font: PanelTheme.font(11), color: PanelTheme.inspectorText, align: .right) }
        case .subheader(let t, let buttons): drawSubheader(c, r, t, buttons)
        case .note(let s):
            for (i, line) in Self.wrap(s, perLine: 48).enumerated() {
                let lr = CanvasRect(x: r.x, y: r.y + Double(i) * PanelGrid.lineHeight, width: r.width, height: PanelGrid.lineHeight)
                PanelDraw.text(c, line, in: lr, font: PanelTheme.font(11), color: PanelTheme.inspectorText)
            }
        case .buttons(let bs):
            let gap = 6.0, w = (r.width - gap * Double(bs.count - 1)) / Double(max(1, bs.count))
            for (i, b) in bs.enumerated() { drawButton(c, CanvasRect(x: r.x + Double(i) * (w + gap), y: r.y + 2, width: w, height: r.height - 4), b, plain: false) }
        default: break
        }
    }

    /// `text-[11px] font-semibold` sub-header with its plain buttons at the right end, each at least a target wide.
    func drawSubheader(_ c: CanvasContext, _ r: CanvasRect, _ t: String, _ buttons: [InspectorRow.Button]) {
        var x = r.maxX
        for b in buttons.reversed() {
            let w = max(PanelGrid.minTarget, b.icon == nil ? c.measureText(b.label, font: PanelTheme.font(11, .medium)).width + 8 : PanelGrid.minTarget)
            let br = CanvasRect(x: x - w, y: r.y, width: w, height: r.height)
            drawButton(c, br, b, plain: true)
            x = br.x - PanelGrid.itemGap
        }
        PanelDraw.text(c, t, in: CanvasRect(x: r.x, y: r.y, width: max(0, x - r.x - 8), height: r.height),
                       font: PanelTheme.font(11, .semibold), color: PanelTheme.text1)
    }

    /// LayoutGeometryRows, grouped: the heading line (11px rowLabel), then two compact fields side by side ending at
    /// the value edge, with the group's keyframe navigation in the gutter of their line. Stacked (too narrow for two
    /// fields): one field per line.
    func drawPair(_ c: CanvasContext, _ r: CanvasRect, label: String, _ a: InspectorRow.Number, _ b: InspectorRow.Number, stacked: Bool = false) {
        let head = CanvasRect(x: r.x, y: r.y, width: r.width, height: PanelGrid.compactRowHeight)
        PanelDraw.text(c, label, in: CanvasRect(x: head.x, y: head.midY - 8.25, width: head.width, height: 16.5), font: Self.rowFont, color: PanelTheme.rowLabel)
        let line = CanvasRect(x: r.x, y: head.maxY, width: r.width, height: PanelGrid.rowHeight)
        _ = drawAccessories(c, line: line, Accessories(key: a.key, keyframe: a.keyframe, resetGlyph: false, resetHit: false))
        let edge = Self.valueEdge(line), fh = PanelGrid.rowHeight - 4
        if stacked {
            drawNumber(c, CanvasRect(x: r.x, y: line.y + 2, width: edge - r.x, height: fh), a, compact: true)
            drawNumber(c, CanvasRect(x: r.x, y: line.maxY + 2, width: edge - r.x, height: fh), b, compact: true)
            return
        }
        let colW = (edge - r.x - PanelGrid.columnGap) / 2
        drawNumber(c, CanvasRect(x: r.x, y: line.y + 2, width: colW, height: fh), a, compact: true)
        drawNumber(c, CanvasRect(x: r.x + colW + PanelGrid.columnGap, y: line.y + 2, width: colW, height: fh), b, compact: true)
    }

    func drawQuad(_ c: CanvasContext, _ r: CanvasRect, _ ns: [InspectorRow.Number]) {
        let gap = PanelGrid.columnGap, colW = (r.width - gap * Double(ns.count - 1)) / Double(max(1, ns.count))
        for (i, n) in ns.enumerated() {
            drawNumber(c, CanvasRect(x: r.x + Double(i) * (colW + gap), y: r.y + 2, width: colW, height: r.height - 4), n, compact: true)
        }
    }

    static func wrap(_ s: String, perLine: Int) -> [String] {
        var lines: [String] = [], cur = ""
        for word in s.split(separator: " ") {
            if cur.count + word.count + 1 > perLine, !cur.isEmpty { lines.append(cur); cur = "" }
            cur += (cur.isEmpty ? "" : " ") + word
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines
    }

    // MARK: Number

    /// Whether the pointer is over any part of property `key`'s row (its label, field, reset or keyframe controls).
    func isHovering(_ key: String) -> Bool {
        switch hovered {
        case .field(let k)?, .scrub(let k)?, .reset(let k)?, .keyframe(let k)?: return k == key
        case .kfPrev(let k)?, .kfNext(let k)?, .stopwatch(let k)?: return k == key
        default: return false
        }
    }

    /// FlatRow: the 11px grey label (rowLabel) in the label column, a scrub zone over it; the value field (`border-b
    /// font-mono`, its value right-aligned in the tier colour) from the control column to the accessories. Compact
    /// (`rounded bg-panel-bg px-1.5 gap-1`, the pair and quad fields): the label, then the field filling the rest.
    func drawNumber(_ c: CanvasContext, _ r: CanvasRect, _ n: InspectorRow.Number, compact: Bool, stacked: Bool = false) {
        if compact { drawCompactNumber(c, r, n); return }
        let lines = stacked ? Self.stackedLines(r) : (r, r)
        let acc = Self.numberAccessories(n, hovering: isHovering(n.key))
        let accLeft = drawAccessories(c, line: lines.0, acc)
        let cols = PanelGrid.columns(lines.0)
        let labelW = stacked ? max(0, accLeft - lines.0.x - PanelGrid.columnGap) : cols.label.width
        drawNumberLabel(c, n, line: lines.0, width: labelW)
        let fieldX = stacked ? lines.1.x : cols.control.x
        let fieldRight = stacked ? lines.1.maxX : accLeft
        drawNumberField(c, CanvasRect(x: fieldX, y: lines.1.y, width: max(0, fieldRight - fieldX), height: lines.1.height), n)
    }

    func drawCompactNumber(_ c: CanvasContext, _ r: CanvasRect, _ n: InspectorRow.Number) {
        c.fillRoundedRect(r.snapped, radius: PanelTheme.radius, PanelTheme.panelBg)
        let pad = Self.compactPad
        var right = r.maxX - pad
        if n.tier == .explicitCustom, n.reset != nil {
            let cell = CanvasRect(x: right - 11, y: r.y, width: 11, height: r.height)
            drawResetGlyph(c, cell, key: n.key, visible: isHovering(n.key))
            addHit(Self.target(cell), .reset(n.key))
            right = cell.x - PanelGrid.itemGap
        }
        // The one-letter label's cell is a whole target wide (it is the scrub handle); the field starts after it.
        let cell = max(PanelGrid.minTarget - pad, c.measureText(n.label, font: Self.rowFont).width + PanelGrid.itemGap)
        drawNumberLabel(c, n, line: CanvasRect(x: r.x, y: r.y, width: cell + pad, height: r.height), width: cell + pad, inset: pad)
        let fx = r.x + pad + cell
        drawNumberField(c, CanvasRect(x: fx, y: r.y, width: max(0, right - fx), height: r.height), n)
    }

    /// The label (from `inset`, truncated to the cell) and, when the value scrubs, its scrub zone: the whole label
    /// cell, `width` wide and the line tall.
    func drawNumberLabel(_ c: CanvasContext, _ n: InspectorRow.Number, line: CanvasRect, width: Double, inset: Double = 0) {
        let lr = CanvasRect(x: line.x + inset, y: line.midY - 8.25, width: max(0, width - inset), height: 16.5)
        PanelDraw.text(c, n.label, in: lr, font: Self.rowFont, color: n.tier.labelColor)
        if n.scrub != nil && !n.disabled { addHit(CanvasRect(x: line.x, y: line.y, width: width, height: line.height), .scrub(n.key)) }
    }

    /// A focused field's backdrop, then its caret after the draft; a read-only value shows its text selected instead.
    func drawFieldEditing(_ c: CanvasContext, _ tr: CanvasRect, text: String, font: CanvasFont, readOnly: Bool) {
        c.fillRect(CanvasRect(x: tr.x - 3, y: tr.y, width: tr.width + 6, height: tr.height), PanelTheme.panelInput)
        guard readOnly else {
            c.fillRect(CanvasRect(x: tr.maxX + 1, y: tr.midY - 6, width: 1, height: 12), PanelTheme.accent)
            return
        }
        let w = min(tr.width, c.measureText(text, font: font).width)
        c.fillRect(CanvasRect(x: tr.maxX - w - 1, y: tr.y + 1, width: w + 2, height: tr.height - 2), PanelTheme.accent.withAlpha(0.3))
    }

    /// The value field in `slot` (its line centred): the value, the draft and caret while typed, the underline, the hit.
    func drawNumberField(_ c: CanvasContext, _ slot: CanvasRect, _ n: InspectorRow.Number) {
        let field = CanvasRect(x: slot.x, y: slot.midY - 9.25, width: slot.width, height: 18.5)
        let textX = n.swatch.map { drawSwatchSlot($0, field: field, midY: slot.midY, c) } ?? field.x
        let editing = self.field?.key == n.key
        var text = n.text
        if let s = scrub, s.key == n.key, let fmt = n.scrub?.format { text = fmt(s.current) }
        if editing, let f = self.field { text = f.draft }
        let tr = CanvasRect(x: textX, y: field.y, width: max(0, field.maxX - textX), height: 16.5)
        if editing { drawFieldEditing(c, tr, text: text, font: PanelTheme.mono(11), readOnly: n.readOnly) }
        PanelDraw.text(c, text, in: tr, font: PanelTheme.mono(11),
                       color: n.tier.valueInk(disabled: n.disabled, typing: editing, adjusting: scrub?.key == n.key), align: .right)
        let underline: CanvasColor = n.tier == .explicitCustom
            ? PanelTheme.accent
            : PanelTheme.inspectorControl
        c.fillRect(CanvasRect(x: field.x, y: field.maxY - 1, width: field.width, height: 1).snapped, editing ? PanelTheme.accent : underline)
        if !n.disabled {
            // The swatch's target sits on the field's left edge: start the field hit after it so the two targets
            // partition the row instead of overlapping (the audit forbids overlapping targets).
            var fx = field.x
            if n.swatch != nil { fx = Self.swatchTarget(field: field, midY: slot.midY).maxX }
            addHit(CanvasRect(x: fx, y: slot.y, width: field.maxX - fx, height: slot.height), .field(n.key))
        }
        if let sw = n.swatch { addHit(Self.swatchTarget(field: field, midY: slot.midY), .button(sw.key)) }
    }

    // MARK: Accessories (reset, keyframes)

    /// Draws `a` in the reserved cells at the right end of `line` and returns the value edge.
    func drawAccessories(_ c: CanvasContext, line: CanvasRect, _ a: Accessories) -> Double {
        if let kf = a.keyframe { drawKeyframeNav(c, right: line.maxX, midY: line.midY, key: a.key, kf) }
        let cell = CanvasRect(x: line.maxX - Self.keyframeGutter - PanelGrid.itemGap - PanelGrid.minTarget, y: line.midY - PanelGrid.minTarget / 2,
                              width: PanelGrid.minTarget, height: PanelGrid.minTarget)
        drawResetGlyph(c, cell, key: a.key, visible: a.resetGlyph)
        if a.resetHit { addHit(cell, .reset(a.key)) }
        return Self.valueEdge(line)
    }

    /// The 11px reset ↺ centred in `cell`, full ink while hovered.
    func drawResetGlyph(_ c: CanvasContext, _ cell: CanvasRect, key: String, visible: Bool) {
        guard visible else { return }
        let g = CanvasRect(x: cell.midX - 5.5, y: cell.midY - 5.5, width: 11, height: 11)
        PanelIcon.reset.draw(c, in: g, color: hovered == .reset(key) ? PanelTheme.text1 : PanelTheme.inspectorText)
    }

    /// Keyframe controls on the property's row (docs/DESIGN.md Rollout 5), four 24 pt cells right to left: next ›,
    /// the 9px KeyframeDiamond (ghost .25 / inactive .6 outline, filled accent on a key; hover full opacity), prev ‹
    /// (the 6×10 arrow at .25 when there is nowhere to go), and the 12px stopwatch (the accent while the property is
    /// animated). Returns the gutter's left edge.
    @discardableResult
    func drawKeyframeNav(_ c: CanvasContext, right: Double, midY: Double, key: String, _ kf: InspectorRow.Keyframe) -> Double {
        let s = Self.keyframeCell
        func cell(_ i: Int) -> CanvasRect { CanvasRect(x: right - s * Double(i + 1), y: midY - s / 2, width: s, height: s) }
        let bg = PanelTheme.panelBgInset, arrow = PanelTheme.neutral400
        let next = cell(0), dia = cell(1), prev = cell(2), watch = cell(3)
        let watchColor = kf.state == .none ? arrow.over(bg, opacity: hovered == .stopwatch(key) ? 1 : 0.6)
            : (hovered == .stopwatch(key) ? PanelTheme.text0 : PanelTheme.accent)
        PanelIcon.phosphor(.timer).draw(c, in: CanvasRect(x: watch.midX - 6, y: midY - 6, width: 12, height: 12), color: watchColor)
        addHit(watch, .stopwatch(key))
        drawStepper(c, prev, path: "M5 1L1 5L5 9", live: kf.prev != nil, hit: .kfPrev(key))
        drawDiamond(c, dia, key: key, kf)
        drawStepper(c, next, path: "M1 1L5 5L1 9", live: kf.next != nil, hit: .kfNext(key))
        return watch.x
    }

    /// A ‹ or › stepper glyph centred in `cell`; it takes presses only when there is a key to go to.
    func drawStepper(_ c: CanvasContext, _ cell: CanvasRect, path: String, live: Bool, hit: Hit) {
        let arrow = PanelTheme.neutral400
        c.strokeSVG([path], viewBox: 10, in: CanvasRect(x: cell.midX - 3, y: cell.midY - 5, width: 10, height: 10),
                    arrow.over(PanelTheme.panelBgInset, opacity: live ? 1 : 0.25), width: 1.4)
        if live { addHit(cell, hit) }
    }

    /// The ◆ of a property row, as the timeline draws the property's keys (TimelineKeyframeGlyph): on a key the kind's
    /// mark filled in the kind's colour (with the key's interpolation variant); animated, its outline in the kind's
    /// colour at .75; not animated, a ghost outline at .3. Hover brings the outline to full opacity.
    func drawDiamond(_ c: CanvasContext, _ cell: CanvasRect, key: String, _ kf: InspectorRow.Keyframe) {
        let at = CanvasPoint(cell.midX, cell.midY), shape = kf.kind.shape
        let hov = hovered == .keyframe(key)
        switch kf.state {
        case .onKey:
            // On a key the diamond is the property kind's mark (#201), like the timeline's; the ease variant stays visible.
            TimelineKeyframeGlyph.draw(c, .init(kf.kind, ease: kf.ease), at: at, r: 5)
        case .animated:
            TimelineKeyframeGlyph.drawOutline(c, .init(shape: shape, color: kf.kind.color.withAlpha(hov ? 1 : 0.75)), at: at, r: 5)
        case .none:
            let ghost = PanelTheme.neutral400.over(PanelTheme.panelBgInset, opacity: hov ? 1 : 0.3)
            TimelineKeyframeGlyph.drawOutline(c, .init(shape: shape, color: ghost), at: at, r: 5)
        }
        addHit(cell, .keyframe(key))
    }

    /// KeyframeDiamond's `<rect x=5 y=0.7 width=6 height=6 rx=1 transform="rotate(45 5 0.7)">` in a 10-unit
    /// view box, mapped into the 9px box.
    static func keyframeDiamond(_ box: CanvasRect) -> CanvasPath {
        let s = box.width / 10, k = 0.5522847498
        let ca = cos(Double.pi / 4), sa = sin(Double.pi / 4)
        func map(_ x: Double, _ y: Double) -> CanvasPoint {   // rect space (0…6) → rotated about (5, 0.7)
            CanvasPoint(box.x + (5 + x * ca - y * sa) * s, box.y + (0.7 + x * sa + y * ca) * s)
        }
        var p = CanvasPath()
        p.move(to: map(1, 0)); p.line(to: map(5, 0))
        p.curve(to: map(6, 1), c1: map(5 + k, 0), c2: map(6, 1 - k)); p.line(to: map(6, 5))
        p.curve(to: map(5, 6), c1: map(6, 5 + k), c2: map(5 + k, 6)); p.line(to: map(1, 6))
        p.curve(to: map(0, 5), c1: map(1 - k, 6), c2: map(0, 5 + k)); p.line(to: map(0, 1))
        p.curve(to: map(1, 0), c1: map(0, 1 - k), c2: map(1 - k, 0))
        p.close()
        return p
    }

    // MARK: Slider, toggle, segmented

    /// FlatSlider: the grey label (rowLabel) in the label column; the track (2px bg-panel-hover line, a 1×4 text-5
    /// centre tick, a text-5 fill from the left only for a custom value; knob 7px text-4, 8px white when custom) from
    /// the control column to the mono value ending at the value edge, in the tier colour; then the reset cell and the
    /// keyframe gutter, with a separate settings gear on the Finish rows. Stacked: the label line on top with the
    /// accessories, the track and value below.
    func drawSlider(_ c: CanvasContext, _ r: CanvasRect, _ s: InspectorRow.Slider, stacked: Bool = false) {
        let lines = stacked ? Self.stackedLines(r) : (r, r)
        if let st = s.settings {
            let gearLine = CanvasRect(x: lines.0.x, y: lines.0.y, width: lines.0.width - Self.keyframeGutter - PanelGrid.itemGap - PanelGrid.minTarget - PanelGrid.itemGap, height: lines.0.height)
            drawGear(c, line: gearLine, key: s.key + Self.gearSuffix, active: st.active)
        }
        let gearSpace = s.settings == nil ? 0.0 : PanelGrid.minTarget + PanelGrid.itemGap
        let edge = drawAccessories(c, line: lines.0, Self.sliderAccessories(s)) - gearSpace
        let cols = PanelGrid.columns(lines.0)
        let labelW = stacked ? max(0, edge - lines.0.x - PanelGrid.columnGap) : cols.label.width
        let label = sliderInputError == s.key ? "Enter \(s.format(s.min))…\(s.format(s.max))" : s.label
        PanelDraw.text(c, label, in: CanvasRect(x: lines.0.x, y: lines.0.midY - 8.25, width: labelW, height: 16.5), font: Self.rowFont, color: s.tier.labelColor)
        drawSliderControl(c, line: lines.1, s, trackX: stacked ? lines.1.x : cols.control.x, valueRight: stacked ? lines.1.maxX : edge)
    }

    /// The settings gear in the gutter's last cell.
    func drawGear(_ c: CanvasContext, line: CanvasRect, key: String, active: Bool) {
        let cell = CanvasRect(x: line.maxX - PanelGrid.minTarget, y: line.midY - PanelGrid.minTarget / 2, width: PanelGrid.minTarget, height: PanelGrid.minTarget)
        let hov = hovered == .keyframe(key)
        PanelIcon.phosphor(.gear).draw(c, in: CanvasRect(x: cell.midX - 6, y: cell.midY - 6, width: 12, height: 12),
                                       color: hov || active ? PanelTheme.text1 : PanelTheme.inspectorText)
        addHit(cell, .keyframe(key))
    }

    /// The track from `trackX` and the value text ending at `valueRight`, on `line`.
    func drawSliderControl(_ c: CanvasContext, line: CanvasRect, _ s: InspectorRow.Slider, trackX: Double, valueRight: Double) {
        let valueRect = CanvasRect(x: valueRight - Self.sliderValueWidth, y: line.midY - 7.5, width: Self.sliderValueWidth, height: 15)
        let drag = sliderDrag?.key == s.key ? sliderDrag : nil
        let pos = drag?.current ?? s.position
        let custom = s.tier == .explicitCustom || drag != nil
        let editing = field?.key == s.key
        let text = editing ? (field?.draft ?? s.display) : (drag != nil ? s.format(pos) : s.display)
        if editing { drawFieldEditing(c, valueRect, text: text, font: PanelTheme.mono(11), readOnly: false) }
        PanelDraw.text(c, text, in: valueRect, font: PanelTheme.mono(11),
                       color: s.tier.valueInk(disabled: s.disabled, adjusting: drag != nil), align: .right)
        let track = CanvasRect(x: trackX, y: line.midY - PanelGrid.minTarget / 2, width: max(10, valueRect.x - 8 - trackX), height: PanelGrid.minTarget)
        let pct = max(0, min(1, (pos - s.min) / max(1e-9, s.max - s.min)))
        let lineY = track.midY - 1
        c.fillRoundedRect(CanvasRect(x: track.x, y: lineY, width: track.width, height: 2), radius: 1, PanelTheme.inspectorControl)
        if s.centerTick { c.fillRect(CanvasRect(x: track.midX - 0.5, y: lineY - 1, width: 1, height: 4), PanelTheme.inspectorText) }
        if custom { c.fillRoundedRect(CanvasRect(x: track.x, y: lineY, width: track.width * pct, height: 2), radius: 1, PanelTheme.inspectorText) }
        let k = custom ? 8.0 : 7.0
        c.fill(.roundedRect(CanvasRect(x: track.x + track.width * pct - k / 2, y: track.midY - k / 2, width: k, height: k), radius: k / 2),
               custom ? PanelTheme.white : PanelTheme.inspectorText)
        if !s.disabled {
            addHit(track, .slider(s.key))
            addHit(Self.target(valueRect), .field(s.key))
        }
    }

    /// FlatToggle: grey label (rowLabel, truncated before the switch), 24×14 pill ending at the value edge, knob 10px
    /// (accent on the right when on, text-4 on the left when off); the target is the switch's cell, the row tall.
    func drawToggle(_ c: CanvasContext, _ r: CanvasRect, _ t: InspectorRow.Toggle) {
        let sw = CanvasRect(x: Self.valueEdge(r) - 24, y: r.y + (r.height - 14) / 2, width: 24, height: 14)
        PanelDraw.text(c, t.label, in: CanvasRect(x: r.x, y: r.y, width: max(0, sw.x - PanelGrid.columnGap - r.x), height: r.height),
                       font: Self.rowFont, color: t.tier.labelColor)
        c.fillRoundedRect(sw, radius: 7, t.on ? PanelTheme.accent.withAlpha(0.35) : PanelTheme.panelHover)
        let knob = CanvasRect(x: t.on ? sw.maxX - 12 : sw.x + 2, y: sw.y + 2, width: 10, height: 10)
        c.fillRoundedRect(knob, radius: 5, t.on ? PanelTheme.accent : PanelTheme.inspectorText)
        addHit(CanvasRect(x: sw.x - 4, y: r.y, width: sw.width + 4, height: r.height), .toggle(t.key))
    }

    /// Each option's natural width: its label plus padding, never under a target.
    static func segmentWidths(_ c: CanvasContext, _ s: InspectorRow.Segmented) -> [Double] {
        s.options.map { max(PanelGrid.minTarget, s.icons[$0.key] == nil ? c.measureText($0.label, font: rowFont).width + segmentPad : PanelGrid.minTarget) }
    }

    /// The options' natural width side by side.
    static func segmentsWidth(_ c: CanvasContext, _ s: InspectorRow.Segmented) -> Double {
        segmentWidths(c, s).reduce(0, +) + segmentGap * Double(max(0, s.options.count - 1))
    }

    /// The options laid left to right across `area`, 28 tall and centred on the line: each grows by an equal share of
    /// the room left, so the control starts at the area's left edge and ends at its right one; when their natural
    /// widths overflow `area` they share it equally (labels truncate), so they never leave it.
    static func segmentRects(_ widths: [Double], in area: CanvasRect) -> [CanvasRect] {
        let n = Double(max(1, widths.count))
        let natural = widths.reduce(0, +) + segmentGap * (n - 1)
        let share = (area.width - segmentGap * (n - 1)) / n
        let extra = (area.width - natural) / n
        var x = area.x
        let h = PanelGrid.rowHeight - 4
        return widths.map { w in
            let ow = natural > area.width ? max(0, share) : w + extra
            defer { x += ow + segmentGap }
            return CanvasRect(x: x, y: area.midY - h / 2, width: ow, height: h)
        }
    }

    /// FlatSegmentedRow: the 11px grey label (rowLabel) in the label column, the options from the control column; each
    /// option an 11px label over a 2px underline, the active one text-0 on the accent, the rest text-4 (hover text-2).
    /// Stacked (the options do not fit beside the label, issue #154): the label line, then the options from the row's
    /// left edge across its width. The options never draw over the label.
    func drawSegmented(_ c: CanvasContext, _ r: CanvasRect, _ s: InspectorRow.Segmented, stacked: Bool = false) {
        let lines = stacked ? Self.stackedLines(r) : (r, r)
        let cols = PanelGrid.columns(lines.0)
        PanelDraw.text(c, s.label, in: CanvasRect(x: r.x, y: lines.0.midY - 8.25, width: stacked ? r.width : cols.label.width, height: 16.5),
                       font: Self.rowFont, color: PanelTheme.rowLabel)
        let area = stacked ? lines.1 : CanvasRect(x: cols.control.x, y: r.y, width: max(0, Self.valueEdge(r) - cols.control.x), height: r.height)
        for (o, or) in zip(s.options, Self.segmentRects(Self.segmentWidths(c, s), in: area)) {
            let hov = hovered == .segment(s.key, o.key)
            let color = o.active ? PanelTheme.text0 : (hov ? PanelTheme.text2 : PanelTheme.inspectorText)
            if let icon = s.icons[o.key] {
                icon.draw(c, in: CanvasRect(x: or.midX - 8, y: or.midY - 8, width: 16, height: 16), color: color)
            } else {
                PanelDraw.text(c, o.label, in: CanvasRect(x: or.x + 2, y: or.midY - 8.25, width: max(0, or.width - 4), height: 16.5),
                               font: Self.rowFont, color: color, align: .center)
            }
            if o.active { c.fillRect(CanvasRect(x: or.x, y: or.maxY - 2, width: or.width, height: 2), PanelTheme.accent) }
            addHit(or, .segment(s.key, o.key))
        }
    }

    // MARK: Buttons, FX nodes

    func drawButton(_ c: CanvasContext, _ r: CanvasRect, _ b: InspectorRow.Button, plain: Bool) {
        let hov = hovered == .button(b.key)
        let font = PanelTheme.font(plain ? 10 : 11, .medium)
        if let icon = b.icon {
            icon.draw(c, in: CanvasRect(x: r.midX - 7, y: r.midY - 7, width: 14, height: 14), color: hov ? PanelTheme.text1 : PanelTheme.text3)
            if !b.disabled { addHit(r, .button(b.key)) }
            return
        }
        switch b.style {
        case .accent: PanelDraw.text(c, b.label, in: r, font: font, color: PanelTheme.accent, align: .center)
        case .muted: PanelDraw.text(c, b.label, in: r, font: font, color: hov ? PanelTheme.text1 : PanelTheme.inspectorText, align: .center)
        case .danger: PanelDraw.text(c, b.label, in: r, font: font, color: PanelTheme.red400, align: .center)
        case .chip, .chipActive: drawChip(c, r, b, hovered: hov)
        }
        if !b.disabled { addHit(r, .button(b.key)) }
    }

    func drawChip(_ c: CanvasContext, _ r: CanvasRect, _ b: InspectorRow.Button, hovered hov: Bool) {
        let active = b.style == .chipActive
        c.fillRoundedRect(r, radius: PanelTheme.radiusMd, active ? PanelTheme.accent.withAlpha(0.18) : (hov ? PanelTheme.panelHover : PanelTheme.panelInput))
        c.strokeRoundedRect(r.insetBy(0.5), radius: PanelTheme.radiusMd - 0.5, active ? PanelTheme.accent.withAlpha(0.5) : PanelTheme.panelBorderInput, width: 1)
        PanelDraw.text(c, b.label, in: r.insetBy(4), font: PanelTheme.font(11, .medium), color: active ? PanelTheme.text0 : PanelTheme.text2, align: .center)
    }

    /// FX rack row: bypass switch, name, type, remove ×; both controls are target-sized.
    func drawFxNode(_ c: CanvasContext, _ r: CanvasRect, _ n: InspectorRow.FxNode) {
        let dot = CanvasRect(x: r.x, y: r.y + (r.height - 14) / 2, width: 24, height: 14)
        c.fillRoundedRect(dot, radius: 7, n.enabled ? PanelTheme.accent.withAlpha(0.35) : PanelTheme.panelHover)
        c.fillRoundedRect(CanvasRect(x: n.enabled ? dot.maxX - 12 : dot.x + 2, y: dot.y + 2, width: 10, height: 10), radius: 5,
                          n.enabled ? PanelTheme.accent : PanelTheme.inspectorText)
        addHit(Self.target(dot), .fxToggle(n.key))
        let rm = CanvasRect(x: r.maxX - PanelGrid.minTarget, y: r.midY - PanelGrid.minTarget / 2, width: PanelGrid.minTarget, height: PanelGrid.minTarget)
        PanelIcon.close.draw(c, in: CanvasRect(x: rm.maxX - 12, y: rm.midY - 5, width: 10, height: 10),
                             color: hovered == .fxRemove(n.key) ? PanelTheme.red400 : PanelTheme.inspectorText)
        addHit(rm, .fxRemove(n.key))
        let tx = dot.maxX + 8
        let ls = PanelDraw.text(c, n.label, in: CanvasRect(x: tx, y: r.y, width: max(0, rm.x - tx - 8) * 0.6, height: r.height),
                                font: PanelTheme.font(11, .medium), color: n.enabled ? PanelTheme.text1 : PanelTheme.inspectorText)
        if n.detail != n.label {
            PanelDraw.text(c, n.detail, in: CanvasRect(x: tx + ls.width + 6, y: r.y + 1, width: max(0, rm.x - tx - ls.width - 14), height: r.height),
                           font: PanelTheme.mono(11), color: PanelTheme.inspectorText)
        }
    }
}
