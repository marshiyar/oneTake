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
/// `<userData>/preferences.json`: appearance, interface size, audio output device, preview cache size and the default export folder.
/// The host owns persistence: every change goes out through `onChange` with the new values, and "Choose…" asks the
/// host for a folder (`onChooseExportFolder`), which answers by setting `values.exportFolder`.
///
/// Keyboard (issue #104): the card opens with focus on its first control and the ring showing. Tab / ⇧Tab cycle
/// Appearance, Audio output, Preview cache, Choose…, Reset and Close without leaving the card; the appearance
/// segments are one stop, and Left / Right move to and apply the next one. Enter / Space press the focused control
/// (the lists open with the current choice highlighted, the arrows choose and Enter commits); Escape closes.
public final class SettingsPanel {
    public struct Values: Equatable {
        public var appearance: ThemeAppearance
        /// Audio output device id; nil is the system default.
        public var audioDevice: String?
        /// Preview frame cache in MB; nil is automatic.
        public var previewCacheMB: Int?
        /// Default export folder; nil is the app's renders folder.
        public var exportFolder: String?
        /// How much larger the whole editor draws, in percent (one of `interfaceSizeChoices`; 100 is normal).
        public var interfaceScalePercent: Int
        public init(appearance: ThemeAppearance = .system, audioDevice: String? = nil, previewCacheMB: Int? = nil, exportFolder: String? = nil,
                    interfaceScalePercent: Int = 100) {
            self.appearance = appearance; self.audioDevice = audioDevice; self.previewCacheMB = previewCacheMB; self.exportFolder = exportFolder
            self.interfaceScalePercent = interfaceScalePercent
        }
    }
    public struct Device: Equatable { public var id, name: String
        public init(id: String, name: String) { self.id = id; self.name = name } }
    public enum Hit: Hashable { case close, appearance(ThemeAppearance), interfaceSize, audio, cache, chooseFolder, resetFolder, card }

    /// The cache sizes offered (MB); nil is automatic.
    public static let cacheChoicesMB: [Int?] = [nil, 512, 1024, 2048, 4096, 8192]
    /// The interface sizes offered, in percent (issue #106; the same list as `DesktopPreferences.interfaceScaleChoices`).
    public static let interfaceSizeChoices = [100, 125, 150, 175, 200]
    public static func interfaceSizeLabel(_ percent: Int) -> String { "\(percent)%" }
    public static let width = 520.0

    public private(set) var isOpen = false
    public var values = Values()
    /// The devices the system offers (empty: only the system default can be chosen). Set by the host once it has asked.
    public var devices: [Device] = [] { didSet { devicesListed = true } }
    /// Whether `devices` has been filled since the card was created (until then a chosen device is not called missing).
    public private(set) var devicesListed = false
    /// Shown under the audio row when no output device can be chosen (no audio output, or `MPVFX_AUDIO_OUTPUT=null`).
    public var deviceChoiceUnavailable = false
    /// Why the last change could not be saved (shown in red at the bottom of the card); nil when it was saved.
    public var saveError: String?
    public var onChange: ((Values) -> Void)?
    public var onChooseExportFolder: (() -> Void)?
    /// Called when the card opens (the host refreshes `devices`).
    public var onOpen: (() -> Void)?
    public let dropdown = PanelDropdown()
    public private(set) var hits = HitMap<Hit>()
    public var hovered: Hit?
    /// Keyboard focus inside the card and its ring; cleared when the card closes.
    public var focus = PanelFocus<Hit>()
    private var size = CanvasSize(0, 0)

    public init() {}

    /// Opens the card with keyboard focus on its first control (the chosen appearance segment, read after `onOpen`
    /// has refreshed `values`), so a keyboard user can start at once.
    public func open() {
        guard !isOpen else { return }
        isOpen = true; hovered = nil
        onOpen?()
        focus = PanelFocus()
        focus.current = .appearance(values.appearance); focus.visible = true
    }
    public func close() { isOpen = false; dropdown.close(); hovered = nil; focus = PanelFocus() }
    public func toggle() { if isOpen { close() } else { open() } }

