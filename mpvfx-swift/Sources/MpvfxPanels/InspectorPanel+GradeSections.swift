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

/// The Grade group's collapsible sections (issue #175): a header row per section that opens and closes it with the
/// mouse or Tab then Enter / Space, the state kept in `PanelPreferences.gradeSections`, and the Looks section whose
/// header names the active look.
extension InspectorPanel {
    /// The sections in order, with whether each starts open. Looks start closed so the grading controls are in view;
    /// Custom LUT keeps its own header and opens by default only while the clip has a LUT.
    static let gradeSectionSpecs: [(id: String, title: String, openByDefault: Bool)] = [
        ("looks", "Looks", false), ("primary", "Primary", true), ("wheels", "Color wheels", true), ("curves", "Curves", true),
        ("secondary", "Secondary color", true), ("finish", "Finish", true)
    ]
    static let lutSectionId = "lut"
    static let gradeSectionRowPrefix = "grade:section:"

    func gradeSectionIsOpen(_ id: String) -> Bool {
        gradeSectionOpen[id] ?? Self.gradeSectionSpecs.first { $0.id == id }?.openByDefault ?? true
    }

    func setGradeSection(_ id: String, open: Bool) {
        gradeSectionOpen[id] = open
        if id == Self.lutSectionId { grade.lutOpen = open }
    }

    /// Accessibility name of a section header's hit ("Collapse Primary" / "Expand Primary").
    func gradeSectionLabel(_ rowId: String) -> String? {
        guard rowId.hasPrefix(Self.gradeSectionRowPrefix) else { return nil }
        let id = String(rowId.dropFirst(Self.gradeSectionRowPrefix.count))
        guard let spec = Self.gradeSectionSpecs.first(where: { $0.id == id }) else { return nil }
        return (gradeSectionIsOpen(id) ? "Collapse " : "Expand ") + spec.title
    }

    /// A section header: hairline, the title in the section style, an optional right-aligned detail, and a caret turned
    /// down while the section is open. One hit over the whole row, so it is Tab-reachable and Enter / Space toggles it.
    func gradeSectionRow(_ id: String, detail: String? = nil) -> InspectorRow {
        let title = Self.gradeSectionSpecs.first { $0.id == id }?.title ?? id
        let open = gradeSectionIsOpen(id), rowId = Self.gradeSectionRowPrefix + id
        return .init(.custom(InspectorCustomRow(id: rowId, height: Self.gradeSectionHeight, draw: { c, r, panel in
            c.fillRect(CanvasRect(x: r.x, y: r.y, width: r.width, height: 1).snapped, PanelTheme.panelHairline)
            let hit = InspectorPanel.Hit.custom(rowId, 0)
            panel.targetHover(c, r, hit)
            let caret = CanvasRect(x: r.maxX - 10, y: r.midY - 5, width: 10, height: 10)
            c.withState {
                if open {
                    c.translate(caret.midX, caret.midY); c.rotate(.pi / 2); c.translate(-caret.midX, -caret.midY)
                }
                c.fillSVG(["M2 3l3 4 3-4z"], viewBox: 10, in: caret, PanelTheme.inspectorText)
            }
            var textRight = caret.x - 8
            if let detail {
                let font = PanelTheme.font(11), w = min(c.measureText(detail, font: font).width, r.width / 2)
                PanelDraw.text(c, detail, in: CanvasRect(x: textRight - w, y: r.midY - 7.5, width: w, height: 15), font: font,
                               color: PanelTheme.inspectorText, align: .right)
                textRight -= w + 8
            }
            PanelDraw.tracked(c, title.uppercased(), in: CanvasRect(x: r.x, y: r.y + 1, width: max(0, textRight - r.x), height: r.height - 1),
                              font: PanelTheme.font(PanelTheme.inspectorSectionSize, .semibold), tracking: 1.08,
                              color: hit == panel.hovered ? PanelTheme.text2 : PanelTheme.inspectorText)
            panel.addHit(r, hit)
        }, pointer: { [weak self] _, _, phase in
            if phase == 0 { self?.setGradeSection(id, open: !open) }
        })))
    }

    /// One header height for every section, a 24 pt target on the 8 pt grid.
    static let gradeSectionHeight = 32.0

    /// The look the grade still is: the preset the grade names (Neutral when it names none) whose application to the
    /// grade changes nothing. A later edit of the look's own values (Amount, a Primary slider, a Finish slider, an
    /// effect) makes it nil, shown as "Custom"; wheels, curves, secondaries and the LUT belong to the rest of the grade.
    static func activeLook(_ g: ColorGrading) -> ColorGrading.Preset? {
        guard let p = ColorGrading.preset(g.preset ?? "neutral") else { return nil }
        var named = g
        named.preset = p.id
        return named.applying(p) == named ? p : nil
    }

    /// A Looks tile as clicking it applies it: the host renders `base.applying(look)`, the clip's own grade with the look
    /// on top (the Effects catalog's look tiles do the same), on the clip's frame or else the sample picture. Without an
    /// Effects preview hook the host's preset-only previews stand in.
    func gradeLookPreview(_ p: ColorGrading.Preset, base g: ColorGrading, clipId: String, _ req: PresetPreviewRequest) -> PresetPreviewState {
        guard effectPreview != nil else { return lookPreview(req) }
        let own = samplePreview(Self.lookDemo(p, base: g, clipId: clipId), req.pixelWidth, req.pixelHeight)
        guard case .unavailable = own else { return own }
        return samplePreview(Self.lookDemo(p, base: g), req.pixelWidth, req.pixelHeight)
    }
}
