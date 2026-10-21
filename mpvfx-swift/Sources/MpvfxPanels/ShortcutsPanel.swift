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

public struct ShortcutHint: Equatable, Sendable { public let key: String, label: String }
public struct ShortcutSection: Equatable, Sendable { public let title: String; public let hints: [ShortcutHint] }

/// SHORTCUT_SECTIONS, plus "⌥ Drag clip" (the clip swap on drop).
public let shortcutSections: [ShortcutSection] = {
    func s(_ t: String, _ h: [(String, String)]) -> ShortcutSection { ShortcutSection(title: t, hints: h.map { ShortcutHint(key: $0.0, label: $0.1) }) }
    return [
        s("Playback", [("Space", "Play / Pause"), ("J", "Play backward"), ("K", "Stop"), ("L", "Play forward"), ("M", "Toggle mute"),
                       ("⇧L", "Toggle loop"), ("←/→", "Step 1 frame"), ("⇧←/⇧→", "Step 10 frames"), ("F", "Toggle fullscreen")]),
        s("Keyframes (when an element is selected)", [("K", "Add keyframe at playhead"), ("Del", "Delete selected keyframe"),
                       (", / .", "Move selected keyframes 1 frame"), ("⇧, / ⇧.", "Move selected keyframes 10 frames"),
                       ("H", "Toggle hold / bezier"), ("U", "Expand / collapse properties"), ("R", "Arm Record motion")]),
        s("Editing", [("⌘C", "Copy element"), ("⌘V", "Paste element"), ("⌥⌘C", "Copy grade"), ("⌥⌘V", "Paste grade"), ("⌘X", "Cut element"), ("S", "Split clip at playhead"),
                      ("Shift + click/drag", "Selection tool: add clips to selection"), ("⌥ Drag clip", "Drop without swapping"), ("⇧Click", "Razor tool: split all tracks"),
                      ("⌘G", "Group elements"), ("⌘⇧G", "Ungroup"), ("Del", "Delete selected element (no keyframe selected)")]),
        s("Gesture recording modifiers", [("Drag", "Record x / y position"), ("Scroll", "Record z depth"), ("⇧ Drag", "Record rotationX / rotationY"),
                                          ("⌥ Drag", "Record rotation"), ("⌘ Drag↕", "Record opacity"), ("⌘ Scroll", "Record scale")]),
        s("Canvas", [("\\", "Toggle before / after compare"), ("Drag", "Move element / add keyframe"), ("⌥ Drag", "Move entire animation path"), ("⇧ Drag", "Uniform resize")]),
        s("Crop", [("Drag edge", "Crop a side"), ("Drag center", "Reposition the crop")]),
        s("Panels", [("⌘1", "Compositions tab"), ("⌘2", "Assets tab")]),
        s("Work area", [("I", "Set in-point"), ("⇧I", "Clear in-point"), ("O", "Set out-point"), ("⇧O", "Clear out-point"),
                        ("A", "Jump to in-point"), ("E", "Jump to out-point")]),
    ]
}()

/// formatTime: MM:SS.
public func formatPanelTime(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "00:00" }
    let m = Int(t / 60), s = Int(t.truncatingRemainder(dividingBy: 60))
    return String(format: "%02d:%02d", m, s)
}

public func historyShortcutLabel(_ redo: Bool, mac: Bool) -> String {
    let m = mac ? "Cmd" : "Ctrl"; return redo ? "\(m)+Shift+Z" : "\(m)+Z"
}

/// The shortcuts panel: keyboard-icon trigger and a non-modal 220px-wide card (max 280px tall, scrolls)
/// with History, Jump to frame, Work area and the shortcut reference.
public final class ShortcutsPanel {
    public struct History: Equatable { public var canUndo, canRedo: Bool; public var undoLabel, redoLabel: String?
        public init(canUndo: Bool, canRedo: Bool, undoLabel: String? = nil, redoLabel: String? = nil) {
            self.canUndo = canUndo; self.canRedo = canRedo; self.undoLabel = undoLabel; self.redoLabel = redoLabel } }
    public enum Hit: Hashable { case trigger, undo, redo, jumpField, go, clearIn, clearOut, appearance(ThemeAppearance), body, outside }

