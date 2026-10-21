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
// Audition on the media bin: a play button on a lit audio or video tile, Space on the selected tile, a thin progress
// bar on the tile that plays (a click seeks), ← / → move 5 s and Esc stops. The panel only draws and asks; the host
// owns the player (`AssetAuditionPlayer`) and fills `audition` and `auditionErrors` every frame.
import Foundation
import MpvfxCanvas
import MpvfxTimeline

/// Where the auditioned file is, for the tile's progress bar.
public struct AuditionTileState: Equatable {
    public var assetId: String
    public var position: Double
    public var duration: Double
    public init(assetId: String, position: Double, duration: Double) { self.assetId = assetId; self.position = position; self.duration = duration }
    var fraction: Double { duration > 0 ? max(0, min(1, position / duration)) : 0 }
}

extension LeftSidebarPanel {
    /// Seconds a ← / → press moves an audition (the same as `AssetAuditionPlayer.seekStep`).
    static let auditionStep = 5.0
    static let auditionBarHeight = 3.0

    /// Audio and video project files have a sound to audition; pictures, fonts, library files and exports do not.
    func canAudition(_ ref: MediaTileRef) -> Bool {
        guard case .media(let id) = ref, let item = mediaItem(id) else { return false }
        return item.category == .audio || item.category == .video
    }

    /// True while a file plays: the host keeps the panel redrawing for the progress bar.
    public var isAuditioning: Bool { audition != nil }

    func isAuditioned(_ ref: MediaTileRef) -> Bool {
        if case .media(let id) = ref { return audition?.assetId == id }
        return false
    }

    /// Start or stop the audition of `ref`; a failure shown on the tile is cleared by the new try.
    func toggleAudition(_ ref: MediaTileRef) {
        guard canAudition(ref), case .media(let id) = ref else { return }
        auditionErrors[id] = nil
        onAuditionToggle?(id)
    }

    // MARK: Draw

    func drawGridAudition(_ c: CanvasContext, _ ref: MediaTileRef, _ thumb: CanvasRect, lit: Bool, clip: CanvasRect) {
        guard canAudition(ref), case .media(let id) = ref else { return }
        let playing = isAuditioned(ref)
        if let message = auditionErrors[id] { drawAuditionError(c, message, in: thumb) }
        guard lit || playing else { return }
        let b = CanvasRect(x: thumb.x + M.badgeInset, y: thumb.maxY - M.badgeInset - M.tileAction - (playing ? Self.auditionBarHeight : 0),
                           width: M.tileAction, height: M.tileAction)
        if playing, let state = audition {
            let bar = CanvasRect(x: thumb.x, y: thumb.maxY - Self.auditionBarHeight, width: thumb.width, height: Self.auditionBarHeight)
            drawAuditionBar(c, bar, state, round: PanelTheme.radiusMd)
            // The click target is a 24 pt strip right of the button (a thin bar alone is too small to hit); it seeks
            // along the whole bar's width.
            auditionBars[ref] = bar
            addClipped(CanvasRect(x: b.maxX + M.badgeInset, y: thumb.maxY - M.tileAction, width: max(0, thumb.maxX - b.maxX - M.badgeInset), height: M.tileAction),
                       .auditionBar(ref), to: clip)
        }
        drawTileAction(c, b, icon: playing ? .stop : .play, hot: hovered == .tileAudition(ref))
        addClipped(b, .tileAudition(ref), to: clip)
    }

