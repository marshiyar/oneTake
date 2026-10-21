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

/// UI state of the Grade group that is not part of the document.
public struct GradeUIState: Equatable {
    public var curveTab = "master"
    public var selectedPoint: Int?
    public var selectedSecondary = 0
    public var lutOpen = false
    public var finishSettings: String?        // "vignette" | "grain"
    public var copyToProject = false
    /// Live values while a wheel (`<set id>:<wheel>`) / curve point is dragged (committed on release).
    var wheelDraft: (key: String, wheel: ColorGrading.Wheel)?
    var curveDraft: [[Double]]?
    /// The pressed curve point: the pointer's offset from its centre, where the press was, and whether it has moved
    /// past the drag threshold (a click that only selects a point never moves it).
    var curveGrab: (dx: Double, dy: Double, start: CanvasPoint, moved: Bool)?
    /// The last press that selected a curve point (tab, index, editor clock), for double-click delete.
    var curveClick: (tab: String, index: Int, time: Double)?
    /// Geometry from the last draw (rows are rebuilt per event, so it lives here).
    var curveBox = CanvasRect(x: 0, y: 0, width: 1, height: 1)
    /// Scopes disclosure (closed by default) and which scopes it shows, how (InspectorPanel+Scopes.swift).
    public var scopesOpen = false
    public var scopes = ScopeSettings()
    /// The secondary eyedropper: the captured frame, whether a capture is still
    /// rendering or failed, Source / Selection matte view, and where the frame was drawn last.
    public internal(set) var sampleFrame: CanvasImage?
    var samplePending = false
    public internal(set) var sampleError = false
    public var showMatte = false
    var sampleRect = CanvasRect(x: 0, y: 0, width: 0, height: 0)
    var matteMemo: (key: ColorGrading.Secondary, image: CanvasImage)?
    public static func == (a: GradeUIState, b: GradeUIState) -> Bool {
        a.curveTab == b.curveTab && a.selectedPoint == b.selectedPoint && a.selectedSecondary == b.selectedSecondary && a.lutOpen == b.lutOpen
            && a.finishSettings == b.finishSettings && a.copyToProject == b.copyToProject
            && a.scopesOpen == b.scopesOpen && a.scopes == b.scopes
    }
}