    public static let width = 220.0, maxHeight = 280.0, gap = 8.0, triggerSize = 28.0

    public var isOpen = false
    public var disabled = false
    public var duration = 0.0
    public var fps = 30.0
    public var inPoint: Double?
    public var outPoint: Double?
    public var history: History?
    public var mac = false
    public var jumpText = ""
    public var jumpFocused = false
    public var hovered: Hit?
    public var scroll = 0.0
    public var onSeek: ((Double) -> Void)?
    public var onUndo: (() -> Void)?
    public var onRedo: (() -> Void)?
    public var onClearIn: (() -> Void)?
    public var onClearOut: (() -> Void)?
    /// The appearance setting (dark or light). Nil hides the Appearance row.
    public var appearance: ThemeAppearance?
    public var onAppearance: ((ThemeAppearance) -> Void)?
    /// Viewport height available above the trigger (CSS calc(100vh - 80px)).
    public var viewportHeight = 10_000.0

    public init() {}

    // MARK: Layout (content coordinates, y from the top of the card)
    struct Layout { var height = 0.0; var regions: [(Hit, CanvasRect)] = []; var draws: [(CanvasContext, CanvasRect) -> Void] = [] }

    private static let sectionTitle = CanvasFont(size: 9, weight: .medium)
    private static let small = CanvasFont(size: 10)
    private static let mono10 = CanvasFont.mono(10)
    private static let mono9 = CanvasFont.mono(9)

