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
import MpvfxTimeline   // EditorKey

/// "Export versions" (⇧⌘R): a card over the Renders tab with a checklist of the export presets. Export queues one
/// render per checked preset (the host runs them one after another, each with its own row in the render list).
/// Keyboard: ↑ ↓ move, Space checks, Return exports, Escape closes. Unusable presets are listed disabled with the reason.
public final class ExportVersionsCard {
    public enum Hit: Hashable { case toggle(String), size(String), export, close, card }

    public private(set) var isOpen = false
    public private(set) var presets: [RenderPreset] = []
    /// Names of the checked presets. Kept for the session, so the next run starts from the last choice.
    public private(set) var checked: Set<String> = []
    /// The row the keyboard acts on.
    public private(set) var cursor = 0
    public var hovered: Hit?
    /// Asks the host to render these presets, in the order of the preset list.
    public var onExport: (([String]) -> Void)?
    /// A preset's composition size was chosen in its row (nil: the project's own size). The host saves it and
    /// gives the card the updated list (`setPresets`).
    public var onSetComposition: ((String, RenderPresetComposition?) -> Void)?
    let dropdown = PanelDropdown()
    public private(set) var hits = HitMap<Hit>()
    private var scroll = 0
    private var size = CanvasSize(0, 0)

    static let rowH = 30.0, pad = 16.0, header = 44.0, footer = 56.0

    public init() {}

    /// The presets that can render: valid settings and a format the engine offers.
    public func isUsable(_ preset: RenderPreset) -> Bool { preset.hasValidSettings && preset.unavailableReason == nil }
    func reason(_ preset: RenderPreset) -> String? {
        preset.hasValidSettings ? preset.unavailableReason : "Invalid settings"
    }

    public func open(presets: [RenderPreset]) {
        self.presets = presets
        checked = checked.intersection(presets.filter(isUsable).map(\.name))
        cursor = 0; scroll = 0; hovered = nil; isOpen = true
    }

    public func close() { dropdown.close(); isOpen = false; hovered = nil }

    /// The list after an edit made from the card; checks and the cursor stay.
    public func setPresets(_ presets: [RenderPreset]) {
        self.presets = presets
        checked = checked.intersection(presets.filter(isUsable).map(\.name))
        cursor = min(cursor, max(0, presets.count - 1))
    }

    static let projectSize = "project", keepSize = "keep"

