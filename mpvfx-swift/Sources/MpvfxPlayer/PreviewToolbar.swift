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
import MpvfxPanels
import MpvfxTheme
import MpvfxTimeline

/// The preview tools bar above the stage: Record (when gesture recording is wired), Crop or
/// the crop Reset / Cancel / Apply group, the snap toggle (S) and the grid toggle (G) with its options popover
/// (Thirds / Quarters / Center, Snap to grid).
public final class PreviewToolbar {
    public static let height = 36.0          // h-9
    public static let paddingX = 8.0, gap = 4.0, iconButton = 28.0
    static var accent: CanvasColor { PanelStyle.accent }
    static var red500: CanvasColor { PanelTheme.red500 }
    /// Button wash: black/x on the dark bar; a faint ink tint on the light one.
    static func wash(_ a: Double) -> CanvasColor { Theme.mode == .light ? PanelTheme.white.withAlpha(a * 0.15) : CanvasColor(ThemeTokens.stageScrim.alpha(a)) }
    /// Glyph on the mint accent fill (black on bright mint, white on the light mode's dark mint).
    static var onAccent: CanvasColor { CanvasColor(ThemeTokens.onAccentMintPair.now) }

    public var snapEnabled = true
    public var gridVisible = false
    /// 2 (centre), 3 (thirds) or 4 (quarters).
    public var gridDivisions = 3
    public var snapToGrid = false
    public var gridPopoverOpen = false
    /// Record motion's state, shown only when the host handles `onToggleRecording`: off, armed (waiting for a
    /// press on the selected layer) or a take in progress.
    public enum Recording: Equatable { case idle, armed, recording }
    public var compareEnabled = false
    public var comparePosition = 0.5
    public var recording: Recording = .idle
    public var cropApplying = false
    public var hovered: Item?
    /// Fires after any preference changes (the host persists them).
    public var onPrefsChange: ((PreviewToolbar) -> Void)?
    public var onToggleRecording: (() -> Void)?

    public enum Item: Equatable {
        case record, crop, cropReset, cropCancel, cropApply, compare, snap, grid, gridOptions
        case gridPreset(Int), snapToGridToggle, popover, cropGroup
    }

    public init() {}

    static let label = CanvasFont(size: 11, weight: .medium), small = CanvasFont(size: 11), xs = CanvasFont(size: 12)
    static let presets: [(value: Int, label: String)] = [(3, "Thirds"), (4, "Quarters"), (2, "Center")]

    func textWidth(_ c: CanvasContext?, _ s: String, _ f: CanvasFont) -> Double {
        c?.measureText(s, font: f).width ?? Double(s.count) * f.size * 0.6
    }

    /// Layout of everything visible, right to left; `c` measures text (nil estimates).
    public func layout(width: Double, cropAvailable: Bool, cropActive: Bool, _ c: CanvasContext?) -> [(Item, CanvasRect)] {
        var out: [(Item, CanvasRect)] = []
        let midY = Self.height / 2
        var x = width - Self.paddingX
        func place(_ item: Item, _ w: Double, _ h: Double) { x -= w; out.append((item, CanvasRect(x: x, y: midY - h / 2, width: w, height: h))); x -= Self.gap }
        place(.grid, Self.iconButton, Self.iconButton)
        let g = out[0].1
        out.append((.gridOptions, CanvasRect(x: g.maxX + 2 - 11, y: g.maxY + 2 - 11, width: 11, height: 11)))
        place(.snap, Self.iconButton, Self.iconButton)
        place(.compare, textWidth(c, "Compare", Self.label) + 16, 28.5)
        if cropActive {
            let apply = cropApplying ? "Applying…" : "Apply"
            let wApply = textWidth(c, apply, CanvasFont(size: 11, weight: .semibold)) + 16
            let wCancel = textWidth(c, "Cancel", Self.small) + 16, wReset = textWidth(c, "Reset", Self.small) + 16
            let inner = 24.5, groupW = 4 + wReset + 4 + wCancel + 4 + wApply + 4 + 2, groupH = inner + 8 + 2
            x -= groupW
            let gx = x, gy = midY - groupH / 2
            out.append((.cropGroup, CanvasRect(x: gx, y: gy, width: groupW, height: groupH)))
            var bx = gx + 1 + 4
            for (item, w) in [(Item.cropReset, wReset), (.cropCancel, wCancel), (.cropApply, wApply)] {
                out.append((item, CanvasRect(x: bx, y: gy + 1 + 4, width: w, height: inner))); bx += w + 4
            }
            x -= Self.gap
        } else if cropAvailable && !cropApplying {
            place(.crop, textWidth(c, "Crop", Self.label) + 16, 28.5)
        }
        if onToggleRecording != nil { out.append((.record, recordRect(c))) }
        if gridPopoverOpen, let r = popoverRect(width: width, c) {
            out.append((.popover, r))
            let rows = presetRects(r, c)
            for (i, p) in Self.presets.enumerated() { out.append((.gridPreset(p.value), rows[i])) }
            out.append((.snapToGridToggle, CanvasRect(x: r.x + 12, y: rows[0].maxY + 8, width: r.width - 24, height: 18)))
        }
        return out
    }

