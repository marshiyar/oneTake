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
    typealias CurveTab = (key: String, label: String, color: ThemePair, hue: Bool, min: Double, max: Double)
    var isGradePasteEnabled: Bool {
        guard onPasteGrade != nil, gradeClipboardAvailable, let editor else { return false }
        let kinds = Dictionary(editor.document.assets.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        return selection.contains { id in
            guard let clip = editor.clip(id)?.clip else { return false }
            return kinds[clip.assetId] == .video || kinds[clip.assetId] == .image
        }
    }

    /// Curve tabs; `color` is the tab's line/point token (ThemeTokens.curve*Pair), so light mode draws dark ink.
    static let curveTabs: [CurveTab] = [
        ("master", "Master", ThemeTokens.curveMasterPair, false, 0, 1), ("red", "R", ThemeTokens.curveRedPair, false, 0, 1),
        ("green", "G", ThemeTokens.curveGreenPair, false, 0, 1), ("blue", "B", ThemeTokens.curveBluePair, false, 0, 1),
        ("hueVsHue", "Hue/Hue", ThemeTokens.curveHueHuePair, true, -180, 180),
        ("hueVsSaturation", "Hue/Sat", ThemeTokens.curveHueSatPair, true, -1, 1),
        ("hueVsLuma", "Hue/Luma", ThemeTokens.curveHueLumaPair, true, -1, 1),
    ]

    func gradeGroup(_ editor: TimelineEditor, _ s: Selected) -> InspectorGroup {
        let g = editor.colorGrading(clipId: s.id) ?? ColorGrading()
        let commit: (ColorGrading) -> Void = { [weak self] next in self?.edited(editor.setColorGrading(clipId: s.id, next)) }
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
                                        reset: { var n = g; n.intensity = 1; commit(n) }))))
        gap(6)
        rows.append(.init(.section("Primary")))
        gap(4)
        for (i, a) in ColorGrading.adjustSliders.enumerated() {
            if i > 0 { gap(2) }
            let v = g.adjustValue(a.key) * a.scale
            let fmt: (Double) -> String = { x in a.key == "exposure" ? String(format: "%+.2f", x / 100) : "\(Int(x.rounded()))\(a.suffix)" }
            rows.append(.init(.slider(.init(key: "grade:adj:\(a.key)", label: a.label, position: v, min: a.min, max: a.max, display: fmt(v), format: fmt,
                                            tier: abs(v) > 1e-6 ? .explicitCustom : .default, centerTick: true,
                                            commit: { x in var n = g; n.adjust[a.key] = (x / a.scale * 1000).rounded() / 1000; commit(n) },
                                            reset: { var n = g; n.adjust[a.key] = 0; commit(n) }))))   // 0, not nil: a missing key reads the preset's value
            if a.key == "contrast" { gap(2); rows.append(pivotSlider(g, commit: commit)) }
        }
        gap(6)
        rows.append(.init(.section("Color wheels")))
        gap(6)
        rows.append(.init(.custom(colorWheels(g, .balance, commit: commit)), controls: wheelFieldControls(g, .balance, commit: commit)))
        if g.showsTonalWheels {   // a contract 2 grade's Shadows / Midtones / Highlights stay editable
            gap(12)
            rows.append(.init(.heading("Tonal wheels", trailing: nil)))
            rows.append(.init(.custom(colorWheels(g, .tonal, commit: commit)), controls: wheelFieldControls(g, .tonal, commit: commit)))
        }
        gap(6)
        rows.append(.init(.section("Curves")))
        gap(6)
        rows.append(.init(.custom(curveTabsRow())))
        gap(8)
        rows.append(.init(.custom(curveGraph(g, commit: commit))))
        gap(8)
        rows.append(.init(.custom(curveFooter(g, commit: commit))))
        gap(6)
        rows.append(contentsOf: secondaryRows(g, commit: commit))
        gap(6)
        rows.append(contentsOf: lutRows(g, commit: commit))
        gap(6)
        rows.append(.init(.section("Finish")))
        gap(6)
        for (i, key) in ["vignette", "grain"].enumerated() {
            if i > 0 { gap(6) }
            rows.append(detailSlider(g, key, commit: commit, gear: true))
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

    func detailSlider(_ g: ColorGrading, _ key: String, commit: @escaping (ColorGrading) -> Void, gear: Bool) -> InspectorRow {
        let spec = ColorGrading.detailSliders.first { $0.key == key }!
        let v = g.detail(key) * 100, def = (ColorGrading.detailDefaults[key] ?? 0) * 100
        var row = InspectorRow.Slider(key: "grade:det:\(key)", label: spec.label, position: v, min: spec.min, max: spec.max,
                                      display: "\(Int(v.rounded()))%", format: { "\(Int($0.rounded()))%" },
                                      tier: abs(v - def) > 1e-6 ? .explicitCustom : .default,
                                      commit: { x in var n = g; n.details[key] = (x / 100 * 1000).rounded() / 1000; commit(n) },
                                      reset: { var n = g; n.details[key] = ColorGrading.defaultDetail(key); commit(n) })   // explicit, as above
        if gear {   // Vignette settings / Grain settings
            row.settings = (grade.finishSettings == key, { [weak self] in
                guard let self else { return }
                self.grade.finishSettings = self.grade.finishSettings == key ? nil : key; self.onEdited?()
            })
        }
        return .init(.slider(row))
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

    // MARK: Curves (the curve modes and the curve graph)

    /// The curve tabs on the shared inline tab bar (`PanelTabBar`): a 32 pt line over a hairline, overflow behind a
    /// chevron when the panel is narrow, one Tab stop with arrow keys.
    func curveTabsRow() -> InspectorCustomRow {
        let tabs = Self.curveTabs.map { PanelTab(id: $0.key, label: $0.label) }
        let pick: (Int) -> Void = { [weak self] i in
            guard let self, Self.curveTabs.indices.contains(i) else { return }
            self.grade.curveTab = Self.curveTabs[i].key; self.grade.selectedPoint = nil; self.onEdited?()
        }
        return InspectorCustomRow(id: "grade:curvetabs", height: PanelGrid.rowHeight, draw: { [weak self] c, r, _ in
            guard let self else { return }
            self.drawInlineTabs(c, PanelTabBar(tabs: tabs, selected: self.grade.curveTab, style: .inline), row: ("grade:curvetabs", base: 0), in: r)
        }, pointer: { [weak self] part, _, phase in
            guard let self, phase == 0, let i = self.inlineTab("grade:curvetabs", part: part, select: pick) else { return }
            pick(i)
        })
    }

    /// The open curve tab; a key that names no tab (the field is public) reads as Master.
    var openCurveTab: CurveTab { Self.curveTabs.first { $0.key == grade.curveTab } ?? Self.curveTabs[0] }
    /// The point rules of the open tab.
    var curveEditing: CurveEditing { let t = openCurveTab; return CurveEditing(hue: t.hue, limit: t.min...t.max) }
    /// A curve point's pointer target: a circle of this radius, so 24 pt across.
    static let curvePointHitRadius = 12.0
    /// The smallest pointer target of a curve control, in points.
    static let curveMinTarget = 24.0

    /// The open tab's points as they render (`CurveEditing.displayed`), or the live points while one is dragged.
    func currentCurvePoints(_ g: ColorGrading) -> [[Double]] {
        if let d = grade.curveDraft { return d }
        let tab = openCurveTab
        return curveEditing.displayed(tab.hue ? g.hueCurve(tab.key) : g.curve(tab.key))
    }

    func writeCurve(_ g: ColorGrading, _ pts: [[Double]]) -> ColorGrading {
        var n = g
        let tab = openCurveTab, stored = curveEditing.stored(pts)
        if tab.hue { n.hueCurves[tab.key] = stored } else { n.curves[tab.key] = stored }
        return n
    }

    /// A point of the open tab in view coordinates; a stored point outside the range sits on the edge.
    func curveToView(_ pt: [Double]) -> CanvasPoint {
        let tab = openCurveTab, box = grade.curveBox
        let nx = tab.hue ? pt[0] / 360 : pt[0], ny = (pt[1] - tab.min) / (tab.max - tab.min)
        return CanvasPoint(box.x + max(0, min(1, nx)) * box.width, box.maxY - max(0, min(1, ny)) * box.height)
    }

    /// The open tab's (input, output) under a view point, clamped to the graph, at 1/1000.
    func curveFromView(_ p: CanvasPoint) -> [Double] {
        let tab = openCurveTab, box = grade.curveBox
        let nx = max(0, min(1, (p.x - box.x) / box.width)), ny = max(0, min(1, (box.maxY - p.y) / box.height))
        let x = tab.hue ? min(359.9, nx * 360) : nx
        return [(x * 1000).rounded() / 1000, ((tab.min + ny * (tab.max - tab.min)) * 1000).rounded() / 1000]
    }

    func curveGraph(_ g: ColorGrading, commit: @escaping (ColorGrading) -> Void) -> InspectorCustomRow {
        InspectorCustomRow(id: "grade:curve", height: 200, draw: { [weak self] c, r, panel in
            self?.drawCurveGraph(c, r, panel, g)
        }, pointer: { [weak self] _, p, phase in
            guard let self else { return }
            switch phase {
            case 0: self.curvePress(g, p)
            case 1: self.curveDrag(p)
            default: self.curveRelease(g, commit: commit)
            }
        }, key: { [weak self] _, k in self?.curveKey(g, k, commit: commit) ?? false })
    }

    /// Keys on the focused curve graph (issue #171): Left / Right select the previous / next point, Up / Down move
    /// the selected point's output and Alt+Left / Alt+Right its input, by 1% of the axis (Shift: 10%); Enter adds a
    /// point (`addCurvePoint`), Delete / Backspace removes the selected one, Space does nothing (a replayed press
    /// would add a point at the graph's centre). A held arrow folds into one undo step.
    func curveKey(_ g: ColorGrading, _ k: EditorKey, commit: @escaping (ColorGrading) -> Void) -> Bool {
        let step = k.shift ? 0.1 : 0.01
        switch k.code {
        case .space: return true
        case .enter: addCurvePoint(g, commit: commit); return true
        case .delete, .backspace: deleteSelectedCurvePoint(g, commit: commit); return true
        case .left, .right:
            let d = k.code == .left ? -1.0 : 1.0
            if k.alt { nudgeCurvePoint(g, dx: d * step, dy: 0, commit: commit) } else { selectNextCurvePoint(g, by: Int(d)) }
            return true
        case .up, .down: nudgeCurvePoint(g, dx: 0, dy: (k.code == .up ? 1 : -1) * step, commit: commit); return true
        default: return false
        }
    }

    /// Selects the point `by` places from the selected one (from the first or last when none is selected).
    func selectNextCurvePoint(_ g: ColorGrading, by: Int) {
        let n = currentCurvePoints(g).count
        guard n > 0 else { return }
        let i = grade.selectedPoint.map { $0 + by } ?? (by > 0 ? 0 : n - 1)
        grade.selectedPoint = min(n - 1, max(0, i))
    }

    /// Moves the selected point by fractions of the tab's axes, through `CurveEditing.moving`.
    func nudgeCurvePoint(_ g: ColorGrading, dx: Double, dy: Double, commit: @escaping (ColorGrading) -> Void) {
        let tab = openCurveTab, pts = currentCurvePoints(g)
        guard let i = grade.selectedPoint, pts.indices.contains(i), let editor else { return }
        let span = tab.hue ? 360.0 : 1.0
        let moved = curveEditing.moving(i, to: [pts[i][0] + dx * span, pts[i][1] + dy * (tab.max - tab.min)], in: pts)
        guard moved != pts else { return }
        editor.withHistory("Edit color grade", coalesceKey: "grade:curve:nudge:\(tab.key):\(i)") { commit(writeCurve(g, moved)) }
    }

    /// CurveGraph: `max-w-[200px] rounded border border-panel-border-input bg-black/20`, view box 160 with the plot
    /// area at 8…152. The line is the curve the grade applies (ColorCurveMath = the renderer's GradeCurve):
    /// normalized, monotone and inside the range. Line and points are clipped to the graph.
    func drawCurveGraph(_ c: CanvasContext, _ r: CanvasRect, _ panel: InspectorPanel, _ g: ColorGrading) {
        let tab = openCurveTab
        let size = min(r.width, 200)
        let frame = CanvasRect(x: r.x + (r.width - size) / 2, y: r.y, width: size, height: size)
        let u = (size - 2) / 160
        grade.curveBox = CanvasRect(x: frame.x + 1 + 8 * u, y: frame.y + 1 + 8 * u, width: 144 * u, height: 144 * u)
        c.fillRoundedRect(frame, radius: 4, PanelTheme.stageScrim.withAlpha(Theme.mode == .light ? 0.05 : 0.2))
        c.strokeRoundedRect(frame.insetBy(0.5), radius: 3.5, PanelTheme.panelBorderInput, width: 1)
        Self.drawCurveGrid(c, frame: frame, u: u)
        if tab.hue { Self.drawHueAxis(c, frame: frame, u: u) }
        let pts = currentCurvePoints(g)
        let color = CanvasColor(tab.color.now)
        c.save()
        c.clip(.roundedRect(frame.insetBy(1), radius: 3))
        var path = CanvasPath()
        for (k, s) in ColorCurveMath.samples(pts, hue: tab.hue, limit: tab.min...tab.max, count: 144).enumerated() {
            let vp = curveToView([s.x, s.y])
            if k == 0 { path.move(to: vp) } else { path.line(to: vp) }
        }
        c.stroke(path, color, StrokeStyle(width: 1.5 * u))
        for (i, pt) in pts.enumerated() {   // r 2.5 (selected 3.5 white), #111 1-unit outline
            let vp = curveToView(pt)
            let sel = grade.selectedPoint == i
            let rad = (sel ? 3.5 : 2.5) * u
            let dot = CanvasPath.roundedRect(CanvasRect(x: vp.x - rad, y: vp.y - rad, width: 2 * rad, height: 2 * rad), radius: rad)
            c.fill(dot, sel ? PanelTheme.white : color)
            c.stroke(dot, CanvasColor(ThemeTokens.curvePointOutlinePair.now), StrokeStyle(width: u))
        }
        c.restore()
        // The target reaches a point's full hit radius past the plot area, so the end points are as easy to grab.
        panel.addHit(grade.curveBox.insetBy(-Self.curvePointHitRadius), .custom("grade:curve", 0))
    }

    /// Quarter lines (rgba(255,255,255,.08), 0.5 wide) over the plot area of a graph `frame` at `u` per view unit.
    static func drawCurveGrid(_ c: CanvasContext, frame: CanvasRect, u: Double) {
        func v(_ x: Double, _ y: Double) -> CanvasPoint { CanvasPoint(frame.x + 1 + x * u, frame.y + 1 + y * u) }
        for ratio in [0.25, 0.5, 0.75] {
            var h = CanvasPath(); h.move(to: v(8, 8 + ratio * 144)); h.line(to: v(152, 8 + ratio * 144))
            var w = CanvasPath(); w.move(to: v(8 + ratio * 144, 8)); w.line(to: v(8 + ratio * 144, 152))
            c.stroke(h, PanelTheme.white.withAlpha(0.08), StrokeStyle(width: 0.5 * u))
            c.stroke(w, PanelTheme.white.withAlpha(0.08), StrokeStyle(width: 0.5 * u))
        }
    }

    /// The hue axis: a 3-unit line at y 157 through #f33 #ff3 #3f3 #3ff #33f #f3f #f33.
    static func drawHueAxis(_ c: CanvasContext, frame: CanvasRect, u: Double) {
        func v(_ x: Double, _ y: Double) -> CanvasPoint { CanvasPoint(frame.x + 1 + x * u, frame.y + 1 + y * u) }
        let stops: [(Double, Double, Double)] = [(1, 0.2, 0.2), (1, 1, 0.2), (0.2, 1, 0.2), (0.2, 1, 1), (0.2, 0.2, 1), (1, 0.2, 1), (1, 0.2, 0.2)]
        let n = 72
        for k in 0..<n {
            let t = (Double(k) + 0.5) / Double(n) * 6, i = min(5, Int(t)), f = t - Double(i)
            let a = stops[i], b = stops[i + 1]
            let x0 = v(8 + 144 * Double(k) / Double(n), 155.5), x1 = v(8 + 144 * Double(k + 1) / Double(n), 158.5)
            c.fillRect(CanvasRect(x: x0.x, y: x0.y, width: x1.x - x0.x + 0.3, height: x1.y - x0.y),
                       CanvasColor(r: a.0 + (b.0 - a.0) * f, g: a.1 + (b.1 - a.1) * f, b: a.2 + (b.2 - a.2) * f))
        }
    }

    /// The nearest point within `curvePointHitRadius` of `p`, if any.
    func nearestCurvePoint(_ pts: [[Double]], to p: CanvasPoint) -> Int? {
        let d = pts.map { pt -> Double in let v = curveToView(pt); return hypot(v.x - p.x, v.y - p.y) }
        guard let i = d.indices.min(by: { d[$0] < d[$1] }), d[i] <= Self.curvePointHitRadius else { return nil }
        return i
    }

    /// A press selects the point under it, or adds one there (where the curve has room for it).
    func curvePress(_ g: ColorGrading, _ p: CanvasPoint) {
        grade.curveDraft = nil
        let pts = currentCurvePoints(g)
        if let i = nearestCurvePoint(pts, to: p) {
            let v = curveToView(pts[i])
            grade.selectedPoint = i; grade.curveDraft = pts
            grade.curveGrab = (v.x - p.x, v.y - p.y, p, false)
        } else if let added = curveEditing.inserting(curveFromView(p), into: pts) {
            grade.selectedPoint = added.index; grade.curveDraft = added.points
            grade.curveGrab = (0, 0, p, true)
        } else {
            grade.selectedPoint = nil; grade.curveGrab = nil
        }
    }

    /// A drag moves the pressed point by the pointer's motion, once it is 3 pt from the press.
    func curveDrag(_ p: CanvasPoint) {
        guard var grab = grade.curveGrab, let i = grade.selectedPoint, let pts = grade.curveDraft else { return }
        if !grab.moved && hypot(p.x - grab.start.x, p.y - grab.start.y) < 3 { return }
        grab.moved = true
        grade.curveGrab = grab
        grade.curveDraft = curveEditing.moving(i, to: curveFromView(CanvasPoint(p.x + grab.dx, p.y + grab.dy)), in: pts)
    }

    /// The release commits the edited curve as one undo step; a press that changed nothing commits nothing.
    func curveRelease(_ g: ColorGrading, commit: (ColorGrading) -> Void) {
        let draft = grade.curveDraft
        grade.curveDraft = nil; grade.curveGrab = nil
        guard let draft, draft != currentCurvePoints(g) else { return }
        commit(writeCurve(g, draft))
    }

    /// The tab's curve at `x` as the grade applies it (an RGB curve, or a hue curve: flat below three points).
    static func curveValue(hue: Bool, limit: ClosedRange<Double>, _ pts: [[Double]], at x: Double) -> Double {
        CurveEditing(hue: hue, limit: limit).value(pts, at: x)
    }

    /// A dragged point keeps its place in the order: it stays at least 0.01 (RGB) / 1° (hue) inside its neighbours,
    /// so no two points share an input (which the renderer rejects, dropping the whole curve) and the selection
    /// index keeps naming the dragged point. (`CurveEditing.moving` adds the pinned RGB end points.)
    static func draggedCurvePoint(_ p: [Double], index i: Int, in pts: [[Double]], hue: Bool) -> [Double] {
        [CurveEditing(hue: hue, limit: 0...1).constrainedInput(i, p[0], in: pts), p[1]]
    }

    /// At least `curveMinTarget` square around `glyph`, kept inside `row`.
    static func curveTarget(_ glyph: CanvasRect, in row: CanvasRect) -> CanvasRect {
        let w = max(glyph.width + 6, curveMinTarget), h = max(glyph.height + 6, curveMinTarget)
        let x = min(max(glyph.midX - w / 2, row.x), row.maxX - w), y = min(max(glyph.midY - h / 2, row.y), row.maxY - h)
        return CanvasRect(x: x, y: y, width: w, height: h)
    }

    /// Footer (`flex min-h-7 items-end gap-2`): the hint (9px text-5) or, with a removable point selected, a
    /// `Delete` text button; the 11px reset at the right (`pb-0.5`).
    func curveFooter(_ g: ColorGrading, commit: @escaping (ColorGrading) -> Void) -> InspectorCustomRow {
        InspectorCustomRow(id: "grade:curvefoot", height: 28, draw: { [weak self] c, r, panel in
            self?.drawCurveFooter(c, r, panel, g)
        }, pointer: { [weak self] part, _, phase in
            guard let self, phase == 0 else { return }
            if part == 0 { self.grade.selectedPoint = nil; commit(self.writeCurve(g, self.openCurveTab.hue ? [] : GradeCurve.identity)) }
            else { self.deleteSelectedCurvePoint(g, commit: commit) }
        })
    }

    func drawCurveFooter(_ c: CanvasContext, _ r: CanvasRect, _ panel: InspectorPanel, _ g: ColorGrading) {
        let line = CanvasRect(x: r.x, y: r.maxY - 13.5, width: r.width - 19, height: 13.5)
        if let i = grade.selectedPoint, curveEditing.canRemove(i, in: currentCurvePoints(g)) {
            let w = c.measureText("Delete", font: PanelTheme.font(9)).width
            let del = CanvasRect(x: line.x, y: line.y - 2, width: w, height: 15.5)
            PanelDraw.text(c, "Delete", in: CanvasRect(x: del.x, y: line.y - 2, width: w, height: 13.5), font: PanelTheme.font(9),
                           color: panel.hovered == .custom("grade:curvefoot", 1) ? PanelTheme.text1 : PanelTheme.text4)
            panel.addHit(Self.curveTarget(del, in: r), .custom("grade:curvefoot", 1))
        } else {
            PanelDraw.text(c, "Click the graph or press Enter to add a point", in: line, font: PanelTheme.font(9), color: PanelTheme.text5)
        }
        let reset = CanvasRect(x: r.maxX - 11, y: r.maxY - 13, width: 11, height: 11)
        PanelIcon.reset.draw(c, in: reset, color: panel.hovered == .custom("grade:curvefoot", 0) ? PanelTheme.text1 : PanelTheme.text4)
        panel.addHit(Self.curveTarget(reset, in: r), .custom("grade:curvefoot", 0))
    }

    func deleteSelectedCurvePoint(_ g: ColorGrading, commit: (ColorGrading) -> Void) {
        guard let i = grade.selectedPoint, let pts = curveEditing.removing(i, from: currentCurvePoints(g)) else { return }
        grade.selectedPoint = nil
        commit(writeCurve(g, pts))
    }

    /// Enter: a point in the middle of the widest gap, on the curve, selected.
    func addCurvePoint(_ g: ColorGrading, commit: (ColorGrading) -> Void) {
        let edit = curveEditing, pts = currentCurvePoints(g)
        guard let added = edit.inserting(edit.insertionPoint(pts), into: pts) else { return }
        grade.selectedPoint = added.index
        commit(writeCurve(g, added.points))
    }

    /// Keys with no text field focused: Delete/Backspace removes the selected curve point; Enter adds a point.
    func gradeKey(_ k: EditorKey) -> Bool {
        guard openGroupId == "grade", let editor, let s = selected() else { return false }
        let g = editor.colorGrading(clipId: s.id) ?? ColorGrading()
        let commit: (ColorGrading) -> Void = { [weak self] n in self?.edited(editor.setColorGrading(clipId: s.id, n)) }
        switch k.code {
        case .delete, .backspace:
            guard grade.selectedPoint != nil else { return false }
            deleteSelectedCurvePoint(g, commit: commit); return true
        case .enter:
            addCurvePoint(g, commit: commit); return true
        default: return false
        }
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