    /// "Project size", one of the named sizes, or the saved size as it is.
    static func sizeLabel(_ preset: RenderPreset) -> String {
        guard let size = preset.composition else { return "Project size" }
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    func sizeOptions(for preset: RenderPreset) -> [PanelDropdown.Option] {
        var options = [PanelDropdown.Option(value: Self.projectSize, label: "Project size")]
        options += NativeCompositionPreset.allCases.map {
            PanelDropdown.Option(value: $0.rawValue, label: "\($0.label) · \(Int($0.width)) × \(Int($0.height))")
        }
        if let size = preset.composition, NativeCompositionPreset.matching(width: size.width, height: size.height) == nil {
            options.append(PanelDropdown.Option(value: Self.keepSize, label: Self.sizeLabel(preset)))
        }
        return options
    }

    func selectedSize(of preset: RenderPreset) -> String {
        guard let size = preset.composition else { return Self.projectSize }
        return NativeCompositionPreset.matching(width: size.width, height: size.height)?.rawValue ?? Self.keepSize
    }

    private func openSizeMenu(for name: String) {
        guard let preset = presets.first(where: { $0.name == name }), let anchor = hits.rect(where: { $0 == .size(name) }) else { return }
        dropdown.open(key: "composition-size", options: sizeOptions(for: preset), selected: selectedSize(of: preset), anchor: anchor,
                      bounds: CanvasRect(x: 0, y: 0, width: size.width, height: size.height)) { [weak self] value in
            switch value {
            case Self.keepSize: return
            case Self.projectSize: self?.onSetComposition?(name, nil)
            default:
                guard let named = NativeCompositionPreset(rawValue: value) else { return }
                self?.onSetComposition?(name, RenderPresetComposition(width: named.width, height: named.height))
            }
        }
    }

    public func toggle(_ name: String) {
        guard let preset = presets.first(where: { $0.name == name }), isUsable(preset) else { return }
        if checked.contains(name) { checked.remove(name) } else { checked.insert(name) }
    }

    /// The checked presets in list order.
    public var selection: [String] { presets.filter { checked.contains($0.name) }.map(\.name) }

    /// Closes the card and hands the checked presets to the host; nothing happens while none is checked.
    @discardableResult
    public func export() -> Bool {
        let names = selection
        guard !names.isEmpty else { return false }
        close()
        onExport?(names)
        return true
    }

    // MARK: Draw

    func cardRect(in size: CanvasSize) -> CanvasRect {
        let w = min(340, max(0, size.width - 24))
        let rows = Double(max(1, min(presets.count, visibleRows(in: size))))
        let h = Self.header + rows * Self.rowH + Self.footer
        return CanvasRect(x: (size.width - w) / 2, y: max(12, min(60, (size.height - h) / 2)), width: w, height: h)
    }

    func visibleRows(in size: CanvasSize) -> Int { max(1, Int((size.height - 24 - Self.header - Self.footer) / Self.rowH)) }

    public func draw(_ c: CanvasContext, size: CanvasSize) {
        self.size = size
        hits.reset()
        guard isOpen else { return }
        c.fillRect(CanvasRect(x: 0, y: 0, width: size.width, height: size.height), PanelTheme.stageScrim.withAlpha(0.45))
        let card = cardRect(in: size)
        hits.add(card, .card)
        c.fillRoundedRect(card, radius: PanelTheme.radiusXl, PanelStyle.popoverBackground)
        c.strokeRoundedRect(card.insetBy(0.5), radius: PanelTheme.radiusXl - 0.5, PanelTheme.panelBorderInput, width: 1)
        let x = card.x + Self.pad, w = card.width - 2 * Self.pad
        PanelDraw.text(c, "Export versions", in: CanvasRect(x: x, y: card.y + 14, width: w - 30, height: 20),
                       font: PanelTheme.font(14, .semibold), color: PanelTheme.text0)
        PanelDraw.hline(c, x0: card.x + 1, x1: card.maxX - 1, y: card.y + Self.header, PanelTheme.panelBorderInput)
        if presets.isEmpty {
            PanelDraw.text(c, "No export presets yet. Save one in the Renders tab.", in: CanvasRect(x: x, y: card.y + Self.header + 6, width: w, height: 18),
                           font: PanelTheme.font(11), color: PanelTheme.text3)
        }
        let shown = visibleRows(in: size)
        let first = min(scroll, max(0, presets.count - shown))
        for (i, preset) in presets.enumerated().dropFirst(first).prefix(shown) {
            drawRow(c, preset, index: i, y: card.y + Self.header + Double(i - first) * Self.rowH, x: card.x, width: card.width)
        }
        let foot = card.maxY - Self.footer
        PanelDraw.hline(c, x0: card.x + 1, x1: card.maxX - 1, y: foot, PanelTheme.panelBorderInput)
        let n = checked.count
        let buttonW = 96.0
        let exportR = CanvasRect(x: card.maxX - Self.pad - buttonW, y: foot + 14, width: buttonW, height: 28)
        let closeR = CanvasRect(x: exportR.x - 8 - 70, y: exportR.y, width: 70, height: 28)
        PanelDraw.smallButton(c, closeR, label: "Cancel", fill: hovered == .close ? PanelTheme.panelHover : PanelTheme.panelSurface, color: PanelTheme.text1)
        hits.add(closeR, .close)
        PanelDraw.smallButton(c, exportR, label: n == 0 ? "Export" : "Export \(n)",
                              fill: n == 0 ? PanelTheme.panelInput : (hovered == .export ? PanelTheme.accent.withAlpha(0.85) : PanelTheme.accent),
                              color: n == 0 ? PanelTheme.text4 : PanelTheme.onAccent)
        if n > 0 { hits.add(exportR, .export) }
        defer { dropdown.draw(c) }
        PanelDraw.text(c, n == 0 ? "Check the versions to render." : "One after another.", in: CanvasRect(x: x, y: foot + 18, width: closeR.x - x - 6, height: 16),
                       font: PanelTheme.font(10), color: PanelTheme.text3)
    }

    private func drawRow(_ c: CanvasContext, _ preset: RenderPreset, index: Int, y: Double, x: Double, width: Double) {
        let row = CanvasRect(x: x + 8, y: y, width: width - 16, height: Self.rowH)
        let usable = isUsable(preset), on = checked.contains(preset.name)
        if hovered == .toggle(preset.name) && usable { c.fillRoundedRect(row, radius: PanelTheme.radiusMd, PanelTheme.panelHover) }
        if index == cursor { c.strokeRoundedRect(row.insetBy(0.5), radius: PanelTheme.radiusMd, PanelTheme.accent, width: 1) }
        let box = CanvasRect(x: row.x + 8, y: row.y + (Self.rowH - 14) / 2, width: 14, height: 14)
        c.fillRoundedRect(box, radius: 3, on ? PanelTheme.accent : PanelTheme.panelInput)
        c.strokeRoundedRect(box.insetBy(0.5), radius: 2.5, usable ? PanelTheme.panelBorderInput : PanelTheme.text5, width: 1)
        if on { PanelDraw.text(c, "✓", in: box, font: PanelTheme.font(10, .semibold), color: PanelTheme.onAccent, align: .center) }
        let left = box.maxX + 8, room = row.maxX - left - 8
        let text = CanvasRect(x: left, y: row.y, width: usable ? room - 124 : 90, height: Self.rowH)
        PanelDraw.text(c, preset.name, in: text, font: PanelTheme.font(11), color: usable ? PanelTheme.text1 : PanelTheme.text4)
        if usable { hits.add(row, .toggle(preset.name)) }
        if let why = reason(preset) {
            PanelDraw.text(c, why, in: CanvasRect(x: text.maxX + 6, y: row.y, width: room - text.width - 6, height: Self.rowH),
                           font: PanelTheme.font(9), color: PanelTheme.text4, align: .right)
            return
        }
        // The size this version renders at: a small select at the row's right end (added after the row, so it wins the press).
        let pick = CanvasRect(x: row.maxX - 124, y: row.y + 3, width: 116, height: Self.rowH - 6)
        PanelSelect.draw(c, pick, text: Self.sizeLabel(preset), hovered: hovered == .size(preset.name))
        hits.add(pick, .size(preset.name))
    }

    // MARK: Input

    /// The card takes every press while open: a press outside it closes it.
    public func pointerDown(_ p: CanvasPoint) -> Bool {
        guard isOpen else { return false }
        if dropdown.pointerDown(p) { return true }
        switch hits.hit(p) {
        case .size(let name)?: openSizeMenu(for: name)
        case .toggle(let name)?:
            toggle(name)
            if let i = presets.firstIndex(where: { $0.name == name }) { cursor = i }
        case .export?: export()
        case .close?: close()
        case .card?: break
        case nil: close()
        }
        return true
    }

    public func pointerMove(_ p: CanvasPoint) -> Bool {
        guard isOpen else { return false }
        if dropdown.isOpen { return dropdown.pointerMove(p) }
        var now = hits.hit(p)
        if now == .card { now = nil }
        if now != hovered { hovered = now; return true }
        return false
    }

    /// The wheel scrolls a long list.
    public func scrollBy(_ dy: Double) {
        guard isOpen else { return }
        if dropdown.isOpen { dropdown.scrollBy(dy); return }
        let hidden = max(0, presets.count - visibleRows(in: size))
        scroll = max(0, min(hidden, scroll + (dy > 0 ? 1 : dy < 0 ? -1 : 0)))
        // Space and Return act on the cursor row, so it stays among the rows that are shown.
        let rows = visibleRows(in: size)
        cursor = max(scroll, min(cursor, scroll + rows - 1))
    }

    public func keyDown(_ k: EditorKey) -> Bool {
        guard isOpen else { return false }
        if k.command { return false }   // ⌘Q, ⌘W and the like stay the app's
        if dropdown.key(k) { return true }
        switch k.code {
        case .escape: close()
        case .enter: export()
        case .space: if presets.indices.contains(cursor) { toggle(presets[cursor].name) }
        case .up: cursor = max(0, cursor - 1); keepCursorShown()
        case .down: cursor = max(0, min(presets.count - 1, cursor + 1)); keepCursorShown()
        default: break
        }
        return true   // modal: no key reaches the editor behind
    }

    private func keepCursorShown() {
        let rows = visibleRows(in: size)
        if cursor < scroll { scroll = cursor } else if cursor >= scroll + rows { scroll = cursor - rows + 1 }
    }
}
