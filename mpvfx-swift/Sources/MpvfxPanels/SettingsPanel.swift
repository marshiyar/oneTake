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
import MpvfxTimeline   // EditorKey

/// The Settings window (Cmd/Ctrl+,): a modal card over the editor with the per-user settings kept in
/// `<userData>/preferences.json`: appearance, audio output device, preview cache size and the default export folder.
/// The host owns persistence: every change goes out through `onChange` with the new values, and "Choose…" asks the
/// host for a folder (`onChooseExportFolder`), which answers by setting `values.exportFolder`.
public final class SettingsPanel {
    public struct Values: Equatable {
        public var appearance: ThemeAppearance
        /// Audio output device id; nil is the system default.
        public var audioDevice: String?
        /// Preview frame cache in MB; nil is automatic.
        public var previewCacheMB: Int?
        /// Default export folder; nil is the app's renders folder.
        public var exportFolder: String?
        public init(appearance: ThemeAppearance = .system, audioDevice: String? = nil, previewCacheMB: Int? = nil, exportFolder: String? = nil) {
            self.appearance = appearance; self.audioDevice = audioDevice; self.previewCacheMB = previewCacheMB; self.exportFolder = exportFolder
        }
    }
    public struct Device: Equatable { public var id, name: String
        public init(id: String, name: String) { self.id = id; self.name = name } }
    public enum Hit: Hashable { case close, appearance(ThemeAppearance), audio, cache, chooseFolder, resetFolder, card }

    /// The cache sizes offered (MB); nil is automatic.
    public static let cacheChoicesMB: [Int?] = [nil, 512, 1024, 2048, 4096, 8192]
    public static let width = 440.0

    public private(set) var isOpen = false
    public var values = Values()
    /// The devices the system offers (empty: only the system default can be chosen).
    public var devices: [Device] = []
    /// Shown under the audio row when the platform plays through the system default only.
    public var deviceChoiceUnavailable = false
    public var onChange: ((Values) -> Void)?
    public var onChooseExportFolder: (() -> Void)?
    /// Called when the card opens (the host refreshes `devices`).
    public var onOpen: (() -> Void)?
    public let dropdown = PanelDropdown()
    public private(set) var hits = HitMap<Hit>()
    public var hovered: Hit?
    private var size = CanvasSize(0, 0)

    public init() {}

    public func open() { guard !isOpen else { return }; isOpen = true; hovered = nil; onOpen?() }
    public func close() { isOpen = false; dropdown.close(); hovered = nil }
    public func toggle() { if isOpen { close() } else { open() } }

    public static func cacheLabel(_ mb: Int?) -> String {
        guard let mb else { return "Automatic" }
        return mb >= 1024 && mb % 1024 == 0 ? "\(mb / 1024) GB" : "\(mb) MB"
    }

    var audioLabel: String {
        guard let id = values.audioDevice else { return "System default" }
        return devices.first { $0.id == id }?.name ?? "\(id) (not connected)"
    }

    private static let title = PanelTheme.font(13, .semibold), label = PanelTheme.font(11, .medium), body = PanelTheme.font(11)
    private static let note = PanelTheme.font(10)
    static let rowH = 28.0, pad = 20.0, labelW = 132.0

    public func cardRect(in size: CanvasSize) -> CanvasRect {
        let h = 52 + 4 * (Self.rowH + 18) + 30 + Self.pad
        let w = min(Self.width, max(0, size.width - 32))
        return CanvasRect(x: ((size.width - w) / 2).rounded(), y: max(16, ((size.height - h) / 2).rounded()), width: w, height: h)
    }

    // MARK: Draw (window coordinates)