    public static func cacheLabel(_ mb: Int?) -> String {
        guard let mb else { return "Automatic" }
        return mb >= 1024 && mb % 1024 == 0 ? "\(mb / 1024) GB" : "\(mb) MB"
    }

    var audioLabel: String {
        guard let id = values.audioDevice else { return "System default" }
        return devices.first { $0.id == id }?.name ?? id
    }

    /// The chosen device is not among the ones the system offers now (unplugged): the default output plays meanwhile.
    var chosenDeviceMissing: Bool {
        guard devicesListed, let id = values.audioDevice else { return false }
        return !devices.contains { $0.id == id }
    }

    /// `path` as wide as fits: whole, or its last components after "…/" (the end says which folder it is).
    static func fitted(_ c: CanvasContext, _ path: String, font: CanvasFont, width: Double) -> String {
        guard c.measureText(path, font: font).width > width else { return path }
        var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        while parts.count > 1 {
            parts.removeFirst()
            let s = "…/" + parts.joined(separator: "/")
            if c.measureText(s, font: font).width <= width { return s }
        }
        return "…/" + (parts.first ?? path)
    }

    private static var title: CanvasFont { PanelTheme.font(13, .semibold) }
    private static var label: CanvasFont { PanelTheme.font(11, .medium) }
    private static var body: CanvasFont { PanelTheme.font(11) }
    private static var note: CanvasFont { PanelTheme.font(10) }
    static let rowH = 28.0, rowGap = 18.0, pad = 20.0, labelW = 132.0, header = 48.0
    /// Appearance, interface size, audio output, preview cache, export folder.
    static let rowCount = 5

    public func cardRect(in size: CanvasSize) -> CanvasRect {
        let h = Self.header + 12 + Double(Self.rowCount) * (Self.rowH + Self.rowGap) + (saveError == nil ? 0 : 20) + Self.pad - 6
        let w = min(Self.width, max(0, size.width - 32))
        return CanvasRect(x: ((size.width - w) / 2).rounded(), y: max(16, ((size.height - h) / 2).rounded()), width: w, height: h)
    }

    // MARK: Draw (window coordinates)

    /// One row's frame: the label column at `x`, the control column at `cx` (`cw` wide), the row's top at `y`.
    struct Row { var x, cx, cw, y: Double }

    /// The card is a popover surface over a scrim (docs/DESIGN.md: menus and popovers use `popover`); fields are
    /// `panelInput` with the field outline, raised controls `panelSurface`, and the accent marks the chosen appearance.
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
        PanelDraw.text(c, "Settings", in: CanvasRect(x: x, y: card.y + 14, width: w - 30, height: 20), font: Self.title, color: PanelTheme.text0)
        let closeR = CanvasRect(x: card.maxX - 12 - PanelTabStrip.buttonSize, y: card.y + 12, width: PanelTabStrip.buttonSize, height: PanelTabStrip.buttonSize)
        PanelTabStrip.iconButton(c, closeR, icon: .close, hovered: hovered == .close)
        PanelDraw.hline(c, x0: card.x + 1, x1: card.maxX - 1, y: card.y + Self.header, PanelTheme.panelBorderInput)