    func layout(_ c: CanvasContext) -> Layout {
        var L = Layout(); var y = 0.0; let w = Self.width
        func title(_ t: String, _ top: Double) {
            let yy = top
            L.draws.append { c, o in c.drawText(t.uppercased(), at: .init(o.x + 12, o.y + yy), font: Self.sectionTitle, color: PanelStyle.neutral500) }
        }
        func divider() { let yy = y; L.draws.append { c, o in c.fillRect(CanvasRect(x: o.x, y: o.y + yy, width: w, height: 1), PanelStyle.divider) }; y += 1 }
        if let current = appearance {   // Appearance: System / Light / Dark segmented row
            y += 12; title("Appearance", y); y += 13.5 + 6
            let seg = CanvasRect(x: 12, y: y, width: w - 24, height: 24)
            let cw = seg.width / Double(ThemeAppearance.allCases.count)
            for (i, a) in ThemeAppearance.allCases.enumerated() {
                L.regions.append((.appearance(a), CanvasRect(x: seg.x + Double(i) * cw, y: seg.y, width: cw, height: seg.height)))
            }
            L.draws.append { [unowned self] c, o in
                let r = CanvasRect(x: o.x + seg.x, y: o.y + seg.y, width: seg.width, height: seg.height)
                c.fillRoundedRect(r, radius: 4, PanelStyle.neutral900)
                c.strokeRoundedRect(r.insetBy(0.5), radius: 3.5, PanelStyle.neutral700, width: 1)
                for (i, a) in ThemeAppearance.allCases.enumerated() {
                    let cr = CanvasRect(x: r.x + Double(i) * cw, y: r.y, width: cw, height: r.height).insetBy(2)
                    let on = a == current, hov = self.hovered == .appearance(a)
                    if on { c.fillRoundedRect(cr, radius: 3, PanelStyle.neutral700) } else if hov { c.fillRoundedRect(cr, radius: 3, PanelStyle.neutral800) }
                    let s = c.measureText(a.label, font: Self.small)
                    c.drawText(a.label, at: .init(cr.x + (cr.width - s.width) / 2, cr.y + (cr.height - s.height) / 2), font: Self.small,
                               color: on ? PanelStyle.neutral50 : (hov ? PanelStyle.neutral200 : PanelStyle.neutral400))
                }
            }
            y += 24 + 10; divider()
        }
        if let h = history {
            y += 12; title("History", y); y += 13.5 + 6
            for (redo, enabled, label) in [(false, h.canUndo, "Undo" + (h.undoLabel.map { " \($0)" } ?? "")),
                                          (true, h.canRedo, "Redo" + (h.redoLabel.map { " \($0)" } ?? ""))] {
                let r = CanvasRect(x: 12, y: y, width: w - 24, height: 27); let hit: Hit = redo ? .redo : .undo
                L.regions.append((hit, r))
                let sc = historyShortcutLabel(redo, mac: mac)
                L.draws.append { [unowned self] c, o in
                    let rr = CanvasRect(x: o.x + r.x, y: o.y + r.y, width: r.width, height: r.height)
                    if enabled && self.hovered == hit { c.fillRoundedRect(rr, radius: 4, PanelStyle.neutral800) }
                    c.drawText(label, at: .init(rr.x + 8, rr.y + 7), font: Self.small, color: enabled ? PanelStyle.neutral300 : PanelStyle.neutral600)
                    let s = c.measureText(sc, font: Self.mono9)
                    c.drawText(sc, at: .init(rr.maxX - 8 - s.width, rr.y + 8), font: Self.mono9, color: PanelStyle.neutral500)
                }
                y += 27 + (redo ? 0 : 4)
            }
            y += 10; divider()
        }
        // Jump to frame
        y += 12; title("Jump to frame", y); y += 13.5 + 6
        let goW = 30.0
        let field = CanvasRect(x: 12, y: y, width: w - 24 - goW - 6, height: 24), go = CanvasRect(x: w - 12 - goW, y: y, width: goW, height: 24)
        L.regions.append((.jumpField, field)); L.regions.append((.go, go))
        L.draws.append { [unowned self] c, o in
            let f = CanvasRect(x: o.x + field.x, y: o.y + field.y, width: field.width, height: field.height)
            c.fillRoundedRect(f, radius: 4, PanelStyle.neutral900)
            c.strokeRoundedRect(f.insetBy(0.5), radius: 3.5, self.jumpFocused ? PanelStyle.accent.withAlpha(0.6) : PanelStyle.neutral700, width: 1)
            let empty = self.jumpText.isEmpty
            c.drawText(empty ? "frame number" : self.jumpText, at: .init(f.x + 8, f.y + 6), font: Self.mono10,
                       color: empty ? PanelStyle.neutral600 : PanelStyle.neutral200)
            if self.jumpFocused {
                let tw = empty ? 0 : c.measureText(self.jumpText, font: Self.mono10).width
                c.fillRect(CanvasRect(x: f.x + 8 + tw, y: f.y + 5, width: 1, height: 14), PanelStyle.neutral200)
            }
            let g = CanvasRect(x: o.x + go.x, y: o.y + go.y, width: go.width, height: go.height)
            if self.hovered == .go && !self.disabled { c.fillRoundedRect(g, radius: 4, PanelStyle.neutral800) }
            c.strokeRoundedRect(g.insetBy(0.5), radius: 3.5, self.hovered == .go ? PanelStyle.neutral500 : PanelStyle.neutral700, width: 1)
            let s = c.measureText("Go", font: Self.small)
            c.drawText("Go", at: .init(g.x + (g.width - s.width) / 2, g.y + 6), font: Self.small,
                       color: PanelStyle.neutral300.withAlpha(self.disabled ? 0.4 : 1))
        }
        y += 24 + 10; divider()
        // Work area
        y += 10; title("Work area", y); y += 13.5 + 6
        for (isOut, letter, label) in [(false, "I", "In-point"), (true, "O", "Out-point")] {
            let rowY = y; let hit: Hit = isOut ? .clearOut : .clearIn
            let clear = CanvasRect(x: w - 12 - 16, y: rowY + 2, width: 16, height: 16)
            L.regions.append((hit, clear))
            L.draws.append { [unowned self] c, o in
                Self.chip(c, letter, at: .init(o.x + 12, o.y + rowY), minWidth: 20)
                c.drawText(label, at: .init(o.x + 12 + 20 + 8 + (letter == "O" ? 0 : 0), o.y + rowY + 5), font: Self.small, color: PanelStyle.neutral400)
                let value = isOut ? self.outPoint : self.inPoint
                if let v = value {
                    let t = formatPanelTime(v); let s = c.measureText(t, font: Self.mono10)
                    let cr = CanvasRect(x: o.x + clear.x, y: o.y + clear.y, width: 16, height: 16)
                    c.drawText(t, at: .init(cr.x - 6 - s.width, o.y + rowY + 5), font: Self.mono10, color: PanelStyle.neutral300)
                    let col = self.hovered == hit ? PanelStyle.neutral200 : PanelStyle.neutral500
                    var x = CanvasPath(); let m = 8.0 * 12 / 24, cx = cr.x + 8, cy = cr.y + 8
                    x.move(to: .init(cx - m / 2 + 0.0, cy - m / 2)); x.line(to: .init(cx + m / 2, cy + m / 2))
                    x.move(to: .init(cx + m / 2, cy - m / 2)); x.line(to: .init(cx - m / 2, cy + m / 2))
                    c.stroke(x, col, StrokeStyle(width: 2.5 * 8 / 24))
                } else {
                    let s = c.measureText("—", font: Self.small)
                    c.drawText("—", at: .init(o.x + w - 12 - s.width, o.y + rowY + 5), font: Self.small, color: PanelStyle.neutral600)
                }
            }
            y += 20 + (isOut ? 0 : 4)
        }
        y += 8; divider()
        // Reference
        y += 10
        for (si, sec) in shortcutSections.enumerated() {
            if si > 0 { y += 12 }
            title(sec.title, y); y += 13.5 + 6
            for (hi, h) in sec.hints.enumerated() {
                let rowY = y
                L.draws.append { c, o in
                    let cw = Self.chip(c, h.key, at: .init(o.x + 12, o.y + rowY), minWidth: 36)
                    c.drawText(h.label, at: .init(o.x + 12 + cw + 12, o.y + rowY + 5), font: Self.small, color: PanelStyle.neutral400)
                }
                y += 20 + (hi == sec.hints.count - 1 ? 0 : 4)
            }
        }
        y += 12
        L.height = y
        return L
    }

