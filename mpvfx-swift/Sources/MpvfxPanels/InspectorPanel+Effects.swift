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

/// UI state of the Effects group (per selected clip).
public struct EffectsUIState: Equatable {
    var clipId: String?
    /// The "Add effect" catalog; nil until toggled, which means open exactly when no effect is active.
    var catalogOpen: Bool?
    var catalogFamily = EffectSpecs.families[0].label
    var selectedKey: String?
}

/// Effects: the active effects as a list, the selected one's editor on a
/// border-input rail (Mix / settings), "Add effect", and the catalog: a 4-column family tab strip over a tile grid
/// of the family's looks and effects. Every value is an amount in the clip's grade (undoable).
extension InspectorPanel {
    func stylizeGroup(_ editor: TimelineEditor, _ s: Selected) -> InspectorGroup {
        let g = editor.colorGrading(clipId: s.id) ?? ColorGrading()
        let commit: (ColorGrading) -> Void = { [weak self] n in self?.edited(editor.setColorGrading(clipId: s.id, n)) }
        if effectsUI.clipId != s.id { effectsUI = EffectsUIState(clipId: s.id) }
        let active = EffectSpecs.all.filter { EffectSpecs.isActive(g, $0.key) }
        let catalogOpen = effectsUI.catalogOpen ?? active.isEmpty
        let selected = active.first { $0.key == effectsUI.selectedKey } ?? active.first
        func applying(_ spec: EffectSpecs.Spec) -> ColorGrading {
            var n = g; for (k, v) in EffectSpecs.applyDefaults[spec.key] ?? [:] { n.effects[k] = v }; return n
        }
        let apply: (EffectSpecs.Spec) -> Void = { [weak self] spec in
            self?.effectsUI.selectedKey = spec.key; self?.effectsUI.catalogOpen = false
            commit(applying(spec))
        }

        var rows: [InspectorRow] = []   // `space-y-2`
        func gap(_ h: Double, rail: Bool = false) { rows.append(.init(.spacer(h), rail: rail)) }
        if !active.isEmpty {
            for (i, e) in active.enumerated() {
                if i > 0 { gap(4) }
                rows.append(.init(.custom(activeEffectRow(e, selected: e.key == selected?.key))))
            }
            gap(8)
        }
        if let sel = selected {
            rows.append(.init(.custom(effectEditorHeader(sel, reapply: { apply(sel) }, remove: { [weak self] in
                self?.effectsUI.selectedKey = nil
                var n = g; n.effects[sel.key] = 0; commit(n)
            })), rail: true))
            if sel.showMaster {
                gap(4, rail: true)
                let v = g.effect(sel.key) * 100
                let fmt: (Double) -> String = { x in sel.masterFormat?(x / 100) ?? "\(Int(x.rounded()))%" }
                rows.append(.init(.slider(.init(key: "fx:\(sel.key)", label: sel.masterLabel, position: v, min: 0, max: sel.max,
                                                display: fmt(v), format: fmt, tier: .explicitCustom,
                                                commit: { x in var n = g; n.effects[sel.key] = (x / 100 * 1000).rounded() / 1000; commit(n) },
                                                reset: { var n = g; n.effects[sel.key] = EffectSpecs.resetValue(effect: sel.key, sel.key); commit(n) })),
                                  rail: true))
            }
            for control in sel.settings {
                gap(4, rail: true)
                rows.append(effectControlRow(control, sel, g, commit: commit))
            }
            gap(8)
        }
        rows.append(.init(.custom(addEffectToggle(open: catalogOpen))))
        if catalogOpen {
            gap(8)
            rows.append(.init(.custom(effectFamilyTabs())))
            gap(8)
            let fam = EffectSpecs.families.first { $0.label == effectsUI.catalogFamily } ?? EffectSpecs.families[0]
            let looks = fam.presets.compactMap(ColorGrading.preset)
            var tiles: [CatalogTile] = looks.map { ($0.label, g.preset == $0.id, Self.lookDemo($0, base: g, clipId: s.id)) }
            tiles += fam.effects.map { ($0.label, EffectSpecs.isActive(g, $0.key), Self.effectDemo($0, base: g, clipId: s.id)) }
            rows.append(.init(.custom(tileGrid(id: "fx:tiles", tiles) { [weak self] i in
                if i < looks.count {
                    var n = g.applying(looks[i]); n.lut = g.lut; commit(n)   // a look replaces the grade, keeping the LUT
                    return
                }
                let spec = fam.effects[i - looks.count]
                if EffectSpecs.isActive(g, spec.key) {
                    self?.effectsUI.selectedKey = spec.key; self?.effectsUI.catalogOpen = false; self?.onEdited?()
                } else { apply(spec) }
            })))
        }
        var group = InspectorGroup(id: "effects", title: "Effects", summary: active.isEmpty ? "none" : "\(active.count) active", rows: rows, spacing: 0)
        // FlatEffectsAccessory: reset every effect (and the palette) while any is active.
        if !active.isEmpty {
            group.reset = { var n = g; for k in ColorGrading.activeEffectKeys { n.effects[k] = nil }; n.palette = nil; commit(n) }
        }
        return group
    }