        var row = Row(x: x, cx: x + Self.labelW, cw: max(0, w - Self.labelW), y: card.y + Self.header + 12)
        for drawRow in [drawAppearance, drawInterfaceSize, drawAudio, drawCache, drawFolder] {
            drawRow(c, row)
            row.y += Self.rowH + Self.rowGap
        }
        if let saveError {
            PanelDraw.text(c, saveError, in: CanvasRect(x: x, y: row.y, width: w, height: 16), font: Self.note, color: PanelTheme.danger)
        }
        hits.add(closeR, .close)   // recorded after the rows, so Tab reaches Close last
        if let ring = focus.ringRect(hits), let focused = focus.current {
            PanelDraw.focusRing(c, ring, radius: Self.ringRadius(focused))
        }
        dropdown.draw(c)
    }

    private func rowLabel(_ c: CanvasContext, _ r: Row, _ s: String) {
        PanelDraw.text(c, s, in: CanvasRect(x: r.x, y: r.y, width: Self.labelW - 8, height: Self.rowH), font: Self.label, color: PanelTheme.text1)
    }

    private func noteLine(_ c: CanvasContext, _ r: Row, _ s: String) {
        PanelDraw.text(c, s, in: CanvasRect(x: r.cx, y: r.y + Self.rowH + 2, width: r.cw, height: 14), font: Self.note, color: PanelTheme.text3)
    }

    private func field(_ c: CanvasContext, _ r: CanvasRect) {
        c.fillRoundedRect(r, radius: PanelTheme.radiusMd, PanelTheme.panelInput)
        c.strokeRoundedRect(r.insetBy(0.5), radius: PanelTheme.radiusMd - 0.5, PanelTheme.panelBorderInput, width: 1)
    }

    private func button(_ c: CanvasContext, _ r: CanvasRect, _ text: String, _ hit: Hit) {
        PanelDraw.smallButton(c, r, label: text, fill: hovered == hit ? PanelTheme.panelHover : PanelTheme.panelSurface, color: PanelTheme.text1)
        hits.add(r, hit)
    }

    /// System / Light / Dark as a segmented control.
    private func drawAppearance(_ c: CanvasContext, _ row: Row) {
        rowLabel(c, row, "Appearance")
        let seg = CanvasRect(x: row.cx, y: row.y, width: row.cw, height: Self.rowH)
        c.fillRoundedRect(seg, radius: PanelTheme.radiusMd, PanelTheme.panelSurface)
        let segW = seg.width / Double(ThemeAppearance.allCases.count)
        for (i, a) in ThemeAppearance.allCases.enumerated() {
            let r = CanvasRect(x: seg.x + Double(i) * segW, y: seg.y, width: segW, height: seg.height)
            let inner = r.insetBy(2), on = a == values.appearance, hov = hovered == .appearance(a)
            if on { c.fillRoundedRect(inner, radius: PanelTheme.radius, PanelTheme.accent) }
            else if hov { c.fillRoundedRect(inner, radius: PanelTheme.radius, PanelTheme.panelHover) }
            PanelDraw.text(c, a.label, in: inner, font: Self.body, color: on ? PanelTheme.onAccent : (hov ? PanelTheme.text0 : PanelTheme.text2), align: .center)
            hits.add(r, .appearance(a))
        }
    }

    /// 100–200 %: every panel, the timeline and the status line draw that much larger.
    private func drawInterfaceSize(_ c: CanvasContext, _ row: Row) {
        rowLabel(c, row, "Interface size")
        let r = CanvasRect(x: row.cx, y: row.y, width: row.cw, height: Self.rowH)
        field(c, r)
        PanelSelect.draw(c, r.insetBy(1), text: Self.interfaceSizeLabel(values.interfaceScalePercent), hovered: hovered == .interfaceSize)
        hits.add(r, .interfaceSize)
        noteLine(c, row, "Enlarges every panel, the timeline and the status line.")
    }

    private func drawAudio(_ c: CanvasContext, _ row: Row) {
        rowLabel(c, row, "Audio output")
        let r = CanvasRect(x: row.cx, y: row.y, width: row.cw, height: Self.rowH)
        let enabled = !devices.isEmpty || values.audioDevice != nil
        field(c, r)
        PanelSelect.draw(c, r.insetBy(1), text: audioLabel, hovered: hovered == .audio, disabled: !enabled)
        if enabled { hits.add(r, .audio) }
        if deviceChoiceUnavailable { noteLine(c, row, "No audio output to choose from in this session.") }
        else if chosenDeviceMissing { noteLine(c, row, "Not connected: the system default plays until it is back.") }
        else { noteLine(c, row, "Takes effect at once, also while playing.") }
    }

    private func drawCache(_ c: CanvasContext, _ row: Row) {
        rowLabel(c, row, "Preview cache")
        let r = CanvasRect(x: row.cx, y: row.y, width: row.cw, height: Self.rowH)
        field(c, r)
        PanelSelect.draw(c, r.insetBy(1), text: Self.cacheLabel(values.previewCacheMB), hovered: hovered == .cache)
        hits.add(r, .cache)
        noteLine(c, row, "Memory for decoded preview frames.")
    }

    /// The folder (its end kept when long), Choose… and, once one is chosen, Reset.
    private func drawFolder(_ c: CanvasContext, _ row: Row) {
        rowLabel(c, row, "Export folder")
        let reset = values.exportFolder != nil
        let chooseW = 70.0, resetW = reset ? 56.0 : 0
        let r = CanvasRect(x: row.cx, y: row.y, width: max(0, row.cw - chooseW - 6 - (reset ? resetW + 6 : 0)), height: Self.rowH)
        field(c, r)
        let textW = max(0, r.width - 16)
        let text = values.exportFolder.map { Self.fitted(c, $0, font: Self.body, width: textW) } ?? "App renders folder"
        PanelDraw.text(c, text, in: CanvasRect(x: r.x + 8, y: r.y, width: textW, height: r.height),
                       font: Self.body, color: values.exportFolder == nil ? PanelTheme.text3 : PanelTheme.text1)
        let chooseR = CanvasRect(x: r.maxX + 6, y: row.y, width: chooseW, height: Self.rowH)
        button(c, chooseR, "Choose…", .chooseFolder)
        if reset { button(c, CanvasRect(x: chooseR.maxX + 6, y: row.y, width: resetW, height: Self.rowH), "Reset", .resetFolder) }
        noteLine(c, row, "For projects outside a library; library projects use their library's folder.")
    }

    // MARK: Input (window coordinates). While open the card is modal: it takes every press, move, wheel and key.

    /// True when the press was taken (always while open; a press outside the card closes it). A press hides the
    /// focus ring and moves focus to the control pressed, so Tab goes on from there.
    public func pointerDown(_ p: CanvasPoint) -> Bool {
        guard isOpen else { return false }
        focus.pointerPressed()
        if dropdown.isOpen { _ = dropdown.pointerDown(p); return true }
        guard let hit = hits.hit(p) else { close(); return true }
        if hit != .card { focus.current = hit }
        act(hit)
        return true
    }

    /// What a press on `hit` does, by pointer or by Enter / Space on the focused control.
    private func act(_ hit: Hit) {
        switch hit {
        case .close: close()
        case .appearance(let segment): focus.current = .appearance(segment); change(\.appearance, segment)
        case .interfaceSize: openInterfaceSizeList()
        case .audio: openAudioList()
        case .cache: openCacheList()
        case .chooseFolder: onChooseExportFolder?()
        case .resetFolder:   // Reset goes away once used; focus stays on the row, on Choose…
            focus.current = .chooseFolder; change(\.exportFolder, nil)
        case .card: break
        }
    }

    /// Sets one value and reports the new values, when it changed.
    private func change<T: Equatable>(_ key: WritableKeyPath<Values, T>, _ value: T) {
        guard values[keyPath: key] != value else { return }
        values[keyPath: key] = value
        onChange?(values)
    }

    private func openAudioList() {
        // Options are spelled out (not `.init`) so complexity tools read these closures as closures.
        let options = [PanelDropdown.Option(value: "", label: "System default")]
            + devices.map { PanelDropdown.Option(value: $0.id, label: $0.name) }
        openDropdown(.audio, options, values.audioDevice ?? "") { [weak self] v in
            self?.change(\.audioDevice, v.isEmpty ? nil : v)
        }
    }

    private func openInterfaceSizeList() {
        let options = Self.interfaceSizeChoices.map { PanelDropdown.Option(value: String($0), label: Self.interfaceSizeLabel($0)) }
        openDropdown(.interfaceSize, options, String(values.interfaceScalePercent)) { [weak self] v in
            guard let percent = Int(v) else { return }
            self?.change(\.interfaceScalePercent, percent)
        }
    }

    private func openCacheList() {
        let options = Self.cacheChoicesMB.map { choice in
            PanelDropdown.Option(value: choice.map { String($0) } ?? "", label: Self.cacheLabel(choice))
        }
        openDropdown(.cache, options, values.previewCacheMB.map { String($0) } ?? "") { [weak self] v in
            self?.change(\.previewCacheMB, Int(v))
        }
    }

    private func openDropdown(_ hit: Hit, _ options: [PanelDropdown.Option], _ selected: String, _ pick: @escaping (String) -> Void) {
        guard let anchor = hits.rect(where: { $0 == hit }) else { return }
        dropdown.open(key: "\(hit)", options: options, selected: selected, anchor: anchor,
                      bounds: CanvasRect(x: 0, y: 0, width: size.width, height: size.height), onPick: pick)
    }

    /// The host picked a folder for "Choose…".
    public func exportFolderChosen(_ path: String) {
        change(\.exportFolder, path)
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

    /// Escape closes the open list, then the card. Command shortcuts (save, quit, Cmd/Ctrl+, to close) pass through;
    /// every other key stays with the card, which is modal.
    public func keyDown(_ k: EditorKey) -> Bool {
        guard isOpen else { return false }
        if dropdown.isOpen { return listKey(k) }
        if case .escape = k.code { close(); return true }
        if k.command { return false }
        cardKey(k)
        return true
    }

    /// An open list takes the arrows, Enter (commit) and Escape (close the list) through `PanelDropdown.key`. A
    /// command shortcut closes it and goes on to the editor and menus (Cmd/Ctrl+, closes the card).
    /// Tab / ⇧Tab close the list without choosing and move the card's focus on, as from a native list.
    private func listKey(_ key: EditorKey) -> Bool {
        if key.command { dropdown.close(); return false }
        if key.code == .tab { dropdown.close(); moveFocus(forward: !key.shift); return true }
        if key.isRepeat, key.code == .enter { return true }   // the Enter that opened the list, still held
        _ = dropdown.key(key)
        return true
    }

    private func cardKey(_ key: EditorKey) {
        switch key.code {
        case .tab: moveFocus(forward: !key.shift)
        case .left: stepAppearance(by: -1)
        case .right: stepAppearance(by: 1)
        case .enter, .space: if !key.isRepeat { pressFocused() }   // a held key presses once; arrows repeat
        default: break
        }
    }

    /// What Tab stops on: every control, the appearance segments as one stop (the chosen one).
    static func focusable(_ hit: Hit, appearance: ThemeAppearance) -> Bool {
        switch hit {
        case .card: false
        case .appearance(let segment): segment == appearance
        default: true
        }
    }

    /// The ring follows the control's corners: segments and Close are `radius`, fields and buttons `radiusMd`.
    static func ringRadius(_ hit: Hit) -> Double {
        switch hit {
        case .appearance, .close: PanelTheme.radius
        default: PanelTheme.radiusMd
        }
    }

    /// Tab / ⇧Tab inside the modal card: past the last control focus comes round to the first, and back.
    private func moveFocus(forward: Bool) {
        let appearance = values.appearance
        let focusable = { (hit: Hit) -> Bool in SettingsPanel.focusable(hit, appearance: appearance) }
        if !focus.move(hits, forward: forward, focusable) { focus.move(hits, forward: forward, focusable) }
    }

    /// Left / Right on the appearance control move to the neighbouring segment and apply it. The ends hold (Left on
    /// System stays on System) rather than wrap, so a held arrow never flips the window from Dark back to System.
    private func stepAppearance(by step: Int) {
        guard case .appearance(let current)? = focus.current else { return }
        let choices = ThemeAppearance.allCases
        guard let index = choices.firstIndex(of: current) else { return }
        focus.visible = true
        act(.appearance(choices[min(max(index + step, 0), choices.count - 1)]))
    }

    /// Enter / Space press the focused control while its ring shows; a list opened this way starts on the current
    /// choice, as a native list opened from the keyboard does.
    private func pressFocused() {
        guard focus.visible, let focused = focus.current else { return }
        act(focused)
        if dropdown.isOpen { dropdown.highlightSelected() }
    }
}