    /// font-mono 10px rounded border chip (px-1.5 py-0.5); returns its width.
    @discardableResult
    static func chip(_ c: CanvasContext, _ text: String, at p: CanvasPoint, minWidth: Double) -> Double {
        let s = c.measureText(text, font: mono10)
        let w = max(minWidth, s.width + 12)
        let r = CanvasRect(x: p.x, y: p.y, width: w, height: 20)
        c.fillRoundedRect(r, radius: 4, PanelStyle.chipBackground)
        c.strokeRoundedRect(r.insetBy(0.5), radius: 3.5, PanelStyle.neutral700, width: 1)
        c.drawText(text, at: .init(r.x + (w - s.width) / 2, r.y + (20 - s.height) / 2), font: mono10, color: PanelStyle.neutral300)
        return w
    }

    public func cardRect(_ c: CanvasContext, trigger: CanvasRect) -> CanvasRect {
        let h = min(layout(c).height, Self.maxHeight, max(0, viewportHeight - 80))
        return PanelStyle.anchorAbove(trigger: trigger, size: CanvasSize(Self.width, h), gap: Self.gap)
    }

    public func maxScroll(_ c: CanvasContext, trigger: CanvasRect) -> Double { max(0, layout(c).height - cardRect(c, trigger: trigger).height) }

    public func hitTest(_ c: CanvasContext, _ p: CanvasPoint, trigger: CanvasRect) -> Hit {
        if trigger.contains(p) { return .trigger }
        guard isOpen else { return .outside }
        let card = cardRect(c, trigger: trigger)
        guard card.contains(p) else { return .outside }
        let local = CanvasPoint(p.x - card.x, p.y - card.y + scroll)
        for (h, r) in layout(c).regions where r.contains(local) { return h }
        return .body
    }