    func gridRect(width: Double) -> CanvasRect {
        CanvasRect(x: width - Self.paddingX - Self.iconButton, y: (Self.height - Self.iconButton) / 2, width: Self.iconButton, height: Self.iconButton)
    }
    /// Popover under the grid button, right-aligned (right-0 top-full mt-1), p-3, min-w 180.
    public func popoverRect(width: Double, _ c: CanvasContext?) -> CanvasRect? {
        let g = gridRect(width: width)
        let rowW = Self.presets.reduce(0) { $0 + textWidth(c, $1.label, Self.small) + 16 } + 2 * 4
        let w = max(180, rowW + 24), h = 12 + 28.5 + 8 + 18 + 12 + 2
        return CanvasRect(x: g.maxX - w, y: g.maxY + 4, width: w, height: h)
    }
    func presetRects(_ r: CanvasRect, _ c: CanvasContext?) -> [CanvasRect] {
        var x = r.x + 1 + 12, out: [CanvasRect] = []
        for p in Self.presets { let w = textWidth(c, p.label, Self.small) + 16; out.append(CanvasRect(x: x, y: r.y + 1 + 12, width: w, height: 28.5)); x += w + 4 }
        return out
    }

    public func item(at p: CanvasPoint, width: Double, cropAvailable: Bool, cropActive: Bool, _ c: CanvasContext?) -> Item? {
        // Later entries (popover rows, the options chevron) sit on top of earlier ones.
        let items = layout(width: width, cropAvailable: cropAvailable, cropActive: cropActive, c)
        let hits = items.filter { $0.1.contains(p) }.map(\.0)
        if let row = hits.last(where: { if case .gridPreset = $0 { return true }; return $0 == .snapToGridToggle }) { return row }
        if hits.contains(.gridOptions) { return .gridOptions }
        if hits.contains(.popover) && gridPopoverOpen, let r = popoverRect(width: width, c), r.contains(p) { return .popover }
        return hits.first { $0 != .popover && $0 != .cropGroup }
    }

    /// Applies a click; returns the crop action the stage must run, if any.
    public enum CropCommand: Equatable { case start, reset, cancel, apply }
    @discardableResult
    public func press(_ item: Item) -> CropCommand? {
        switch item {
        case .snap: snapEnabled.toggle(); onPrefsChange?(self)
        case .grid: gridVisible.toggle(); onPrefsChange?(self)
        case .gridOptions: gridPopoverOpen.toggle()
        case .gridPreset(let v): gridDivisions = v; gridVisible = true; gridPopoverOpen = false; onPrefsChange?(self)
        case .snapToGridToggle: snapToGrid.toggle(); onPrefsChange?(self)
        case .record: onToggleRecording?()
        case .compare: compareEnabled.toggle()
        case .crop: return .start
        case .cropReset: return cropApplying ? nil : .reset
        case .cropCancel: return cropApplying ? nil : .cancel
        case .cropApply: return cropApplying ? nil : .apply
        case .popover, .cropGroup: break
        }
        return nil
    }

    /// S toggles snap, G toggles the grid, and backslash toggles Compare (unmodified keys).
    public func key(_ ch: Character) -> Bool {
        switch ch {
        case "s", "S": snapEnabled.toggle(); onPrefsChange?(self); return true
        case "g", "G": gridVisible.toggle(); onPrefsChange?(self); return true
        case "\\": compareEnabled.toggle(); return true
        default: return false
        }
    }

    // MARK: Drawing

