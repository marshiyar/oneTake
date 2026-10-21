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

/// The Style group's Blend row for visual clips: "Blend" and a select (Normal, Multiply, Screen, Overlay, Add, Soft
/// light, Darken, Lighten) beside Opacity, and, once the clip carries a mode, the reset back to Normal. Every pick
/// is one undo step through TimelineEditor.setClipBlend, saved in project.json as `clip.style.blend`.
extension InspectorPanel {
    static let blendRowId = "blend"

    /// The select's options, in the order the dropdown lists them.
    public static func blendOptions() -> [PanelDropdown.Option] {
        NativeBlendMode.allCases.map { PanelDropdown.Option(value: $0.rawValue, label: $0.label) }
    }

    /// Default while the key is absent, custom for any other mode.
    public static func blendTier(_ mode: NativeBlendMode) -> PropertyValueTier { mode == .normal ? .default : .explicitCustom }

    func setBlend(_ editor: TimelineEditor, _ s: Selected, _ mode: NativeBlendMode) {
        edited(editor.setClipBlend(clipId: s.id, mode), label: "Set blend mode")
    }

    func blendRow(_ editor: TimelineEditor, _ s: Selected) -> InspectorRow {
        let mode = s.clip.style?.blendMode ?? .normal
        return InspectorRow(.custom(InspectorCustomRow(id: Self.blendRowId, height: 30, draw: { c, r, panel in
            panel.drawBlend(c, r, mode: mode)
        }, pointer: { [weak self] part, _, phase in
            guard phase == 0, let self else { return }
            if part == 1 { self.setBlend(editor, s, .normal) } else { self.openBlendDropdown(editor, s) }
        })))
    }

    func drawBlend(_ c: CanvasContext, _ r: CanvasRect, mode: NativeBlendMode) {
        let tier = Self.blendTier(mode)
        PanelDraw.text(c, "Blend", in: CanvasRect(x: r.x, y: r.midY - 8.25, width: 86, height: 16.5),
                       font: PanelTheme.font(11), color: tier.labelColor)
        var right = r.maxX
        if tier != .default {
            let reset = CanvasRect(x: right - 11, y: r.midY - 5.5, width: 11, height: 11)
            let hot = hovered == .custom(Self.blendRowId, 1)
            PanelIcon.reset.draw(c, in: reset, color: hot ? PanelTheme.text1 : PanelTheme.text3)
            addHit(reset.insetBy(-3), .custom(Self.blendRowId, 1))
            right = reset.x - 6
        }
        let field = CanvasRect(x: r.x + 96, y: r.midY - 14, width: max(0, right - r.x - 96), height: 28)
        PanelSelect.draw(c, field, text: mode.label, hovered: hovered == .custom(Self.blendRowId, 0))
        addHit(field, .custom(Self.blendRowId, 0))
    }

    func openBlendDropdown(_ editor: TimelineEditor, _ s: Selected) {
        guard let anchor = hits.rect(where: { $0 == .custom(Self.blendRowId, 0) }) else { return }
        let current = (s.clip.style?.blendMode ?? .normal).rawValue
        onOpenDropdown?("blend", Self.blendOptions(), current, anchor) { [weak self] v in
            guard let self, let m = NativeBlendMode(rawValue: v) else { return }
            self.setBlend(editor, s, m)
        }
    }
}
