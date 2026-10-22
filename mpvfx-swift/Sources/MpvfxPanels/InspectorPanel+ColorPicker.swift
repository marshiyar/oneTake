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

/// One colour property of the selected clip (Fill, Stroke color, Text color) as the inspector shows it.
struct ColorFieldSpec {
    var key: String, label: String
    /// The stored value (nil: none, transparent or the default) and what the field reads then.
    var value: String?, placeholder: String
    /// Whether the renderer reads an alpha byte for this property (Fill), so the picker offers it.
    var allowAlpha: Bool
    var historyLabel: String
    /// Linked text fields display resolved values while their tier and reset follow the local override.
    var tier: PropertyValueTier? = nil
    var reset: (() -> Bool)? = nil
    /// Writes a normalized hex, or nil to clear; false when nothing changed.
    var apply: (String?) -> Bool
}

/// The open colour picker (issue #189): which field, the colour being edited (HSV, so a drag through grey keeps
/// its hue) and the eyedropper's captured frame.
public struct ColorPickerState {
    public var key: String
    public var clipId: String
    public var color: PickerColor
    /// The document value the colour was last read from; a different stored value (an undo) re-reads it.
    var source: String?
    var allowAlpha = false
    var dragging = false
    var commit: ((String, String?) -> Void)?
    var frame: CanvasImage?
    var framePending = false, frameError = false
    var frameRect = CanvasRect(x: 0, y: 0, width: 0, height: 0)
    var svImage: (hue: Double, image: CanvasImage)?
}

extension InspectorPanel {
    static let colorFormatHint = "Enter a colour like #1A2B3C"
    static let maxRecentColors = 8

    /// A colour row: the field with its swatch, the format hint after a refused value, and the picker when open.
    func colorRows(_ f: ColorFieldSpec, clipId: String) -> [InspectorRow] {
        let swatchKey = "swatch:\(f.key)"
        let tier = f.tier ?? (f.value == nil ? .default : .explicitCustom)
        let number = InspectorRow.Number(
            key: f.key, label: f.label, text: f.value ?? f.placeholder, tier: tier,
            commit: { [weak self] text in self?.commitColorText(text, f) },
            reset: tier == .default ? nil : { [weak self] in self?.edited(f.reset?() ?? f.apply(nil), label: f.historyLabel) },
            swatch: InspectorRow.Swatch(color: normalizedHexColor(f.value ?? f.placeholder), key: swatchKey))
        let open = InspectorRow(.buttons([InspectorRow.Button(key: swatchKey, label: "Pick \(f.label.lowercased())", style: .chip) { [weak self] in
            self?.toggleColorPicker(f, clipId: clipId)
        }]))
        var rows = [InspectorRow(.number(number), controls: [open])]
        if colorFieldError == f.key { rows.append(colorHintRow(f.key)) }
        if colorPicker?.key == f.key, colorPicker?.clipId == clipId { rows += pickerRows(f) }
        return rows
    }

    func colorHintRow(_ key: String) -> InspectorRow {
        InspectorRow(.custom(InspectorCustomRow(id: "colorHint:\(key)", height: 16, draw: { c, r, _ in
            PanelDraw.text(c, Self.colorFormatHint, in: r, font: PanelTheme.font(11), color: PanelTheme.red400, align: .right)
        })))
    }

    /// A typed value: a colour, or empty / "none" / "transparent" to clear; anything else keeps the old value and
    /// shows the format hint until the next edit.
    func commitColorText(_ text: String, _ f: ColorFieldSpec) {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        let cleared = t.isEmpty || t == "transparent" || t == "none"
        guard cleared || normalizedHexColor(t) != nil else { colorFieldError = f.key; onEdited?(); return }
        colorFieldError = nil
        edited(f.apply(cleared ? nil : t), label: f.historyLabel)
    }

    func toggleColorPicker(_ f: ColorFieldSpec, clipId: String) {
        if colorPicker?.key == f.key { colorPicker = nil; onEdited?(); return }
        let start = PickerColor(hex: f.value ?? f.placeholder) ?? PickerColor(hue: 0, saturation: 0, value: 1)   // none: start from white
        colorPicker = ColorPickerState(key: f.key, clipId: clipId, color: start, source: f.value, allowAlpha: f.allowAlpha)
        onEdited?()
    }

    func closeColorPicker() {
        guard let key = colorPicker?.key else { return }
        colorPicker = nil
        focus.current = .button("swatch:\(key)")
        onEdited?()
    }

    /// Writes the picker's colour as one undo step (`coalesce` folds a run of arrow keys into one).
    func commitPickerColor(coalesce: String? = nil) {
        guard let cp = colorPicker, let commit = cp.commit else { return }
        let hex = cp.color.hex(allowAlpha: cp.allowAlpha)
        colorPicker?.source = hex
        rememberRecentColor(hex)
        commit(hex, coalesce)
    }

    func rememberRecentColor(_ hex: String) {
        recentColors.removeAll { $0 == hex }
        recentColors.insert(hex, at: 0)
        if recentColors.count > Self.maxRecentColors { recentColors.removeLast(recentColors.count - Self.maxRecentColors) }
    }

    /// The swatches under the picker: colours picked in this session, newest first, then the colours the project
    /// already uses (fills, strokes, text, the canvas), at most `maxRecentColors`.
    func pickerRecentColors() -> [String] {
        var out: [String] = []
        for c in recentColors + Self.projectColors(editor?.document) where !out.contains(c) && out.count < Self.maxRecentColors { out.append(c) }
        return out
    }

    // MARK: Swatch

    static let swatchSize = 16.0, swatchTargetSize = 24.0

    /// The swatch's 24 pt target, centred on the 16 pt swatch at the field's left edge.
    static func swatchTarget(field: CanvasRect, midY: Double) -> CanvasRect {
        let inset = (swatchTargetSize - swatchSize) / 2
        return CanvasRect(x: field.x - inset, y: midY - swatchTargetSize / 2, width: swatchTargetSize, height: swatchTargetSize)
    }

    /// Draws a number row's swatch at the field's left edge; returns where the value text starts.
    func drawSwatchSlot(_ sw: InspectorRow.Swatch, field: CanvasRect, midY: Double, _ c: CanvasContext) -> Double {
        let box = Self.swatchTarget(field: field, midY: midY).insetBy((Self.swatchTargetSize - Self.swatchSize) / 2)
        drawSwatch(c, box, hex: sw.color)
        return box.maxX + 6
    }

    /// A document colour as a square: the checkerboard first when it is none or not opaque, then the colour.
    func drawSwatch(_ c: CanvasContext, _ r: CanvasRect, hex: String?) {
        let color = hex.flatMap(normalizedHexColor).map(CanvasColor.documentColor)
        if (color?.a ?? 0) < 1 { Self.drawChecker(c, r) }
        if let color { c.fillRect(r, color) }
        c.strokeRect(r.insetBy(0.5), PanelTheme.panelBorderInput)
    }

    static func projectColors(_ doc: NativeProjectDocument?) -> [String] {
        guard let doc else { return [] }
        var raw: [String?] = []
        for clip in doc.sequence.tracks.flatMap(\.clips) {
            let text = resolvedText(clip, doc.textStyles ?? [])
            raw += [clip.style?.fill, clip.style?.strokeColor, text?.color]
        }
        raw.append(doc.canvas.background)
        var out: [String] = []
        for c in raw.compactMap({ $0.flatMap(normalizedHexColor) }) where !out.contains(c) { out.append(c) }
        return out
    }
}