    /// An active effect: `min-h-[30px] border px-2 text-[10px]`, accent/10 on the accent border while it is the one
    /// being edited ("Editing"), else bg-panel-bg-soft on the hairline ("Active", 9px text-5).
    func activeEffectRow(_ e: EffectSpecs.Spec, selected: Bool) -> InspectorCustomRow {
        InspectorCustomRow(id: "fx:active:\(e.key)", height: 30, draw: { c, r, panel in
            let hot = panel.hovered == .custom("fx:active:\(e.key)", 0)
            if selected { c.fillRect(r.snapped, PanelTheme.accent.withAlpha(0.1)) }   // bg-panel-bg-soft is not a theme colour: transparent
            c.strokeRect(r.snapped.insetBy(0.5), selected ? PanelTheme.accent : (hot ? PanelTheme.panelBorderInput : PanelTheme.panelHairline), width: 1)
            PanelDraw.text(c, e.label, in: CanvasRect(x: r.x + 9, y: r.midY - 7.5, width: r.width - 60, height: 15), font: PanelTheme.font(10),
                           color: selected ? PanelTheme.text0 : (hot ? PanelTheme.text1 : PanelTheme.text3))
            PanelDraw.text(c, selected ? "Editing" : "Active", in: CanvasRect(x: r.x + 9, y: r.midY - 6.75, width: r.width - 18, height: 13.5),
                           font: PanelTheme.font(9), color: PanelTheme.text5, align: .right)
            panel.addHit(r, .custom("fx:active:\(e.key)", 0))
        }, pointer: { [weak self] _, _, phase in
            guard let self, phase == 0 else { return }
            self.effectsUI.selectedKey = e.key; self.onEdited?()
        })
    }

    /// The editor's head: `min-h-[26px]` 11px medium text-1 name, then reset ↺ and remove × at 11px (text-4, gap-2).
    func effectEditorHeader(_ e: EffectSpecs.Spec, reapply: @escaping () -> Void, remove: @escaping () -> Void) -> InspectorCustomRow {
        InspectorCustomRow(id: "fx:head", height: 26, draw: { c, r, panel in
            PanelDraw.text(c, e.label, in: CanvasRect(x: r.x, y: r.midY - 8.25, width: r.width - 40, height: 16.5), font: PanelTheme.font(11, .medium), color: PanelTheme.text1)
            let x = CanvasRect(x: r.maxX - 11, y: r.midY - 5.5, width: 11, height: 11)
            let reset = CanvasRect(x: x.x - 8 - 11, y: x.y, width: 11, height: 11)
            PanelIcon.reset.draw(c, in: reset, color: panel.hovered == .custom("fx:head", 0) ? PanelTheme.text1 : PanelTheme.text4)
            PanelIcon.close.draw(c, in: x, color: panel.hovered == .custom("fx:head", 1) ? CanvasColor(ThemeTokens.red300) : PanelTheme.text4)
            panel.addHit(reset.insetBy(-3), .custom("fx:head", 0))
            panel.addHit(x.insetBy(-3), .custom("fx:head", 1))
        }, pointer: { part, _, phase in
            guard phase == 0 else { return }
            if part == 0 { reapply() } else { remove() }
        })
    }