    public func draw(_ c: CanvasContext, width: Double, cropAvailable: Bool, cropActive: Bool) {
        c.fillRect(CanvasRect(x: 0, y: 0, width: width, height: Self.height), PlayerView.viewportSurface)            // bg-neutral-950
        c.fillRect(CanvasRect(x: 0, y: Self.height - 1, width: width, height: 1), PanelStyle.neutral800.withAlpha(0.7))  // border-b
        let items = layout(width: width, cropAvailable: cropAvailable, cropActive: cropActive, c)
        func rect(_ i: Item) -> CanvasRect? { items.first { $0.0 == i }?.1 }
        let white = PanelTheme.white   // strongest ink (white dark, near-black light)

        for (i, on) in [(Item.snap, snapEnabled), (.grid, gridVisible)] {
            guard let r = rect(i) else { continue }
            let hov = hovered == i
            c.fillRoundedRect(r, radius: 6, on ? Self.accent.withAlpha(0.2) : Self.wash(hov ? 0.6 : 0.4))
            let color = on ? Self.accent : white.withAlpha(hov ? 0.8 : 0.6)
            let g = CanvasRect(x: r.x + 6, y: r.y + 6, width: 16, height: 16)
            let icon = i == .snap ? PlayerIcons.magnet(fill: on) : PlayerIcons.gridFour(fill: on)
            PlayerIcons.stroke(c, icon.stroke, in: g, box: 256, color: color, width: 16)
            PlayerIcons.fill(c, icon.fill, in: g, box: 256, color: color)
        }
        if let r = rect(.gridOptions) {   // the small chevron: rounded p-0.5 bg-black/50, white/50 (white/90 hover)
            c.fillRoundedRect(r, radius: 4, Self.wash(0.5))
            let col = white.withAlpha(hovered == .gridOptions ? 0.9 : 0.5)
            c.withState {
                c.translate(r.x + 2, r.y + 2); c.scale(7 / 8, 7 / 8)
                c.fill(PlayerIcons.poly([(1, 2.5), (4, 5.5), (7, 2.5)], close: true), col)
            }
        }
        if let r = rect(.crop) {
            let hov = hovered == .crop
            c.fillRoundedRect(r, radius: 6, Self.wash(hov ? 0.6 : 0.4))
            c.drawText("Crop", at: .init(r.x + 8, r.y + (r.height - 11) / 2), font: Self.label, color: white.withAlpha(hov ? 1 : 0.7))
        }
        if let r = rect(.compare) {
            let hov = hovered == .compare
            c.fillRoundedRect(r, radius: 6, compareEnabled ? Self.accent.withAlpha(0.2) : Self.wash(hov ? 0.6 : 0.4))
            c.drawText("Compare", at: .init(r.x + 8, r.y + (r.height - 11) / 2), font: Self.label,
                       color: compareEnabled ? Self.accent : white.withAlpha(hov ? 1 : 0.7))
        }
        if cropActive, let group = rect(.cropGroup) {
            c.fillRoundedRect(group, radius: 6, PanelTheme.black)
            c.strokeRoundedRect(group.insetBy(0.5), radius: 5.5, white.withAlpha(0.15), width: 1)
            let dim = cropApplying ? 0.4 : 1.0
            for (i, text, alpha) in [(Item.cropReset, "Reset", 0.65), (.cropCancel, "Cancel", 0.75)] {
                guard let r = rect(i) else { continue }
                let hov = hovered == i && !cropApplying
                if hov { c.fillRoundedRect(r, radius: 4, PanelStyle.neutral900) }
                c.drawText(text, at: .init(r.x + 8, r.y + (r.height - 11) / 2), font: Self.small, color: white.withAlpha((hov ? 1 : alpha) * dim))
            }
            if let r = rect(.cropApply) {
                c.fillRoundedRect(r, radius: 4, Self.accent.withAlpha(dim))
                c.drawText(cropApplying ? "Applying…" : "Apply", at: .init(r.x + 8, r.y + (r.height - 11) / 2),
                           font: CanvasFont(size: 11, weight: .semibold), color: Self.onAccent.withAlpha(dim))
            }
        }
        if let r = rect(.record) { drawRecord(c, r) }
        if gridPopoverOpen, let r = popoverRect(width: width, c) {
            c.fillRoundedRect(r, radius: 8, PanelStyle.neutral800)
            c.strokeRoundedRect(r.insetBy(0.5), radius: 7.5, PanelStyle.neutral700, width: 1)
            for (i, p) in Self.presets.enumerated() {
                let pr = presetRects(r, c)[i], on = gridDivisions == p.value, hov = hovered == .gridPreset(p.value)
                if on { c.fillRoundedRect(pr, radius: 4, white.withAlpha(0.15)) } else if hov { c.fillRoundedRect(pr, radius: 4, white.withAlpha(0.05)) }
                c.drawText(p.label, at: .init(pr.x + 8, pr.y + (pr.height - 11) / 2), font: Self.small, color: on ? white : white.withAlpha(0.6))
            }
            let rowY = presetRects(r, c)[0].maxY + 8
            let box = CanvasRect(x: r.x + 13, y: rowY + 2, width: 13, height: 13)
            if snapToGrid {
                c.fillRoundedRect(box, radius: 3, Self.accent)
                c.stroke(PlayerIcons.poly([(box.x + 3, box.y + 6.5), (box.x + 5.5, box.y + 9.5), (box.x + 10, box.y + 3.5)]), Self.onAccent, StrokeStyle(width: 1.75))
            } else {
                c.fillRoundedRect(box, radius: 3, PanelTheme.stageInk)
                c.strokeRoundedRect(box.insetBy(0.5), radius: 2.5, PanelStyle.neutral500, width: 1)
            }
            c.drawText("Snap to grid", at: .init(box.maxX + 8, rowY + 3), font: Self.xs, color: white.withAlpha(0.8))
        }
        if hovered == .record, let r = rect(.record) { drawRecordTip(c, r) }
    }
}