/// Grade group: presets, Amount, Primary, Color wheels, Curves (7 modes),
/// Secondary color, Custom LUT, Finish, Copy grade to. Edits write the clip's color-grading effect (undoable).
extension InspectorPanel {
    var isGradePasteEnabled: Bool {
        guard onPasteGrade != nil, gradeClipboardAvailable, let editor else { return false }
        let kinds = Dictionary(editor.document.assets.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        return selection.contains { id in
            guard let clip = editor.clip(id)?.clip else { return false }
            return kinds[clip.assetId] == .video || kinds[clip.assetId] == .image
        }
    }

    func gradeGroup(_ editor: TimelineEditor, _ s: Selected) -> InspectorGroup {
        // Animated values (issue #179) show their value at the playhead, and an edit of one keys it there.
        let t = time, g = editor.gradeShown(clipId: s.id, time: t)
        let commit: (ColorGrading) -> Void = { [weak self] next in self?.edited(editor.commitGrade(clipId: s.id, time: t, shown: g, next: next)) }
        // Sections `space-y-1.5` apart; slider lists `space-y-0.5`.
        var rows: [InspectorRow] = []
        func gap(_ h: Double) { rows.append(.init(.spacer(h))) }
        let presets = ColorGrading.gradePresets
        let lut = g.lut, version = g.version
        // Sections `space-y-3`: Scopes, then the preset block (`space-y-1.5`) whose "Retry look previews" link shows
        // while the look frames are unavailable (an inline button on an 18px line).
        rows.append(.init(.custom(scopesRow(s.id))))
        gap(12)
        if presetPreview == nil || presetPreviewsAvailable?(s.id) == false {
            rows.append(.init(.custom(retryPreviewsRow())))
            gap(6)
        }
        rows.append(.init(.custom(presetGrid(presets, selected: g.preset, preview: { [weak self] id, w, h in
            self?.lookPreview(PresetPreviewRequest(clipId: s.id, presetId: id, lutSrc: lut?.src, lutIntensity: lut?.intensity ?? 1,
                                                   pixelWidth: w, pixelHeight: h, version: version)) ?? .failed(.noRenderer)
        }, onPick: { p in commit(g.applying(p)) }))))
        gap(6)
        rows.append(.init(.slider(.init(key: "grade:amount", label: "Amount", position: g.intensity * 100, min: 0, max: 100,
                                        display: "\(Int((g.intensity * 100).rounded()))%", format: { "\(Int($0.rounded()))%" },
                                        tier: g.intensity == 1 ? .default : .explicitCustom,
                                        commit: { v in var n = g; n.intensity = max(0, min(1, v / 100)); commit(n) },
                                        reset: { var n = g; n.intensity = 1; commit(n) },
                                        keyframe: gradeKeyframe(editor, s, [NativeGradeParameter.intensityId], shown: g)))))
        gap(6)
        rows.append(.init(.section("Primary")))
        gap(4)
        rows += primaryRows(editor, s, g, commit: commit)
        gap(6)
        rows.append(.init(.section("Color wheels")))
        gap(6)
        rows.append(.init(.custom(colorWheels(g, .balance, commit: commit)), controls: wheelFieldControls(g, .balance, commit: commit)))
        // Keep tonal wheels available so a neutral grade can start a wheel animation.
        gap(12)
        rows.append(.init(.heading("Tonal wheels", trailing: nil)))
        rows.append(.init(.custom(colorWheels(g, .tonal, commit: commit)), controls: wheelFieldControls(g, .tonal, commit: commit)))
        rows.append(wheelKeyframesRow(editor, s, shown: g))
        gap(6)
        rows.append(.init(.section("Curves")))
        gap(6)
        rows.append(.init(.custom(curveTabsRow(g))))
        gap(8)
        rows.append(.init(.custom(curveGraph(g, commit: commit))))
        gap(8)
        rows.append(contentsOf: curvePointRows(g, set: { editor.setColorGrading(clipId: s.id, $0) }))
        gap(6)
        rows.append(.init(.custom(curveFooter(g, commit: commit))))
        gap(2)
        rows.append(.init(.custom(curveHintRow())))
        gap(6)
        rows.append(contentsOf: secondaryRows(g, commit: commit))
        gap(6)
        rows.append(contentsOf: lutRows(g, commit: commit))
        gap(6)
        rows.append(.init(.section("Finish")))
        gap(6)
        for (i, key) in ["vignette", "grain"].enumerated() {
            if i > 0 { gap(6) }
            rows.append(detailSlider(g, key, commit: commit, gear: true,
                                     keyframe: gradeKeyframe(editor, s, [NativeGradeParameter.detailId(key)], shown: g)))
            if grade.finishSettings == key {
                let tune = key == "vignette" ? ["vignetteMidpoint", "vignetteRoundness", "vignetteFeather"] : ["grainSize", "grainRoughness"]
                for t in tune { gap(2); rows.append(detailSlider(g, t, commit: commit, gear: false)) }
            }
        }
        // Copy grade to: `flex justify-between border-t border-panel-hairline pt-1.5`, a 11px text-2 label with a
        // mono 11px text-0 select on a border-input/50 underline (clicking flips the two scopes), Apply in accent.
        gap(6)
        rows.append(.init(.custom(gradeClipboardRow())))
        gap(4)
        rows.append(.init(.custom(copyGradeRow(g, apply: { [weak self] in
            guard let self else { return }
            self.edited(editor.copyColorGrading(from: s.id, toAllProjectMedia: self.grade.copyToProject) > 0)
        }))))
        let summary = g.enabled ? "\(g.preset ?? "neutral") · \(Int((g.intensity * 100).rounded()))%" : "off"
        var group = InspectorGroup(id: "grade", title: "Grade", summary: summary, rows: rows, spacing: 0)
        group.enabled = g.enabled
        group.accessibilityLabel = "Grade enabled"
        group.setEnabled = { v in var n = g; n.enabled = v; commit(n) }
        // FlatColorGradingAccessory's reset (RotateCcw 12, text-3). Hold-to-compare and the runtime status pill are
        // not drawn: the native preview has no compare bypass or runtime handshake yet.
        group.reset = g.isAuthored ? { commit(ColorGrading()) } : nil
        return group
    }

    /// The ten Primary sliders, `space-y-0.5`, each keyframeable (issue #179).
    func primaryRows(_ editor: TimelineEditor, _ s: Selected, _ g: ColorGrading, commit: @escaping (ColorGrading) -> Void) -> [InspectorRow] {
        var rows: [InspectorRow] = []
        for (i, a) in ColorGrading.adjustSliders.enumerated() {
            if i > 0 { rows.append(.init(.spacer(2))) }
            let v = g.adjustValue(a.key) * a.scale
            let fmt: (Double) -> String = { x in a.key == "exposure" ? String(format: "%+.2f", x / 100) : "\(Int(x.rounded()))\(a.suffix)" }
            rows.append(.init(.slider(.init(key: "grade:adj:\(a.key)", label: a.label, position: v, min: a.min, max: a.max, display: fmt(v), format: fmt,
                                            tier: abs(v) > 1e-6 ? .explicitCustom : .default, centerTick: true,
                                            commit: { x in var n = g; n.adjust[a.key] = (x / a.scale * 1000).rounded() / 1000; commit(n) },
                                            reset: { var n = g; n.adjust[a.key] = 0; commit(n) },   // 0, not nil: a missing key reads the preset's value
                                            keyframe: gradeKeyframe(editor, s, [NativeGradeParameter.adjustId(a.key)], shown: g)))))
            if a.key == "contrast" { rows.append(.init(.spacer(2))); rows.append(pivotSlider(g, commit: commit)) }
        }
        return rows
    }

    /// Contrast's pivot (issue #176): the luma that contrast leaves unchanged, 50% by default (how older grades draw).
    func pivotSlider(_ g: ColorGrading, commit: @escaping (ColorGrading) -> Void) -> InspectorRow {
        let v = g.pivotValue * 100
        let fmt: (Double) -> String = { "\(Int($0.rounded()))%" }
        return .init(.slider(.init(key: "grade:adj:pivot", label: "Pivot", position: v, min: 0, max: 100, display: fmt(v), format: fmt,
                                   tier: abs(v - 50) > 1e-6 ? .explicitCustom : .default, centerTick: true,
                                   commit: { x in var n = g; n.pivot = (min(100, max(0, x)) * 10).rounded() / 1000; commit(n) },
                                   reset: { var n = g; n.pivot = nil; commit(n) })))
    }

    func gradeClipboardRow() -> InspectorCustomRow {
        InspectorCustomRow(id: "grade:clipboard", height: 28, draw: { [weak self] c, r, panel in
            guard let self else { return }
            let pasteEnabled = self.isGradePasteEnabled
            let gap = 6.0, width = (r.width - gap) / 2
            let copy = CanvasRect(x: r.x, y: r.y + 2, width: width, height: 24)
            let paste = CanvasRect(x: copy.maxX + gap, y: copy.y, width: width, height: 24)
            PanelDraw.smallButton(c, copy, label: "Copy grade",
                                  fill: panel.hovered == .custom("grade:clipboard", 0) ? PanelTheme.panelHover : PanelTheme.panelSurface,
                                  color: PanelTheme.text1)
            PanelDraw.smallButton(c, paste, label: "Paste grade",
                                  fill: panel.hovered == .custom("grade:clipboard", 1) ? PanelTheme.panelHover : PanelTheme.panelSurface,
                                  color: pasteEnabled ? PanelTheme.text1 : PanelTheme.text4)
            panel.addHit(copy, .custom("grade:clipboard", 0))
            if pasteEnabled { panel.addHit(paste, .custom("grade:clipboard", 1)) }
        }, pointer: { [weak self] part, _, phase in
            guard let self, phase == 0 else { return }
            _ = part == 0 ? onCopyGrade?() : onPasteGrade?()
            onEdited?()
        })
    }

    func copyGradeRow(_ g: ColorGrading, apply: @escaping () -> Void) -> InspectorCustomRow {
        InspectorCustomRow(id: "grade:copyto", height: 32, draw: { [weak self] c, r, panel in
            guard let self else { return }
            c.fillRect(CanvasRect(x: r.x, y: r.y, width: r.width, height: 1).snapped, PanelTheme.panelHairline)
            let line = CanvasRect(x: r.x, y: r.y + 5, width: r.width, height: 24)
            let label = "Copy grade to"
            let lw = c.measureText(label, font: PanelTheme.font(11)).width
            PanelDraw.text(c, label, in: CanvasRect(x: line.x, y: line.y, width: lw + 1, height: 16.5), font: PanelTheme.font(11), color: PanelTheme.text2)
            let option = self.grade.copyToProject ? "All project media" : "Current file media"
            let ow = c.measureText(option, font: PanelTheme.mono(11)).width + 18
            let sel = CanvasRect(x: line.x + lw + 6, y: line.y, width: ow, height: 24)
            let hot = panel.hovered == .custom("grade:copyto", 0)
            PanelDraw.text(c, option, in: CanvasRect(x: sel.x, y: sel.y, width: ow - 14, height: 16.5), font: PanelTheme.mono(11), color: PanelTheme.text0)
            PanelIcon.groupCaretDown.draw(c, in: CanvasRect(x: sel.maxX - 11, y: sel.midY - 5, width: 10, height: 10), color: PanelTheme.text3)
            c.fillRect(CanvasRect(x: sel.x, y: sel.maxY, width: sel.width, height: 1).snapped,
                       hot ? PanelTheme.panelBorderInput : PanelTheme.panelBorderInput.withAlpha(0.5))
            panel.addHit(sel.insetBy(-2), .custom("grade:copyto", 0))
            let aw = c.measureText("Apply", font: PanelTheme.font(11, .medium)).width
            let ap = CanvasRect(x: r.maxX - aw - 8, y: line.y, width: aw + 8, height: 24)
            let enabled = g.isAuthored
            PanelDraw.text(c, "Apply", in: ap, font: PanelTheme.font(11, .medium),
                           color: enabled ? (panel.hovered == .custom("grade:copyto", 1) ? PanelTheme.accent.withAlpha(0.8) : PanelTheme.accent) : PanelTheme.accent.withAlpha(0.5))
            if enabled { panel.addHit(ap.insetBy(-2), .custom("grade:copyto", 1)) }
        }, pointer: { [weak self] part, _, phase in
            guard let self, phase == 0 else { return }
            if part == 0 { self.grade.copyToProject.toggle(); self.onEdited?() } else { apply() }
        })
    }

    func detailSlider(_ g: ColorGrading, _ key: String, commit: @escaping (ColorGrading) -> Void, gear: Bool,
                      keyframe: InspectorRow.Keyframe? = nil) -> InspectorRow {
        let spec = ColorGrading.detailSliders.first { $0.key == key }!
        let v = g.detail(key) * 100, def = (ColorGrading.detailDefaults[key] ?? 0) * 100
        var row = InspectorRow.Slider(key: "grade:det:\(key)", label: spec.label, position: v, min: spec.min, max: spec.max,
                                      display: "\(Int(v.rounded()))%", format: { "\(Int($0.rounded()))%" },
                                      tier: abs(v - def) > 1e-6 ? .explicitCustom : .default,
                                      commit: { x in var n = g; n.details[key] = (x / 100 * 1000).rounded() / 1000; commit(n) },
                                      reset: { var n = g; n.details[key] = ColorGrading.defaultDetail(key); commit(n) })   // explicit, as above
        row.keyframe = keyframe
        if gear {   // Vignette settings / Grain settings
            row.settings = (grade.finishSettings == key, { [weak self] in
                guard let self else { return }
                self.grade.finishSettings = self.grade.finishSettings == key ? nil : key; self.onEdited?()
            })
        }
        return .init(.slider(row))
    }

    /// The Clip / Program switch: 9px segments in a hairline pill (`panelInput`), the chosen one on an accent wash in
    /// text-0, the other text-4 (hover text-2). Its hits are added after the header's, so they win there.
    func drawScopeSourceSwitch(_ c: CanvasContext, maxX: Double, midY: Double, _ panel: InspectorPanel) {
        let font = PanelTheme.font(9), sources = ColorScopes.Source.allCases
        let widths = sources.map { c.measureText($0.label, font: font).width + 12 }
        let pill = CanvasRect(x: maxX - widths.reduce(0, +) - 2, y: midY - 9, width: widths.reduce(0, +) + 2, height: 18)
        c.fillRoundedRect(pill, radius: PanelTheme.radiusMd, PanelTheme.panelInput)
        c.strokeRoundedRect(pill.insetBy(0.5), radius: PanelTheme.radiusMd - 0.5, PanelTheme.panelBorderInput, width: 1)
        var x = pill.x + 1
        for (i, source) in sources.enumerated() {
            let seg = CanvasRect(x: x, y: pill.y + 1, width: widths[i], height: 16)
            let hit = InspectorPanel.Hit.custom("grade:scopes", Self.scopeSourcePart + i)
            let on = scopeSource == source
            if on { c.fillRoundedRect(seg, radius: PanelTheme.radiusMd - 1, PanelTheme.accent.withAlpha(0.18)) }
            PanelDraw.text(c, source.label, in: CanvasRect(x: seg.x, y: seg.midY - 6.75, width: seg.width, height: 13.5), font: font,
                           color: on ? PanelTheme.text0 : (panel.hovered == hit ? PanelTheme.text2 : PanelTheme.text4), align: .center)
            panel.addHit(seg, hit)
            x = seg.maxX
        }
    }

    /// "Retry look previews": 10px medium accent on the block's 18px line.
    func retryPreviewsRow() -> InspectorCustomRow {
        InspectorCustomRow(id: "grade:retry", height: 18, draw: { c, r, panel in
            let label = "Retry look previews"
            let w = c.measureText(label, font: PanelTheme.font(10, .medium)).width
            let b = CanvasRect(x: r.x, y: r.y, width: w, height: 15)
            PanelDraw.text(c, label, in: CanvasRect(x: b.x, y: b.y, width: w + 1, height: 15), font: PanelTheme.font(10, .medium),
                           color: panel.hovered == .custom("grade:retry", 0) ? PanelTheme.accent.withAlpha(0.8) : PanelTheme.accent)
            panel.addHit(b, .custom("grade:retry", 0))
        }, pointer: { [weak self] _, _, phase in if phase == 0 { self?.onRetryPresetPreviews?(); self?.onEdited?() } })
    }

    // MARK: Presets

    /// FLAT_PREVIEW_GRID (`repeat(auto-fill,minmax(120px,1fr)) gap-1`): bordered tiles, a 16:9 `bg-black/20`
    /// preview over the label (`px-2 py-1.5 text-[10px]`). The selected tile: `border-panel-accent
    /// bg-panel-accent/10 text-panel-text-0`; the rest hairline-bordered, text-3. The preview area shows the look
    /// frame, its "Rendering" caption, or a placeholder with the reason (`drawPreviewFrame`), never nothing.
    /// FLAT_PREVIEW_GRID height: ceil(count / columns) rows of (1 + 16:9 frame + 27 label + 1) tiles, `gap` apart.
    static func previewGridHeight(count: Int, width: Double, columns: Int = 3, gap: Double = 4) -> Double {
        guard count > 0 else { return 0 }
        let rows = (count + columns - 1) / columns
        let tileW = (width - gap * Double(columns - 1)) / Double(columns)
        let tileH = 2 + (tileW - 2) * 9 / 16 + 27
        return Double(rows) * tileH + Double(rows - 1) * gap
    }

    func presetGrid(_ presets: [ColorGrading.Preset], selected: String?,
                    preview: @escaping (_ presetId: String, _ pixelWidth: Int, _ pixelHeight: Int) -> PresetPreviewState = { _, _, _ in .unavailable },
                    onPick: @escaping (ColorGrading.Preset) -> Void) -> InspectorCustomRow {
        let cols = 3, gap = 4.0
        // The row's height follows the width the body will draw at (the panel is resizable): tiles are 16:9 frames
        // over a 27px label, so a wider panel makes taller tiles and the grid must reserve them all, including a
        // partial last row.
        let height = Self.previewGridHeight(count: presets.count, width: bodyContentWidth, columns: cols, gap: gap)
        return InspectorCustomRow(id: "grade:presets", height: height, draw: { c, r, panel in
            let w = (r.width - gap * Double(cols - 1)) / Double(cols)
            let h = 2 + (w - 2) * 9 / 16 + 27
            for (i, p) in presets.enumerated() {
                let tr = CanvasRect(x: r.x + Double(i % cols) * (w + gap), y: r.y + Double(i / cols) * (h + gap), width: w, height: h)
                let on = selected == p.id || (selected == nil && p.id == "neutral")
                let hov = panel.hovered == .custom("grade:presets", i)
                if on { c.fillRect(tr, PanelTheme.accent.withAlpha(0.1)) }
                let sw = CanvasRect(x: tr.x + 1, y: tr.y + 1, width: tr.width - 2, height: (tr.width - 2) * 9 / 16)
                // The look frame, `object-contain` in the 16:9 frame, at the tile's device pixels (capped).
                let px = Self.tilePixels(sw, scale: c.deviceScale)
                Self.drawPreviewFrame(c, sw, preview(p.id, px.width, px.height))
                PanelDraw.text(c, p.label, in: CanvasRect(x: tr.x + 9, y: sw.maxY + 6, width: tr.width - 18, height: 15), font: PanelTheme.font(10),
                               color: on ? PanelTheme.text0 : (hov ? PanelTheme.text1 : PanelTheme.text3))
                c.strokeRect(tr.insetBy(0.5), on ? PanelTheme.accent : (hov ? PanelTheme.panelBorderInput : PanelTheme.panelHairline), width: 1)
                panel.addHit(tr, .custom("grade:presets", i))
            }
        }, pointer: { part, _, phase in if phase == 0, presets.indices.contains(part) { onPick(presets[part]) } })
    }

    /// Largest rect of the image's aspect inside `box`, centred.
    static func containRect(_ w: Int, _ h: Int, in box: CanvasRect) -> CanvasRect {
        guard w > 0, h > 0, box.width > 0, box.height > 0 else { return box }
        let s = min(box.width / Double(w), box.height / Double(h))
        return CanvasRect(x: box.x + (box.width - Double(w) * s) / 2, y: box.y + (box.height - Double(h) * s) / 2,
                          width: Double(w) * s, height: Double(h) * s)
    }


    // MARK: Secondary color

    func secondaryRows(_ g: ColorGrading, commit: @escaping (ColorGrading) -> Void) -> [InspectorRow] {
        var rows: [InspectorRow] = []
        let canAdd = g.secondaries.count < ColorGrading.maxSecondaries
        let add: () -> Void = { [weak self] in
            var n = g; n.secondaries.append(.init()); self?.grade.selectedSecondary = n.secondaries.count - 1; commit(n)
        }
        let remove: () -> Void = { [weak self] in
            guard let self, g.secondaries.indices.contains(self.grade.selectedSecondary) else { return }
            var n = g; n.secondaries.remove(at: self.grade.selectedSecondary); self.grade.selectedSecondary = max(0, self.grade.selectedSecondary - 1); commit(n)
        }
        rows.append(.init(.section("Secondary color")))
        rows.append(.init(.spacer(6)))
        // Selection chips (`h-6 min-w-6 border-b-2 px-1 font-mono text-[10px]`) left, 12px + and trash right (`gap-2`).
        let selIndex = min(grade.selectedSecondary, max(0, g.secondaries.count - 1))
        rows.append(.init(.custom(InspectorCustomRow(id: "sec:head", height: g.secondaries.isEmpty ? 12 : 24, draw: { c, r, panel in
            var x = r.x
            for i in g.secondaries.indices {
                let label = "\(i + 1)"
                let w = max(24, c.measureText(label, font: PanelTheme.mono(10)).width + 8)
                let cr = CanvasRect(x: x, y: r.y, width: w, height: 24)
                let on = i == selIndex
                PanelDraw.text(c, label, in: CanvasRect(x: cr.x, y: cr.y + 4.5, width: w, height: 15), font: PanelTheme.mono(10),
                               color: on ? PanelTheme.text0 : PanelTheme.text4, align: .center)
                if on { c.fillRect(CanvasRect(x: cr.x, y: cr.maxY - 2, width: w, height: 2), PanelTheme.accent) }
                panel.addHit(cr, .custom("sec:head", 10 + i))
                x = cr.maxX + 4
            }
            let canRemove = !g.secondaries.isEmpty
            let trash = CanvasRect(x: r.maxX - 12, y: r.midY - 6, width: 12, height: 12)
            let plus = CanvasRect(x: trash.x - 8 - 12, y: trash.y, width: 12, height: 12)
            let off = PanelTheme.text3.over(PanelTheme.panelBgInset, opacity: 0.35)
            PanelIcon.phosphor(.plus).draw(c, in: plus, color: !canAdd ? off : (panel.hovered == .custom("sec:head", 0) ? PanelTheme.text1 : PanelTheme.text3))
            PanelIcon.trash.draw(c, in: trash, color: !canRemove ? off : (panel.hovered == .custom("sec:head", 1) ? PanelTheme.text1 : PanelTheme.text3))
            if canAdd { panel.addHit(plus.insetBy(-3), .custom("sec:head", 0)) }
            if canRemove { panel.addHit(trash.insetBy(-3), .custom("sec:head", 1)) }
        }, pointer: { [weak self] part, _, phase in
            guard phase == 0 else { return }
            if part == 0 { add() } else if part == 1 { remove() } else { self?.grade.selectedSecondary = part - 10; self?.onEdited?() }
        }))))
        if g.secondaries.isEmpty {
            rows.append(.init(.spacer(6)))
            // `w-full border border-dashed border-panel-border-input px-2 py-2 text-[10px] text-panel-text-4`.
            rows.append(.init(.custom(InspectorCustomRow(id: "sec:placeholder", height: 33, draw: { c, r, panel in
                let hov = panel.hovered == .custom("sec:placeholder", 0)
                c.stroke(.rect(r.insetBy(0.5)), hov ? PanelTheme.accent.withAlpha(0.5) : PanelTheme.panelBorderInput, StrokeStyle(width: 1, dash: [3, 3]))
                PanelDraw.text(c, "Add a color selection", in: CanvasRect(x: r.x, y: r.y + 9, width: r.width, height: 15), font: PanelTheme.font(10),
                               color: hov ? PanelTheme.text2 : PanelTheme.text4, align: .center)
                panel.addHit(r, .custom("sec:placeholder", 0))
            }, pointer: { _, _, phase in if phase == 0 { add() } }))))
            return rows
        }
        let headCount = rows.count
        let sel = min(grade.selectedSecondary, g.secondaries.count - 1)
        let s = g.secondaries[sel]
        func set(_ edit: @escaping (inout ColorGrading.Secondary, Double) -> Void) -> (Double) -> Void {
            { v in var n = g; edit(&n.secondaries[sel], v); commit(n) }
        }
        rows.append(.init(.toggle(.init(key: "sec:enabled", label: "Selection enabled", on: s.enabled, set: { v in var n = g; n.secondaries[sel].enabled = v; commit(n) }))))
        rows += eyedropperRows(g, sel: sel, commit: commit)
        rows.append(.init(.custom(InspectorCustomRow(id: "sec:swatch", height: 14, draw: { c, r, _ in
            let (rr, gg, bb) = HueWheelImage.hsv(s.hueCenter, 0.8, 0.9)
            c.fillRoundedRect(CanvasRect(x: r.x, y: r.y + 2, width: r.width, height: 10), radius: 3, CanvasColor(r: rr, g: gg, b: bb))
        }))))
        func slider(_ key: String, _ label: String, _ v: Double, _ lo: Double, _ hi: Double, _ fmt: @escaping (Double) -> String, def: Double, center: Bool,
                    _ apply: @escaping (inout ColorGrading.Secondary, Double) -> Void) -> InspectorRow {
            .init(.slider(.init(key: key, label: label, position: v, min: lo, max: hi, display: fmt(v), format: fmt,
                                tier: abs(v - def) > 1e-6 ? .explicitCustom : .default, centerTick: center, commit: set(apply),
                                reset: { var n = g; apply(&n.secondaries[sel], def); commit(n) })))
        }
        let deg: (Double) -> String = { "\(Int($0.rounded()))°" }, pct: (Double) -> String = { "\(Int($0.rounded()))%" }
        rows.append(.init(.heading("Qualifier", trailing: nil)))
        rows.append(slider("sec:hue", "Hue", s.hueCenter, 0, 359, deg, def: 0, center: false) { $0.hueCenter = $1 })
        rows.append(slider("sec:range", "Hue range", s.hueRange, 0, 180, deg, def: 30, center: false) { $0.hueRange = min($1, 180 - $0.hueSoftness) })
        rows.append(slider("sec:soft", "Hue softness", s.hueSoftness, 0, 180, deg, def: 20, center: false) { $0.hueSoftness = min($1, 180 - $0.hueRange) })
        rows.append(.init(.heading("Correction", trailing: nil)))
        rows.append(slider("sec:shift", "Hue shift", s.hueShift, -180, 180, deg, def: 0, center: true) { $0.hueShift = $1.rounded() })
        rows.append(slider("sec:sat", "Saturation", s.saturation * 100, -100, 100, pct, def: 0, center: true) { $0.saturation = ($1 / 100 * 100).rounded() / 100 })
        rows.append(slider("sec:luma", "Luma", s.luma * 100, -100, 100, pct, def: 0, center: true) { $0.luma = ($1 / 100 * 100).rounded() / 100 })
        rows.append(slider("sec:temp", "Warmth", s.temperature * 100, -100, 100, pct, def: 0, center: true) { $0.temperature = ($1 / 100 * 100).rounded() / 100 })
        rows.append(slider("sec:tint", "Tint", s.tint * 100, -100, 100, pct, def: 0, center: true) { $0.tint = ($1 / 100 * 100).rounded() / 100 })
        // The selection's controls sit `space-y-1.5` under the header.
        let tail = rows[headCount...].flatMap { [InspectorRow(.spacer(6)), $0] }
        return Array(rows[..<headCount]) + tail
    }

    // MARK: Custom LUT

    func lutRows(_ g: ColorGrading, commit: @escaping (ColorGrading) -> Void) -> [InspectorRow] {
        // `border-t border-panel-hairline pt-1.5` over a `min-h-[30px]` button: 11px text-2 label, the 10px caret
        // `M2 3l3 4 3-4z` in text-5 (turned 90° when open).
        var rows: [InspectorRow] = [.init(.custom(InspectorCustomRow(id: "lut:toggle", height: 37, draw: { [weak self] c, r, panel in
            c.fillRect(CanvasRect(x: r.x, y: r.y, width: r.width, height: 1).snapped, PanelTheme.panelHairline)
            let row = CanvasRect(x: r.x, y: r.y + 7, width: r.width, height: 30)
            PanelDraw.text(c, "Custom LUT", in: CanvasRect(x: row.x, y: row.midY - 8.25, width: row.width - 16, height: 16.5), font: PanelTheme.font(11), color: PanelTheme.text2)
            let caret = CanvasRect(x: row.maxX - 10, y: row.midY - 5, width: 10, height: 10)
            c.withState {
                if self?.grade.lutOpen == true { c.translate(caret.midX, caret.midY); c.rotate(.pi / 2); c.translate(-caret.midX, -caret.midY) }
                c.fillSVG(["M2 3l3 4 3-4z"], viewBox: 10, in: caret, PanelTheme.text5)
            }
            panel.addHit(row, .custom("lut:toggle", 0))
        }, pointer: { [weak self] _, _, phase in if phase == 0 { self?.grade.lutOpen.toggle() } })))]
        guard grade.lutOpen else { return rows }
        let assets = lutAssets()
        let options = [""] + assets
        let cur = g.lut?.src ?? ""
        rows.append(.init(.segmented(.init(key: "lut:pick", label: g.lut.map { ($0.src as NSString).lastPathComponent } ?? "None",
                                           options: [(key: "prev", label: "‹", active: false), (key: "next", label: "›", active: false), (key: "import", label: "+", active: false)],
                                           select: { [weak self] k in
            if k == "import" { self?.onImportLut?(); return }
            guard let i = options.firstIndex(of: cur) ?? Optional(0) else { return }
            let j = (i + (k == "next" ? 1 : options.count - 1)) % options.count
            var n = g; n.lut = options[j].isEmpty ? nil : ColorGrading.Lut(src: options[j], intensity: g.lut?.intensity ?? 1); commit(n)
        }))))
        if let lut = g.lut {
            rows.append(.init(.slider(.init(key: "lut:strength", label: "LUT strength", position: lut.intensity * 100, min: 0, max: 100,
                                            display: "\(Int((lut.intensity * 100).rounded()))%", format: { "\(Int($0.rounded()))%" },
                                            tier: lut.intensity == 1 ? .default : .explicitCustom,
                                            commit: { v in var n = g; n.lut?.intensity = v / 100; commit(n) },
                                            reset: { var n = g; n.lut?.intensity = 1; commit(n) }))))
        }
        if assets.isEmpty { rows.append(.init(.note("Import a .cube file with + to use it as a LUT."))) }
        return rows
    }
}

/// The wheel surface, rendered once at 4× of the 112px wheel: `conic-gradient(from 90deg, #f33, #f3f, #33f, #3ff,
/// #3f3, #ff3, #f33)` under `radial-gradient(circle, rgb(128 128 128) 0%, transparent 72%)`, the radial sized to the
/// padding box's farthest corner (72% of 55·√2 ≈ 56px). Drawn clipped to the wheel's circle.
enum HueWheelImage {
    static let pixels = 448
    nonisolated(unsafe) private static var cached: CanvasImage?
    static func image() -> CanvasImage {
        if let cached { return cached }
        let n = pixels, scale = Double(n) / 112
        let stops: [(Double, Double, Double)] = [(1, 0.2, 0.2), (1, 0.2, 1), (0.2, 0.2, 1), (0.2, 1, 1), (0.2, 1, 0.2), (1, 1, 0.2), (1, 0.2, 0.2)]
        var px = [UInt8](repeating: 255, count: n * n * 4)
        let c = Double(n) / 2, fade = 0.72 * 55 * 2.0.squareRoot() * scale
        for y in 0..<n {
            for x in 0..<n {
                let dx = Double(x) + 0.5 - c, dy = Double(y) + 0.5 - c
                var theta = atan2(dx, -dy) * 180 / .pi - 90   // clockwise from the top, starting at 90°
                theta = (theta.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
                let t = theta / 60, k = min(5, Int(t)), f = t - Double(k)
                let a = stops[k], b = stops[k + 1]
                var r = a.0 + (b.0 - a.0) * f, g = a.1 + (b.1 - a.1) * f, bl = a.2 + (b.2 - a.2) * f
                let alpha = max(0, 1 - hypot(dx, dy) / fade), grey = 128.0 / 255
                r = grey * alpha + r * (1 - alpha); g = grey * alpha + g * (1 - alpha); bl = grey * alpha + bl * (1 - alpha)
                let i = (y * n + x) * 4
                px[i] = UInt8((r * 255).rounded()); px[i + 1] = UInt8((g * 255).rounded()); px[i + 2] = UInt8((bl * 255).rounded())
            }
        }
        let img = CanvasImage(width: n, height: n, rgba: px)
        cached = img
        return img
    }

    static func hsv(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let hh = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let i = Int(hh), f = hh - Double(i)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i { case 0: return (v, t, p); case 1: return (q, v, p); case 2: return (p, v, t); case 3: return (p, q, v); case 4: return (t, p, v); default: return (v, p, q) }
    }
}