    public func draw(_ c: CanvasContext, size: CanvasSize) {
        self.size = size
        hits.reset()
        guard isOpen else { return }
        c.fillRect(CanvasRect(x: 0, y: 0, width: size.width, height: size.height), PanelTheme.black.withAlpha(0.45))
        let card = cardRect(in: size)
        hits.add(card, .card)
        c.fillRoundedRect(card, radius: PanelTheme.radiusXl, PanelTheme.neutral950)
        c.strokeRoundedRect(card.insetBy(0.5), radius: PanelTheme.radiusXl - 0.5, PanelTheme.neutral700, width: 1)
        let x = card.x + Self.pad, w = card.width - 2 * Self.pad
        PanelDraw.text(c, "Settings", in: CanvasRect(x: x, y: card.y + 16, width: w - 30, height: 20), font: Self.title, color: PanelTheme.neutral50)
        let closeR = CanvasRect(x: card.maxX - 14 - 24, y: card.y + 14, width: 24, height: 24)
        PanelDraw.iconButton(c, closeR, icon: .close, hovered: hovered == .close)
        hits.add(closeR, .close)
        PanelDraw.hline(c, x0: card.x, x1: card.maxX, y: card.y + 48, PanelTheme.neutral800)

        var y = card.y + 52 + 12
        let cx = x + Self.labelW, cw = max(0, w - Self.labelW)
        func rowLabel(_ s: String) {
            PanelDraw.text(c, s, in: CanvasRect(x: x, y: y, width: Self.labelW - 8, height: Self.rowH), font: Self.label, color: PanelTheme.neutral300)
        }
        func noteLine(_ s: String) {
            PanelDraw.text(c, s, in: CanvasRect(x: cx, y: y + Self.rowH + 2, width: cw, height: 14), font: Self.note, color: PanelTheme.neutral500)
        }

        // Appearance: System / Light / Dark
        rowLabel("Appearance")
        let seg = CanvasRect(x: cx, y: y, width: cw, height: Self.rowH)
        c.fillRoundedRect(seg, radius: PanelTheme.radiusMd, PanelTheme.neutral900)
        let segW = seg.width / Double(ThemeAppearance.allCases.count)
        for (i, a) in ThemeAppearance.allCases.enumerated() {
            let r = CanvasRect(x: seg.x + Double(i) * segW, y: seg.y, width: segW, height: seg.height)
            let inner = r.insetBy(2), on = a == values.appearance, hov = hovered == .appearance(a)
            if on { c.fillRoundedRect(inner, radius: PanelTheme.radius, PanelTheme.neutral700) }
            else if hov { c.fillRoundedRect(inner, radius: PanelTheme.radius, PanelTheme.neutral800) }
            PanelDraw.text(c, a.label, in: inner, font: Self.body, color: on ? PanelTheme.neutral50 : (hov ? PanelTheme.neutral200 : PanelTheme.neutral400), align: .center)
            hits.add(r, .appearance(a))
        }
        y += Self.rowH + 18

        // Audio output
        rowLabel("Audio output")
        let audioR = CanvasRect(x: cx, y: y, width: cw, height: Self.rowH)
        let audioEnabled = !devices.isEmpty || values.audioDevice != nil
        PanelSelect.draw(c, audioR, text: audioLabel, hovered: hovered == .audio, disabled: !audioEnabled)
        if audioEnabled { hits.add(audioR, .audio) }
        if deviceChoiceUnavailable { noteLine("Plays through the system's default output on this platform.") }
        y += Self.rowH + 18

        // Preview cache
        rowLabel("Preview cache")
        let cacheR = CanvasRect(x: cx, y: y, width: cw, height: Self.rowH)
        PanelSelect.draw(c, cacheR, text: Self.cacheLabel(values.previewCacheMB), hovered: hovered == .cache)
        hits.add(cacheR, .cache)
        noteLine("Memory for decoded preview frames.")
        y += Self.rowH + 18

        // Default export folder
        rowLabel("Export folder")
        let reset = values.exportFolder != nil
        let chooseW = 70.0, resetW = reset ? 56.0 : 0
        let fieldW = max(0, cw - chooseW - 6 - (reset ? resetW + 6 : 0))
        let field = CanvasRect(x: cx, y: y, width: fieldW, height: Self.rowH)
        c.fillRoundedRect(field, radius: PanelTheme.radiusMd, PanelTheme.panelInput)
        PanelDraw.text(c, values.exportFolder ?? "App renders folder", in: CanvasRect(x: field.x + 8, y: field.y, width: max(0, field.width - 16), height: field.height),
                       font: Self.body, color: values.exportFolder == nil ? PanelTheme.neutral500 : PanelTheme.text1)
        let chooseR = CanvasRect(x: field.maxX + 6, y: y, width: chooseW, height: Self.rowH)
        PanelDraw.smallButton(c, chooseR, label: "Choose…", fill: hovered == .chooseFolder ? PanelTheme.neutral700 : PanelTheme.neutral800, color: PanelTheme.neutral100)
        hits.add(chooseR, .chooseFolder)
        if reset {
            let resetR = CanvasRect(x: chooseR.maxX + 6, y: y, width: resetW, height: Self.rowH)
            PanelDraw.smallButton(c, resetR, label: "Reset", fill: hovered == .resetFolder ? PanelTheme.neutral700 : PanelTheme.neutral800, color: PanelTheme.neutral100)
            hits.add(resetR, .resetFolder)
        }
        noteLine("For projects outside a library; library projects use the library's folder.")

        dropdown.draw(c)
    }