/// The stage's right-click menu: z-order actions with their glyphs, a divider and Delete.
public struct StageContextMenu: Equatable {
    public var origin: CanvasPoint
    public var targetIds: [String]
    /// Which z actions can move the target (an action that would change nothing is shown disabled).
    public var enabled: Set<StageZOrderAction>
    public var canDelete: Bool
    public var hovered: Int?
    public init(origin: CanvasPoint, targetIds: [String], enabled: Set<StageZOrderAction>, canDelete: Bool) {
        self.origin = origin; self.targetIds = targetIds; self.enabled = enabled; self.canDelete = canDelete
    }
    public enum Choice: Equatable { case z(StageZOrderAction), delete }
    static let rowHeight = 28.0, width = 180.0

    var rows: [Choice] { StageZOrderAction.allCases.map { .z($0) } + (canDelete ? [.delete] : []) }
    var height: Double { 4 + Double(StageZOrderAction.allCases.count) * Self.rowHeight + (canDelete ? 9 + Self.rowHeight : 0) + 4 + 2 }

    /// Clamped inside `bounds` like the original's adjusted position.
    public func frame(in bounds: CanvasRect) -> CanvasRect {
        CanvasRect(x: min(origin.x, bounds.maxX - Self.width - 4), y: min(origin.y, bounds.maxY - height - 4), width: Self.width, height: height)
    }
    func rowRect(_ i: Int, _ f: CanvasRect) -> CanvasRect {
        let zCount = StageZOrderAction.allCases.count
        let y = f.y + 1 + 4 + Double(i) * Self.rowHeight + (i >= zCount ? 9 : 0)
        return CanvasRect(x: f.x + 1, y: y, width: f.width - 2, height: Self.rowHeight)
    }
    public func choice(at p: CanvasPoint, bounds: CanvasRect) -> (inside: Bool, choice: Choice?) {
        let f = frame(in: bounds)
        guard f.contains(p) else { return (false, nil) }
        for (i, r) in rows.enumerated() where rowRect(i, f).contains(p) {
            if case .z(let a) = r, !enabled.contains(a) { return (true, nil) }
            return (true, r)
        }
        return (true, nil)
    }
    public func row(at p: CanvasPoint, bounds: CanvasRect) -> Int? {
        let f = frame(in: bounds)
        return rows.indices.first { rowRect($0, f).contains(p) }
    }

    /// bg-neutral-900 border-neutral-700 rounded-md py-1; rows px-3 py-1.5 text-xs, 16px glyph mr-2;
    /// enabled neutral-300 (hover bg-neutral-800), disabled neutral-600; Delete red-400 with a ⌫ hint.
    public func draw(_ c: CanvasContext, bounds: CanvasRect) {
        let f = frame(in: bounds)
        c.fillRoundedRect(f, radius: 6, PanelStyle.neutral900)
        c.strokeRoundedRect(f.insetBy(0.5), radius: 5.5, PanelStyle.neutral700, width: 1)
        let font = CanvasFont(size: 12)
        for (i, row) in rows.enumerated() {
            let r = rowRect(i, f)
            switch row {
            case .z(let a):
                let on = enabled.contains(a)
                if on && hovered == i { c.fillRect(r, PanelStyle.neutral800) }
                let color = on ? PanelStyle.neutral300 : PanelStyle.neutral600
                PlayerIcons.stroke(c, PlayerIcons.zOrder(a), in: CanvasRect(x: r.x + 12, y: r.y + 6, width: 16, height: 16), box: 16, color: color, width: 1.2)
                c.drawText(a.label, at: .init(r.x + 12 + 16 + 8, r.y + 8), font: font, color: color)
            case .delete:
                c.fillRect(CanvasRect(x: f.x + 1, y: r.y - 5, width: f.width - 2, height: 1), PanelStyle.neutral700.withAlpha(0.6))
                if hovered == i { c.fillRect(r, PanelStyle.neutral800) }
                c.drawText("Delete", at: .init(r.x + 12, r.y + 8), font: font, color: PanelTheme.red400)
                let hint = "⌫", hf = CanvasFont(size: 10)
                c.drawText(hint, at: .init(r.maxX - 12 - c.measureText(hint, font: hf).width, r.y + 9), font: hf, color: PanelStyle.neutral500)
            }
        }
    }
}
