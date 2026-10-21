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

/// The Composition section: what the Design tab shows with nothing selected. A preset select (Landscape 16:9,
/// Portrait 9:16, Square 1:1, Vertical 4:5, 4K 16:9, Custom), the width and height fields, and the current size.
/// Every change is one undo step through TimelineEditor.setCanvasSize, saved in project.json like any edit.
extension InspectorPanel {
    static let compositionGroupId = "composition"
    static let compositionPresetRowId = "compositionPreset"

    /// Nothing selected and no audio bus open: the Design tab edits the composition.
    var showsComposition: Bool { editor != nil && selection.isEmpty && selectedBus() == nil }

    var compositionSize: (width: Double, height: Double) {
        (editor?.document.canvas.width ?? 0, editor?.document.canvas.height ?? 0)
    }

    /// The matching preset's value, "custom" when the size matches none.
    public var compositionPresetValue: String {
        NativeCompositionPreset.matching(width: compositionSize.width, height: compositionSize.height)?.rawValue ?? "custom"
    }

    /// The select's text: the matching preset with its size, or "Custom · W×H".
    public var compositionPresetLabel: String {
        let (w, h) = compositionSize
        if let p = NativeCompositionPreset.matching(width: w, height: h) { return Self.presetLabel(p) }
        return "Custom · \(Self.sizeText(w, h))"
    }

    /// The preset select's options, in the order the dropdown lists them.
    public func compositionPresetOptions() -> [PanelDropdown.Option] {
        NativeCompositionPreset.allCases.map { PanelDropdown.Option(value: $0.rawValue, label: Self.presetLabel($0)) }
            + [PanelDropdown.Option(value: "custom", label: "Custom")]
    }

    static func presetLabel(_ p: NativeCompositionPreset) -> String { "\(p.label) · \(sizeText(p.width, p.height))" }
    static func sizeText(_ w: Double, _ h: Double) -> String { "\(Int(w))×\(Int(h))" }

    func setCompositionSize(_ editor: TimelineEditor, width: Double, height: Double) {
        edited(editor.setCanvasSize(width: width, height: height), label: "Set composition size")
    }

    /// A typed side: whole pixels, "px" and thousands separators allowed; nil for anything else.
    static func compositionSide(_ text: String) -> Double? {
        let t = text.lowercased().replacingOccurrences(of: "px", with: "").replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let v = Double(t), jsIsInteger(v), v >= 1 else { return nil }
        return v
    }

    func compositionGroup(_ editor: TimelineEditor) -> InspectorGroup {
        let (w, h) = compositionSize
        func side(_ key: String, _ label: String, _ value: Double, apply: @escaping (Double) -> Void) -> InspectorRow.Number {
            InspectorRow.Number(key: key, label: label, text: "\(Int(value))", tier: .default,
                                commit: { v in if let n = Self.compositionSide(v) { apply(n) } })
        }
        let width = side("compositionWidth", "W", w) { [weak self] n in self?.setCompositionSize(editor, width: n, height: h) }
        let height = side("compositionHeight", "H", h) { [weak self] n in self?.setCompositionSize(editor, width: w, height: n) }
        let presets = NativeCompositionPreset.allCases.map { p in
            InspectorRow.Button(key: "\(Self.compositionPresetRowId).\(p.rawValue)", label: Self.presetLabel(p),
                                style: p.rawValue == compositionPresetValue ? .chipActive : .chip,
                                action: { [weak self] in self?.setCompositionSize(editor, width: p.width, height: p.height) })
        }
        let shape = w == h ? "square" : (h > w ? "portrait" : "landscape")
        let ratio = RightPanel.ratio(w, h)
        let rows: [InspectorRow] = [
            InspectorRow(.custom(compositionPresetRow(editor)), controls: [InspectorRow(.buttons(presets))]),
            InspectorRow(.pair(label: "Size", width, height)),
            InspectorRow(.note("\(Self.sizeText(w, h)) · \(ratio) \(shape). Clips with no size of their own refit; "
                               + "placed clips and text keep their size and distance from the centre.")),
        ]
        return InspectorGroup(id: Self.compositionGroupId, title: "Composition", summary: "\(Self.sizeText(w, h)) · \(ratio)", rows: rows, spacing: 8)
    }

    /// "Preset" and the select (PanelSelect, `h-7`), opening the right panel's dropdown with the current preset marked.
    func compositionPresetRow(_ editor: TimelineEditor) -> InspectorCustomRow {
        InspectorCustomRow(id: Self.compositionPresetRowId, height: 30, draw: { c, r, panel in
            PanelDraw.text(c, "Preset", in: CanvasRect(x: r.x, y: r.midY - 8.25, width: 86, height: 16.5),
                           font: PanelTheme.font(11), color: PanelTheme.text3)
            let field = CanvasRect(x: r.x + 96, y: r.midY - 14, width: max(0, r.width - 96), height: 28)
            PanelSelect.draw(c, field, text: panel.compositionPresetLabel, hovered: panel.hovered == .custom(Self.compositionPresetRowId, 0))
            panel.addHit(field, .custom(Self.compositionPresetRowId, 0))
            panel.compositionPresetField = field
        }, pointer: { [weak self] _, _, phase in
            guard phase == 0, let self, let anchor = self.compositionPresetField else { return }
            self.onOpenDropdown?("composition-preset", self.compositionPresetOptions(), self.compositionPresetValue, anchor) { [weak self] v in
                guard let self, let p = NativeCompositionPreset(rawValue: v) else { return }   // "Custom": type the size below
                self.setCompositionSize(editor, width: p.width, height: p.height)
            }
        })
    }

    /// The section's header (the bus header's look: icon, "Composition", the size in text-4), then its rows.
    func drawComposition(_ c: CanvasContext, _ r: CanvasRect, _ editor: TimelineEditor) {
        let h = Self.clipHeaderHeight - 1
        let row = CanvasRect(x: r.x + 16, y: r.y, width: r.width - 32, height: h)
        PanelIcon.phosphor(.square).draw(c, in: CanvasRect(x: row.x, y: row.y + (h - 14) / 2, width: 14, height: 14), color: PanelTheme.container)
        let nameX = row.x + 24
        let ns = PanelDraw.text(c, "Composition", in: CanvasRect(x: nameX, y: row.y, width: row.width * 0.6, height: h),
                                font: PanelTheme.font(13, .semibold), color: PanelTheme.text0)
        let (w, hh) = compositionSize
        PanelDraw.text(c, Self.sizeText(w, hh), in: CanvasRect(x: nameX + ns.width + 8, y: row.y + 1.5, width: max(0, row.maxX - nameX - ns.width - 8), height: h),
                       font: PanelTheme.font(10), color: PanelTheme.text4)
        PanelDraw.hline(c, x0: r.x, x1: r.maxX, y: r.y + h, PanelTheme.panelHairline)
        let g = laidOut(compositionGroup(editor), c, width: r.width)
        let bodyH = Self.openBodyHeight(g, 0)
        bodyRect = CanvasRect(x: r.x, y: r.y + h + 1, width: r.width, height: max(0, r.height - h - 1))
        bodyContentHeight = bodyH; bodyMaxScroll = 0
        drawGroupBody(c, CanvasRect(x: r.x, y: r.y + h + 1, width: r.width, height: bodyH), g)
        if let ring = focus.ringRect(hits) { PanelDraw.focusRing(c, ring) }
    }
}
