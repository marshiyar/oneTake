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
import MpvfxCanvas

extension RightPanel {
    /// Standard controls participate in the existing Tab / Enter and text-field paths.
    func drawRenderPresets(_ c: CanvasContext, _ r: CanvasRect) -> Double {
        let x = r.x + 12, w = r.width - 24
        let select = CanvasRect(x: x, y: r.y + 12, width: w, height: 28)
        PanelSelect.draw(c, select, text: presetName.isEmpty ? "Export presets" : presetName,
                         hovered: hovered == .preset, disabled: isRendering)
        if !isRendering { hits.add(select, .preset) }
        let name = CanvasRect(x: x, y: select.maxY + 8, width: w, height: 28)
        c.fillRoundedRect(name, radius: PanelTheme.radiusMd, PanelTheme.panelInput)
        let draft = field.flatMap { $0.key == "preset-name" ? $0.draft : nil }
        PanelDraw.text(c, draft ?? (presetName.isEmpty ? "Preset name" : presetName),
                       in: name.insetBy(6), font: PanelTheme.font(11), color: PanelTheme.text1)
        if draft != nil { PanelDraw.focusRing(c, name, radius: PanelTheme.radiusMd) }
        if !isRendering { hits.add(name, .presetName) }
        for (i, item) in [(Hit.savePreset, "Save / update"), (Hit.deletePreset, "Delete preset")].enumerated() {
            let rect = CanvasRect(x: x + Double(i) * (w + 8) / 2, y: name.maxY + 8, width: (w - 8) / 2, height: 28)
            let enabled = !isRendering && (item.0 == .savePreset || renderPresets.contains { $0.name == presetName })
            c.fillRoundedRect(rect, radius: PanelTheme.radiusMd,
                              hovered == item.0 && enabled ? PanelTheme.panelHover : PanelTheme.panelInput)
            PanelDraw.text(c, item.1, in: rect, font: PanelTheme.font(11),
                           color: enabled ? PanelTheme.text1 : PanelTheme.text4, align: .center)
            if enabled { hits.add(rect, item.0) }
        }
        return name.maxY + 36
    }

    /// Every setting is copied together; refusing an unsupported preset leaves the current settings intact.
    @discardableResult
    public func applyRenderPreset(named name: String) -> Bool {
        guard !isRendering, let preset = renderPresets.first(where: { $0.name == name }) else { return false }
        guard preset.hasValidSettings else { actionError = "Invalid render preset settings"; return false }
        if let reason = preset.unavailableReason { actionError = reason; return false }
        settings = preset.settings; presetName = name
        onSettingsChanged?(settings)
        return true
    }

    func handlePresetHit(_ hit: Hit) -> Bool {
        switch hit {
        case .preset:
            guard !isRendering, let anchor = hits.rect(where: { $0 == .preset }) else { return true }
            let options = renderPresets.map { preset in
                PanelDropdown.Option(value: preset.name,
                                     label: preset.name + (preset.unavailableReason.map { " — " + $0 } ?? ""),
                                     disabled: preset.unavailableReason != nil)
            }
            dropdown.open(key: "render-preset", options: options, selected: presetName, anchor: anchor,
                          bounds: CanvasRect(x: 0, y: 0, width: size.width, height: size.height)) { [weak self] name in
                _ = self?.applyRenderPreset(named: name); self?.onChange?()
            }
        case .presetName:
            if !isRendering { field = PanelTextField(key: "preset-name", value: presetName) }
        case .savePreset:
            if !isRendering { onSavePreset?(presetName, settings) }
        case .deletePreset:
            if !isRendering { onDeletePreset?(presetName) }
        default: return false
        }
        return true
    }
}
