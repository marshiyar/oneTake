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
import MpvfxTimeline

/// A labelled select that opens the right panel's dropdown (the Fit row's look): the label in its value-tier colour, the
/// select showing the current choice, and, when `reset` is given and the tier is not the default, the reset glyph.
/// Each choice is also an addressable button `<id>.<option>` (and `<id>.reset`), so a scripted drive or a test picks one by
/// key. Used where a segmented control would not leave 24 pt targets (a row of five or six kinds).
extension InspectorPanel {
    func dropdownRow(id: String, label: String, options: [PanelDropdown.Option], current: String, tier: PropertyValueTier,
                     reset: (() -> Void)? = nil, pick: @escaping (String) -> Void) -> InspectorRow {
        let shown = options.first { $0.value == current }?.label ?? ""
        var buttons = options.filter { !$0.disabled }.map { o in
            InspectorRow.Button(key: "\(id).\(o.value)", label: o.label, style: o.value == current ? .chipActive : .chip,
                                action: { pick(o.value) })
        }
        if let reset { buttons.append(InspectorRow.Button(key: "\(id).reset", label: "↺", style: .muted, action: reset, disabled: tier == .default)) }
        let row = InspectorCustomRow(id: id, height: 30, draw: { c, r, panel in
            PanelDraw.text(c, label, in: CanvasRect(x: r.x, y: r.midY - 8.25, width: 86, height: 16.5),
                           font: PanelTheme.font(11), color: tier.labelColor)
            let right = Self.valueEdge(r)
            if reset != nil, tier != .default {
                let glyph = CanvasRect(x: right + PanelGrid.itemGap + (PanelGrid.minTarget - 11) / 2, y: r.midY - 5.5, width: 11, height: 11)
                PanelIcon.reset.draw(c, in: glyph, color: panel.hovered == .custom(id, 1) ? PanelTheme.text1 : PanelTheme.inspectorText)
                panel.addHit(CanvasRect(x: right + PanelGrid.itemGap, y: r.midY - PanelGrid.minTarget / 2,
                                        width: PanelGrid.minTarget, height: PanelGrid.minTarget), .custom(id, 1))
            }
            let field = CanvasRect(x: r.x + 96, y: r.midY - 14, width: max(0, right - r.x - 96), height: 28)
            PanelSelect.draw(c, field, text: shown, hovered: panel.hovered == .custom(id, 0))
            panel.addHit(field, .custom(id, 0))
        }, pointer: { [weak self] part, _, phase in
            guard phase == 0, let self else { return }
            if part == 1 { reset?(); return }
            guard let anchor = self.hits.rect(where: { $0 == .custom(id, 0) }) else { return }
            self.onOpenDropdown?(id, options, current, anchor) { v in pick(v) }
        })
        return InspectorRow(.custom(row), controls: [InspectorRow(.buttons(buttons))])
    }
}
