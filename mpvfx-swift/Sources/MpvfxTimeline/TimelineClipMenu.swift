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

/// Drawn clip context menu.
public struct TimelineClipMenu: Equatable, Sendable {
    public enum Action: String, Sendable {
        case split, cut, copy, paste, copyGrade, pasteGrade, duplicate, thumbnails, mute, keepPitch, detachAudio, reattachAudio, delete
    }
    public struct Item: Equatable, Sendable {
        public var action: Action; public var label: String; public var hint: String?
        public var enabled = true; public var checked: Bool?; public var destructive = false
    }
    public enum Entry: Equatable, Sendable { case item(Item), divider }

    public static let width = 200.0, itemHeight = 28.0, dividerHeight = 9.0, padY = 4.0
    public var x: Double, y: Double, clipId: String
    public var entries: [Entry]
    public var hovered: Action?

    public var height: Double {
        var h: Double = 2.0 * Self.padY + 2.0
        for e in entries { if case .divider = e { h += Self.dividerHeight } else { h += Self.itemHeight } }
        return h
    }
    public var rect: CanvasRect { CanvasRect(x: x, y: y, width: Self.width, height: height) }

    public func itemRects() -> [(Item, CanvasRect)] {
        var cy = y + 1 + Self.padY; var out: [(Item, CanvasRect)] = []
        for e in entries {
            switch e {
            case .divider: cy += Self.dividerHeight
            case .item(let it):
                out.append((it, CanvasRect(x: x + 1, y: cy, width: Self.width - 2, height: Self.itemHeight))); cy += Self.itemHeight
            }
        }
        return out
    }
    public func item(atX px: Double, y py: Double) -> Item? {
        itemRects().first { px >= $0.1.x && px <= $0.1.maxX && py >= $0.1.y && py < $0.1.maxY }?.0
    }

    /// Entries for a clip of `kind`: split, the clipboard group, thumbnails, mute and pitch, the audio link, delete.
    /// `keepsPitch` is the clip's pitch option, nil for a clip without sound (no row).
    public static func entries(kind: TimelineClipKind, splitEnabled: Bool, thumbnails: Bool, muted: Bool,
                               canReattach: Bool, canDetach: Bool, canMute: Bool = true,
                               canPaste: Bool = false, canPasteGrade: Bool = false, gradePasteReason: String? = nil,
                               keepsPitch: Bool? = nil) -> [Entry] {
        var e: [Entry] = []
        let hasSplit = kind == .video || kind == .audio || kind == .image
        if hasSplit { e.append(.item(Item(action: .split, label: "Split", hint: "S", enabled: splitEnabled))); e.append(.divider) }
        e.append(.item(Item(action: .cut, label: "Cut", hint: "⌘X")))
        e.append(.item(Item(action: .copy, label: "Copy", hint: "⌘C")))
        e.append(.item(Item(action: .paste, label: "Paste", hint: "⌘V", enabled: canPaste)))
        if kind == .video || kind == .image {
            e.append(.item(Item(action: .copyGrade, label: "Copy grade", hint: "⌥⌘C")))
            e.append(.item(Item(action: .pasteGrade, label: "Paste grade", hint: canPasteGrade ? "⌥⌘V" : gradePasteReason, enabled: canPasteGrade)))
        }
        e.append(.item(Item(action: .duplicate, label: "Duplicate", hint: "⌘D")))
        e.append(.divider)
        if kind == .video || kind == .image {
            e.append(.item(Item(action: .thumbnails, label: "Show thumbnails", checked: thumbnails)))
            e.append(.divider)
        }
        if (kind == .video || kind == .audio) && canMute {
            e.append(.item(Item(action: .mute, label: muted ? "Unmute" : "Mute", checked: muted)))
        }
        if let keepsPitch { e.append(.item(Item(action: .keepPitch, label: "Keep audio pitch", checked: keepsPitch))) }
        if e.last != .divider { e.append(.divider) }
        if canReattach { e.append(.item(Item(action: .reattachAudio, label: "Reattach audio"))); e.append(.divider) }
        else if canDetach { e.append(.item(Item(action: .detachAudio, label: "Detach audio"))); e.append(.divider) }
        e.append(.item(Item(action: .delete, label: "Delete", hint: "⌫", destructive: true)))
        return e
    }
}

extension TimelineView {
    /// One drawn menu row (nil entries are dividers).
    struct MenuRow { var label: String, hint: String?, enabled: Bool, checked: Bool, destructive: Bool, hovered: Bool }

    func drawClipMenu(_ c: CanvasContext, _ m: TimelineClipMenu) {
        let rows: [MenuRow?] = m.entries.map {
            guard case .item(let it) = $0 else { return nil }
            return MenuRow(label: it.label, hint: it.hint, enabled: it.enabled, checked: it.checked == true,
                           destructive: it.destructive, hovered: m.hovered == it.action)
        }
        drawMenu(c, m.rect, rows)
    }

    /// The clip menu's look, shared by the timeline's drawn menus.
    func drawMenu(_ c: CanvasContext, _ r: CanvasRect, _ rows: [MenuRow?]) {
        c.fillRoundedRect(r, radius: 6, CanvasColor(ThemeTokens.neutral900))
        c.strokeRoundedRect(r.insetBy(0.5), radius: 6, CanvasColor(ThemeTokens.neutral700), width: 1)
        let f = CanvasFont(family: Self.uiFontFamily, size: 12)
        var cy = r.y + 1 + TimelineClipMenu.padY
        for row in rows {
            guard let it = row else {
                // Dividers: my-1 border-t neutral-700/60.
                c.fillRect(CanvasRect(x: r.x + 1, y: cy + 4, width: r.width - 2, height: 1), CanvasColor(ThemeTokens.neutral700.alpha(0.6)))
                cy += TimelineClipMenu.dividerHeight
                continue
            }
            let ir = CanvasRect(x: r.x + 1, y: cy, width: r.width - 2, height: TimelineClipMenu.itemHeight)
            cy += TimelineClipMenu.itemHeight
            if it.hovered && it.enabled { c.fillRect(ir, CanvasColor(ThemeTokens.neutral800)) }
            var color = CanvasColor(it.destructive ? ThemeTokens.red400 : ThemeTokens.neutral300)
            if !it.enabled { color = color.withAlpha(0.4) }
            c.drawText(it.label, at: .init(ir.x + 12, ir.y + 7), font: f, color: color)
            if it.checked {
                c.drawText("✓", at: .init(ir.maxX - 24, ir.y + 7), font: f, color: theme.accent)
            } else if let h = it.hint {
                let hf = CanvasFont(family: Self.uiFontFamily, size: 10)
                let w = c.measureText(h, font: hf).width
                c.drawText(h, at: .init(ir.maxX - 12 - w, ir.y + 8), font: hf, color: CanvasColor(ThemeTokens.neutral500.alpha(it.enabled ? 1 : 0.4)))
            }
        }
    }
}