    @discardableResult
    public func pointerDown(_ c: CanvasContext, _ p: CanvasPoint, trigger: CanvasRect) -> Bool {
        let hit = hitTest(c, p, trigger: trigger)
        jumpFocused = hit == .jumpField
        switch hit {
        case .trigger: isOpen.toggle(); if !isOpen { jumpFocused = false }
        case .undo: if history?.canUndo == true { onUndo?() }
        case .redo: if history?.canRedo == true { onRedo?() }
        case .go: commitJump()
        case .clearIn: if inPoint != nil { inPoint = nil; onClearIn?() }
        case .clearOut: if outPoint != nil { outPoint = nil; onClearOut?() }
        case .appearance(let a): if appearance != a { appearance = a; onAppearance?(a) }
        case .jumpField, .body: break
        case .outside: if isOpen { isOpen = false; return true }; return false
        }
        return true
    }

    public func pointerMove(_ c: CanvasContext, _ p: CanvasPoint, trigger: CanvasRect) { hovered = hitTest(c, p, trigger: trigger) }

    public func scrollBy(_ c: CanvasContext, _ dy: Double, trigger: CanvasRect) {
        scroll = min(maxScroll(c, trigger: trigger), max(0, scroll + dy))
    }

    /// commitJumpFrame: parseInt, clamp to [0, duration].
    public func commitJump() {
        guard !disabled, duration > 0 else { return }
        let digits = jumpText.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber || $0 == "-" }
        guard let frame = Int(digits) else { return }
        onSeek?(min(duration, Double(max(0, frame)) / fps))
    }

    /// Text entry for the focused jump field. Returns true if consumed.
    public func key(_ name: String, text: String?) -> Bool {
        guard isOpen else { return false }
        if name == "Escape" { isOpen = false; jumpFocused = false; return true }
        guard jumpFocused, !disabled else { return false }
        switch name {
        case "Return", "Enter", "KP_Enter": commitJump()
        case "BackSpace": if !jumpText.isEmpty { jumpText.removeLast() }
        default:
            guard let t = text, !t.isEmpty else { return false }
            jumpText += t
        }
        return true
    }

    public func draw(_ c: CanvasContext, trigger: CanvasRect) {
        // Trigger: 11px keyboard glyph, stroke 1.75.
        let col = isOpen ? PanelStyle.neutral200 : (hovered == .trigger ? PanelStyle.neutral300 : PanelStyle.neutral600)
        let s = 11.0 / 24, cx = trigger.x + trigger.width / 2, cy = trigger.y + trigger.height / 2
        func P(_ x: Double, _ y: Double) -> CanvasPoint { .init(cx + (x - 12) * s, cy + (y - 12) * s) }
        let st = StrokeStyle(width: 1.75 * s)
        c.stroke(.roundedRect(CanvasRect(x: P(2, 4).x, y: P(2, 4).y, width: 20 * s, height: 16 * s), radius: 2 * s), col, st)
        for (x, y) in [(6.0, 8.0), (10, 8), (14, 8), (18, 8), (6, 12), (10, 12), (14, 12), (18, 12)] {
            c.fillRect(CanvasRect(x: P(x, y).x - 0.5, y: P(x, y).y - 0.5, width: 1, height: 1), col)
        }
        var bar = CanvasPath(); bar.move(to: P(8, 16)); bar.line(to: P(16, 16)); c.stroke(bar, col, st)
        guard isOpen else { return }
        let L = layout(c)
        let card = cardRect(c, trigger: trigger)
        scroll = min(scroll, max(0, L.height - card.height))
        PanelStyle.drawPopover(c, card)
        c.withState {
            c.clip(.roundedRect(card.insetBy(1), radius: 7))
            let origin = CanvasRect(x: card.x, y: card.y - scroll, width: card.width, height: L.height)
            for d in L.draws { d(c, origin) }
            if L.height > card.height {   // overlay scrollbar
                let th = card.height * card.height / L.height
                let ty = card.y + (card.height - th) * scroll / (L.height - card.height)
                c.fillRoundedRect(CanvasRect(x: card.maxX - 5, y: ty + 2, width: 3, height: th - 4), radius: 1.5, PanelStyle.neutral600.withAlpha(0.6))
            }
        }
    }
}
