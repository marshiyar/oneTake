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

/// The Media group's Fit row for video and image clips: "Fit" and a select (Fit, Fill, Stretch) that opens the
/// right panel's dropdown, and, once the clip carries a fit, the reset that returns it to Fit. Every pick is one
/// undo step through TimelineEditor.setMediaFit, saved in project.json as `clip.fit`.
extension InspectorPanel {
    static let mediaFitRowId = "mediaFit"

    /// The select's options, in the order the dropdown lists them.
    public static func mediaFitOptions() -> [PanelDropdown.Option] {
        NativeMediaFit.allCases.map { PanelDropdown.Option(value: $0.rawValue, label: mediaFitLabel($0)) }
    }

    static func mediaFitLabel(_ fit: NativeMediaFit) -> String {
        switch fit {
        case .fit: "Fit"
        case .fill: "Fill"
        case .stretch: "Stretch"
        }
    }

    /// The row's value tier: default while the key is absent, explicit default for a written-out Fit, custom for
    /// Fill and Stretch.
    public static func mediaFitTier(_ fit: NativeMediaFit?) -> PropertyValueTier {
        guard let fit else { return .default }
        return fit == .fit ? .explicitDefault : .explicitCustom
    }

    func setMediaFit(_ editor: TimelineEditor, _ s: Selected, _ fit: NativeMediaFit?) {
        edited(editor.setMediaFit(clipId: s.id, fit), label: "Set fit")
    }

    /// The Fit row, with its picks and reset as addressable buttons (scripted drives and tests press them by key:
    /// `mediaFit.fit`, `mediaFit.fill`, `mediaFit.stretch`, `mediaFit.reset`).
    func mediaFitRows(_ editor: TimelineEditor, _ s: Selected) -> [InspectorRow] {
        let shown = s.clip.fit ?? .fit
        var buttons = NativeMediaFit.allCases.map { f in
            InspectorRow.Button(key: "\(Self.mediaFitRowId).\(f.rawValue)", label: Self.mediaFitLabel(f),
                                style: f == shown ? .chipActive : .chip,
                                action: { [weak self] in self?.setMediaFit(editor, s, f) })
        }
        let reset = InspectorRow.Button(key: "\(Self.mediaFitRowId).reset", label: "↺", style: .muted,
                                        action: { [weak self] in self?.setMediaFit(editor, s, nil) },
                                        disabled: s.clip.fit == nil)
        buttons.append(reset)
        return [InspectorRow(.custom(mediaFitRow(editor, s)), controls: [InspectorRow(.buttons(buttons))])]
    }

    /// "Fit" in its tier colour, the select (PanelSelect, as the Composition preset draws it) and the reset (part 1).
    func mediaFitRow(_ editor: TimelineEditor, _ s: Selected) -> InspectorCustomRow {
        let fit = s.clip.fit
        return InspectorCustomRow(id: Self.mediaFitRowId, height: 30, draw: { c, r, panel in
            panel.drawMediaFit(c, r, fit: fit)
        }, pointer: { [weak self] part, _, phase in
            guard phase == 0, let self else { return }
            if part == 1 { self.setMediaFit(editor, s, nil) } else { self.openMediaFitDropdown(editor, s) }
        })
    }

    func drawMediaFit(_ c: CanvasContext, _ r: CanvasRect, fit: NativeMediaFit?) {
        let tier = Self.mediaFitTier(fit)
        PanelDraw.text(c, "Fit", in: CanvasRect(x: r.x, y: r.midY - 8.25, width: 86, height: 16.5),
                       font: PanelTheme.font(11), color: tier.labelColor)
        var right = Self.valueEdge(r)
        if tier != .default {
            let reset = CanvasRect(x: right + PanelGrid.itemGap + (PanelGrid.minTarget - 11) / 2, y: r.midY - 5.5, width: 11, height: 11)
            let hot = hovered == .custom(Self.mediaFitRowId, 1)
            PanelIcon.reset.draw(c, in: reset, color: hot ? PanelTheme.text1 : PanelTheme.inspectorText)
            addHit(CanvasRect(x: right + PanelGrid.itemGap, y: r.midY - PanelGrid.minTarget / 2,
                              width: PanelGrid.minTarget, height: PanelGrid.minTarget), .custom(Self.mediaFitRowId, 1))
            right = reset.x - 6
        }
        let field = CanvasRect(x: r.x + 96, y: r.midY - 14, width: max(0, right - r.x - 96), height: 28)
        PanelSelect.draw(c, field, text: Self.mediaFitLabel(fit ?? .fit),
                         hovered: hovered == .custom(Self.mediaFitRowId, 0))
        addHit(field, .custom(Self.mediaFitRowId, 0))
    }

    /// Opens the dropdown under the select drawn last, with the clip's fit marked.
    func openMediaFitDropdown(_ editor: TimelineEditor, _ s: Selected) {
        guard let anchor = hits.rect(where: { $0 == .custom(Self.mediaFitRowId, 0) }) else { return }
        let current = (s.clip.fit ?? .fit).rawValue
        onOpenDropdown?("media-fit", Self.mediaFitOptions(), current, anchor) { [weak self] v in
            guard let self, let f = NativeMediaFit(rawValue: v) else { return }
            self.setMediaFit(editor, s, f)
        }
    }
}