    // MARK: Input (window coordinates). While open the card is modal: it takes every press, move, wheel and key.

    /// True when the press was taken (always while open; a press outside the card closes it).
    public func pointerDown(_ p: CanvasPoint) -> Bool {
        guard isOpen else { return false }
        if dropdown.isOpen { _ = dropdown.pointerDown(p); return true }
        guard let hit = hits.hit(p) else { close(); return true }
        switch hit {
        case .close: close()
        case .appearance(let a): if a != values.appearance { values.appearance = a; onChange?(values) }
        case .audio:
            let options = [PanelDropdown.Option(value: "", label: "System default")] + devices.map { .init(value: $0.id, label: $0.name) }
            openDropdown(.audio, options, values.audioDevice ?? "") { [weak self] v in
                guard let self else { return }
                let device: String? = v.isEmpty ? nil : v
                if device != self.values.audioDevice { self.values.audioDevice = device; self.onChange?(self.values) }
            }
        case .cache:
            let options = Self.cacheChoicesMB.map { PanelDropdown.Option(value: $0.map(String.init) ?? "", label: Self.cacheLabel($0)) }
            openDropdown(.cache, options, values.previewCacheMB.map(String.init) ?? "") { [weak self] v in
                guard let self else { return }
                let mb = Int(v)
                if mb != self.values.previewCacheMB { self.values.previewCacheMB = mb; self.onChange?(self.values) }
            }
        case .chooseFolder: onChooseExportFolder?()
        case .resetFolder: values.exportFolder = nil; onChange?(values)
        case .card: break
        }
        return true
    }

    private func openDropdown(_ hit: Hit, _ options: [PanelDropdown.Option], _ selected: String, _ pick: @escaping (String) -> Void) {
        guard let anchor = hits.rect(where: { $0 == hit }) else { return }
        dropdown.open(key: "\(hit)", options: options, selected: selected, anchor: anchor,
                      bounds: CanvasRect(x: 0, y: 0, width: size.width, height: size.height), onPick: pick)
    }

    /// The host picked a folder for "Choose…".
    public func exportFolderChosen(_ path: String) {
        guard path != values.exportFolder else { return }
        values.exportFolder = path; onChange?(values)
    }

    /// True when hover changed (redraw).
    public func pointerMove(_ p: CanvasPoint) -> Bool {
        guard isOpen else { return false }
        if dropdown.isOpen { return dropdown.pointerMove(p) }
        let h = hits.hit(p).flatMap { $0 == .card ? nil : $0 }
        guard h != hovered else { return false }
        hovered = h; return true
    }

    public func scroll(dy: Double) -> Bool {
        guard isOpen else { return false }
        if dropdown.isOpen { dropdown.scrollBy(dy) }
        return true
    }

    /// Escape closes the open list, then the card. Command shortcuts (save, quit, Cmd/Ctrl+, to close) pass through.
    public func keyDown(_ k: EditorKey) -> Bool {
        guard isOpen else { return false }
        if dropdown.isOpen { _ = dropdown.key(k); return true }   // arrows, Enter, Escape closes the list
        if case .escape = k.code { close(); return true }
        return !k.command
    }
}