    /// FlatEffectControl: a slider, a toggle (on at ≥ 0.5) or a select row, reset to the effect's add value.
    func effectControlRow(_ control: EffectSpecs.Control, _ e: EffectSpecs.Spec, _ g: ColorGrading,
                          commit: @escaping (ColorGrading) -> Void) -> InspectorRow {
        let key = control.key
        let value = EffectSpecs.value(g, key), def = EffectSpecs.resetValue(effect: e.key, key)
        let set: (Double) -> Void = { v in var n = g; n.effects[key] = v; commit(n) }
        let tier: PropertyValueTier = abs(value - def) > 0.0001 ? .explicitCustom : .default
        switch control {
        case .slider(_, let label, let lo, let hi, let scale, let unit, let format):
            let fmt: (Double) -> String = { x in
                format?(x / scale) ?? (x == x.rounded() ? "\(Int(x))\(unit)" : String(format: "%.1f%@", x, unit))
            }
            return .init(.slider(.init(key: "fx:set:\(key)", label: label, position: value * scale, min: lo, max: hi,
                                       display: fmt((value * scale).rounded()), format: { fmt($0.rounded()) }, tier: tier,
                                       commit: { x in set((x.rounded() / scale * 10000).rounded() / 10000) }, reset: { set(def) })), rail: true)
        case .toggle(_, let label):
            return .init(.toggle(.init(key: "fx:set:\(key)", label: label, on: value >= 0.5, tier: tier, set: { set($0 ? 1 : 0) }, reset: { set(def) })), rail: true)
        case .select(_, let label, let options):
            let i = max(0, min(options.count - 1, Int(value.rounded())))
            return .init(.custom(InspectorCustomRow(id: "fx:sel:\(key)", height: 30, draw: { c, r, panel in
                // FlatSelectRow: 11px tier label; mono 11px value + 10px caret on a 1px underline (accent/30 when custom).
                PanelDraw.text(c, label, in: CanvasRect(x: r.x, y: r.midY - 8.25, width: r.width / 2, height: 16.5), font: PanelTheme.font(11),
                               color: tier == .explicitCustom ? PanelTheme.text2 : PanelTheme.text3)
                let tw = c.measureText(options[i], font: PanelTheme.mono(11)).width
                let box = CanvasRect(x: r.maxX - tw - 16, y: r.midY - 8.75, width: tw + 16, height: 17.5)
                PanelDraw.text(c, options[i], in: CanvasRect(x: box.x, y: box.y, width: tw + 1, height: 16.5), font: PanelTheme.mono(11),
                               color: tier == .explicitCustom ? PanelTheme.text0 : PanelTheme.text1)
                PanelIcon.groupCaretDown.draw(c, in: CanvasRect(x: box.maxX - 10, y: box.y + 3.25, width: 10, height: 10), color: PanelTheme.text4)
                let hot = panel.hovered == .custom("fx:sel:\(key)", 0)
                let line = tier == .explicitCustom ? PanelTheme.accent.withAlpha(hot ? 0.7 : 0.3) : PanelTheme.panelBorderInput.withAlpha(hot ? 1 : 0.5)
                c.fillRect(CanvasRect(x: box.x, y: box.maxY - 1, width: box.width, height: 1).snapped, line)
                panel.addHit(box.insetBy(-3), .custom("fx:sel:\(key)", 0))
            }, pointer: { _, _, phase in if phase == 0 { set(Double((i + 1) % options.count)) } })), rail: true)
        }
    }

    /// `flex min-h-[30px] gap-1 text-[10px] font-medium text-panel-accent`: an 11px plus and "Add effect".
    func addEffectToggle(open: Bool) -> InspectorCustomRow {
        InspectorCustomRow(id: "fx:add", height: 30, draw: { c, r, panel in
            let color = panel.hovered == .custom("fx:add", 0) ? PanelTheme.accent.withAlpha(0.8) : PanelTheme.accent
            PanelIcon.plus.draw(c, in: CanvasRect(x: r.x, y: r.midY - 5.5 + 1, width: 11, height: 11), color: color)
            let w = c.measureText("Add effect", font: PanelTheme.font(10, .medium)).width
            PanelDraw.text(c, "Add effect", in: CanvasRect(x: r.x + 15, y: r.midY - 7.5, width: w + 1, height: 15), font: PanelTheme.font(10, .medium), color: color)
            panel.addHit(CanvasRect(x: r.x, y: r.y, width: 15 + w, height: r.height), .custom("fx:add", 0))
        }, pointer: { [weak self] _, _, phase in
            guard let self, phase == 0 else { return }
            self.effectsUI.catalogOpen = !open; self.onEdited?()
        })
    }