    func drawRowAudition(_ c: CanvasContext, _ ref: MediaTileRef, _ r: CanvasRect, lit: Bool, hasAction: Bool, clip: CanvasRect) {
        guard canAudition(ref), case .media(let id) = ref else { return }
        let playing = isAuditioned(ref)
        if let message = auditionErrors[id] {
            let font = PanelTheme.font(10)
            PanelDraw.text(c, message, in: CanvasRect(x: r.x + 48, y: r.y + 25, width: max(0, r.width - 56), height: 16), font: font, color: PanelTheme.red400)
        }
        guard lit || playing else { return }
        let right = r.maxX - 4 - (hasAction ? M.tileAction + 4 : 0)
        let b = CanvasRect(x: right - M.tileAction, y: r.midY - M.tileAction / 2, width: M.tileAction, height: M.tileAction)
        if playing, let state = audition {
            let bar = CanvasRect(x: r.x + 6, y: r.maxY - 5, width: max(0, r.width - 12), height: Self.auditionBarHeight)
            drawAuditionBar(c, bar, state, round: 1.5)
            auditionBars[ref] = bar
            addClipped(CanvasRect(x: bar.x, y: r.maxY - M.tileAction, width: max(0, b.x - M.badgeInset - bar.x), height: M.tileAction), .auditionBar(ref), to: clip)
        }
        drawTileAction(c, b, icon: playing ? .stop : .play, hot: hovered == .tileAudition(ref))
        addClipped(b, .tileAudition(ref), to: clip)
    }

    func drawAuditionBar(_ c: CanvasContext, _ bar: CanvasRect, _ state: AuditionTileState, round: Double) {
        c.fillRoundedRect(bar, radius: min(round, bar.height / 2), PanelTheme.neutral950.withAlpha(0.75))
        let filled = CanvasRect(x: bar.x, y: bar.y, width: bar.width * state.fraction, height: bar.height)
        guard filled.width > 0 else { return }
        c.fillRoundedRect(filled, radius: min(round, bar.height / 2), PanelTheme.accent)
    }

    /// The failure over the picture: a dark wash and the message in the error colour, up to three lines.
    func drawAuditionError(_ c: CanvasContext, _ message: String, in thumb: CanvasRect) {
        c.fillRoundedRect(thumb, radius: PanelTheme.radiusMd, PanelTheme.neutral950.withAlpha(0.85))
        let font = PanelTheme.font(10)
        let wrapped = MediaTileText.lines(c, message, font: font, width: thumb.width - 12, maxLines: 4)
        for (i, line) in wrapped.lines.enumerated() {
            PanelDraw.text(c, line, in: CanvasRect(x: thumb.x + 6, y: thumb.y + 6 + Double(i) * 13, width: thumb.width - 12, height: 13), font: font, color: PanelTheme.red400)
        }
    }

    // MARK: Input

    /// A press on the play button or on the progress bar. Returns false for any other hit.
    func pressAudition(_ hit: Hit, at p: CanvasPoint) -> Bool {
        switch hit {
        case .tileAudition(let ref):
            selected = ref
            toggleAudition(ref)
            return true
        case .auditionBar(let ref):
            guard case .media(let id) = ref, let bar = auditionBars[ref], let state = audition, state.assetId == id else { return true }
            selected = ref
            let fraction = bar.width > 0 ? max(0, min(1, (p.x - bar.x) / bar.width)) : 0
            onAuditionSeek?(id, fraction * state.duration)
            return true
        default: return false
        }
    }

    /// Space on the selected tile, ← / → while a file plays, Esc to stop. Space on a focused header control and the
    /// arrows with nothing playing keep their other meanings.
    func keyAudition(_ k: EditorKey) -> Bool {
        let onHeaderControl: Bool = { if focus.visible, let cur = focus.current { return !isTile(cur) }; return false }()
        switch k.code {
        case .space:
            guard !onHeaderControl, !k.command, let ref = selected, canAudition(ref) else { return false }
            toggleAudition(ref)
            return true
        case .left, .right:
            guard audition != nil, !k.command, !k.shift else { return false }
            onAuditionSeekBy?(k.code == .left ? -Self.auditionStep : Self.auditionStep)
            return true
        case .escape:
            guard audition != nil || !auditionErrors.isEmpty else { return false }
            auditionErrors = [:]
            if audition != nil { onAuditionStop?() }
            return true
        default: return false
        }
    }
}
