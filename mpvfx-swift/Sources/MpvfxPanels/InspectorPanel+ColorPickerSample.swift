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

/// The colour picker's recent colours, its eyedropper (the stage frame captured into the picker, as the Grade
/// secondary's "Sample color from frame" does with the clip's frame) and its keys.
extension InspectorPanel {
    static let recentSwatch = 20.0, recentTarget = 24.0

    func pickerRecentRow() -> InspectorRow {
        let colors = pickerRecentColors()
        return InspectorRow(.custom(InspectorCustomRow(id: "picker:recent", height: 28, draw: { c, r, panel in
            PanelDraw.text(c, "Recent", in: CanvasRect(x: r.x, y: r.midY - 8.25, width: 60, height: 16.5), font: PanelTheme.font(11),
                           color: PanelTheme.rowLabel)
            var x = r.x + 64
            for (i, hex) in colors.enumerated() where x + Self.recentTarget <= r.maxX {
                let target = CanvasRect(x: x, y: r.midY - Self.recentTarget / 2, width: Self.recentTarget, height: Self.recentTarget)
                panel.drawSwatch(c, target.insetBy((Self.recentTarget - Self.recentSwatch) / 2), hex: hex)
                panel.addHit(target, .custom("picker:recent", i))
                x += Self.recentTarget + 2
            }
            if colors.isEmpty {
                PanelDraw.text(c, "None yet", in: CanvasRect(x: x, y: r.midY - 8.25, width: r.maxX - x, height: 16.5),
                               font: PanelTheme.font(11), color: PanelTheme.text4)
            }
        }, pointer: { [weak self] part, _, phase in
            guard let self, phase == 0, colors.indices.contains(part), let c = PickerColor(hex: colors[part]) else { return }
            let keepAlpha = self.colorPicker?.allowAlpha == true
            self.colorPicker?.color = keepAlpha ? c : PickerColor(hue: c.hue, saturation: c.saturation, value: c.value)
            self.commitPickerColor()
        })), rail: true)
    }

    // MARK: Eyedropper

    func pickerSampleRows() -> [InspectorRow] {
        guard let cp = colorPicker else { return [] }
        if cp.frameError {
            return [InspectorRow(.custom(InspectorCustomRow(id: "picker:frameError", height: 16, draw: { c, r, _ in
                PanelDraw.text(c, "Preview frame unavailable. Try again after the media loads.", in: r, font: PanelTheme.font(10), color: PanelTheme.red400)
            })), rail: true)]
        }
        guard let frame = cp.frame else {
            if cp.framePending { capturePickerFrame() }   // still rendering: ask again on this draw
            return []
        }
        let height = min(180, max(40, bodyContentWidth * Double(frame.height) / Double(max(1, frame.width))))
        return [InspectorRow(.custom(InspectorCustomRow(id: "picker:frame", height: height, draw: { [weak self] c, r, panel in
            c.fillRect(r, PanelTheme.black)
            let pic = PreviewImageFit.contain(frame.width, frame.height, in: r)
            self?.colorPicker?.frameRect = pic
            c.drawImage(frame, in: pic)
            c.strokeRect(r.insetBy(0.5), PanelTheme.panelHairline)
            panel.addHit(pic, .custom("picker:frame", 0))
        }, pointer: { [weak self] _, p, phase in if phase == 0 { self?.samplePickerFrame(at: p) } })), rail: true)]
    }

    /// Asks the host for the stage frame; a frame still rendering is asked for again on the next draw.
    func capturePickerFrame() {
        switch stageFrame?(Self.sampleFrameSize, Self.sampleFrameSize) ?? .unavailable {
        case .ready(let img): colorPicker?.frame = img; colorPicker?.framePending = false; colorPicker?.frameError = false
        case .rendering: colorPicker?.framePending = true
        case .unavailable: colorPicker?.framePending = false; colorPicker?.frameError = true
        }
    }

    /// The pixel under `p` on the captured frame becomes the colour (alpha kept), written at once.
    func samplePickerFrame(at p: CanvasPoint) {
        guard let cp = colorPicker, let frame = cp.frame, cp.frameRect.width > 0, cp.frameRect.height > 0 else { return }
        let x = Int((p.x - cp.frameRect.x) / cp.frameRect.width * Double(frame.width))
        let y = Int((p.y - cp.frameRect.y) / cp.frameRect.height * Double(frame.height))
        guard x >= 0, y >= 0, x < frame.width, y < frame.height else { return }
        let i = (y * frame.width + x) * 4
        let c = PickerColor.fromRGB(Double(frame.rgba[i]) / 255, Double(frame.rgba[i + 1]) / 255, Double(frame.rgba[i + 2]) / 255,
                                    alpha: cp.color.alpha)
        colorPicker?.color = c
        commitPickerColor()
    }

    // MARK: Keys

    /// Escape closes the picker; arrows move the focused square (saturation ←→, value ↑↓) or bar, Shift ten times
    /// as far, a held key folding into one undo step. Enter and Space on a square or bar do nothing (a press there
    /// would jump to its centre). nil: not the picker's key.
    func pickerKey(_ k: EditorKey) -> Bool? {
        guard colorPicker != nil, field == nil, !k.command, !k.alt else { return nil }
        if k.code == .escape { closeColorPicker(); return true }
        guard case .custom(let id, 0)? = focus.current, Self.pickerKeyParts.contains(id) else { return nil }
        if k.code == .enter || k.code == .space { return true }
        guard let (dx, dy) = Self.arrowStep(k) else { return nil }
        nudgePicker(id, dx: dx, dy: dy)
        return true
    }

    static let pickerKeyParts: Set<String> = ["picker:sv", "picker:hue", "picker:alpha"]

    /// An arrow as a move along x and y in 0…1 units: 1 %, or 10 % with Shift; nil for any other key.
    static func arrowStep(_ k: EditorKey) -> (Double, Double)? {
        let step = k.shift ? 0.1 : 0.01
        switch k.code {
        case .left: return (-step, 0)
        case .right: return (step, 0)
        case .up: return (0, step)
        case .down: return (0, -step)
        default: return nil
        }
    }

    func nudgePicker(_ id: String, dx: Double, dy: Double) {
        guard var c = colorPicker?.color else { return }
        switch id {
        case "picker:sv": c.saturation = min(1, max(0, c.saturation + dx)); c.value = min(1, max(0, c.value + dy))
        case "picker:hue": c.hue = min(359.999, max(0, c.hue + (dx + dy) * 360))
        default: c.alpha = min(1, max(0, c.alpha + dx + dy))
        }
        colorPicker?.color = c
        commitPickerColor(coalesce: "picker-keys:\(id)")
        focus.visible = true
    }
}