    /// `grid grid-cols-4 gap-px border border-panel-hairline bg-panel-hairline`: 25px bg-panel-bg tabs, 9px labels,
    /// the open family medium accent, the rest text-4 (hover text-1).
    func effectFamilyTabs() -> InspectorCustomRow {
        let fams = EffectSpecs.families
        return InspectorCustomRow(id: "fx:tabs", height: 27, draw: { [weak self] c, r, panel in
            guard let self else { return }
            c.fillRect(r.snapped, PanelTheme.panelHairline)
            let w = (r.width - 2 - Double(fams.count - 1)) / Double(fams.count)
            for (i, f) in fams.enumerated() {
                let tr = CanvasRect(x: r.x + 1 + Double(i) * (w + 1), y: r.y + 1, width: w, height: 25)
                c.fillRect(tr.snapped, PanelTheme.panelBg)
                let on = f.label == self.effectsUI.catalogFamily
                PanelDraw.text(c, f.label, in: CanvasRect(x: tr.x + 8, y: tr.midY - 6.75, width: tr.width - 16, height: 13.5),
                               font: PanelTheme.font(9, on ? .medium : .regular),
                               color: on ? PanelTheme.accent : (panel.hovered == .custom("fx:tabs", i) ? PanelTheme.text1 : PanelTheme.text4), align: .center)
                panel.addHit(tr, .custom("fx:tabs", i))
            }
        }, pointer: { [weak self] part, _, phase in
            guard let self, phase == 0, fams.indices.contains(part) else { return }
            self.effectsUI.catalogFamily = fams[part].label; self.onEdited?()
        })
    }

    /// FLAT_PREVIEW_GRID tiles (`grid-cols-3 gap-1`): a 16:9 bg-black/20 frame over a `px-2 py-1.5` 10px label, the
    /// active ones accent/10 on the accent border. The frame shows the host's sample picture with the tile's look or
    /// effect (`effectPreview`), its "Rendering" caption, or a placeholder with the reason.
    typealias CatalogTile = (label: String, on: Bool, demo: TileDemo)

    func tileGrid(id: String, _ tiles: [CatalogTile], onPick: @escaping (Int) -> Void) -> InspectorCustomRow {
        let cols = 3, gap = 4.0
        // The height follows the width the body draws at (the panel is resizable), as the Grade preset grid's does.
        let height = Self.previewGridHeight(count: max(1, tiles.count), width: bodyContentWidth, columns: cols, gap: gap)
        return InspectorCustomRow(id: id, height: height, draw: { [weak self] c, r, panel in
            let w = (r.width - gap * Double(cols - 1)) / Double(cols)
            let h = 2 + (w - 2) * 9 / 16 + 27
            for (i, t) in tiles.enumerated() {
                let tr = CanvasRect(x: r.x + Double(i % cols) * (w + gap), y: r.y + Double(i / cols) * (h + gap), width: w, height: h)
                let hov = panel.hovered == .custom(id, i)
                if t.on { c.fillRect(tr, PanelTheme.accent.withAlpha(0.1)) }   // bg-panel-bg-soft resolves to transparent
                let sw = CanvasRect(x: tr.x + 1, y: tr.y + 1, width: tr.width - 2, height: (tr.width - 2) * 9 / 16)
                // The clip frame (else the sample picture) with the tile's look or effect, at the tile's device pixels (capped).
                let px = Self.tilePixels(sw, scale: c.deviceScale)
                Self.drawPreviewFrame(c, sw, self?.samplePreview(t.demo, px.width, px.height) ?? .failed(.noRenderer))
                PanelDraw.text(c, t.label, in: CanvasRect(x: tr.x + 9, y: sw.maxY + 6, width: tr.width - 18, height: 15), font: PanelTheme.font(10),
                               color: t.on ? PanelTheme.text1 : (hov ? PanelTheme.text1 : PanelTheme.text3))
                c.strokeRect(tr.insetBy(0.5), t.on ? PanelTheme.accent : (hov ? PanelTheme.panelBorderInput : PanelTheme.panelHairline), width: 1)
                panel.addHit(tr, .custom(id, i))
            }
        }, pointer: { part, _, phase in if phase == 0, tiles.indices.contains(part) { onPick(part) } })
    }
}
