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

/// The panels' glyphs, drawn from recorded vector geometry: inline path data (sidebar
/// toggles, import plus, upload, select caret) stroked with round caps and joins, and the Phosphor outlines
/// the icon names map to (X, Eye, Stack, FilmStrip, MusicNote, TextT,
/// ArrowCounterClockwise, Trash, CaretRight…).
public enum PanelIcon: Equatable, Sendable {
    /// `M5 4v16 / m10 7 5 5-5 5` (show left sidebar / hide right sidebar).
    case sidebarShowLeft
    /// `m14 7-5 5 5 5 / M19 4v16` (hide left sidebar / show right sidebar).
    case sidebarHideLeft
    /// The native `<details>` disclosure triangle (closed / open).
    case caretRight, caretDown
    /// FlatGroupHeader carets (12-unit view box, filled): closed `M4 2l4 4-4 4z`, open `M2 4l4 4 4-4z`.
    case groupCaretRight, groupCaretDown
    /// Native `<select>` chevron.
    case selectCaret
    case close, eye, eyeOff, layers, film, image, music, text, font, reset, trash, plus, upload, download, help, spinnerArc, diamond, diamondFilled
    case chevronLeft, chevronRight, check, keyframeNav
    /// Audition: play and stop on a tile.
    case play, stop
    /// Three dots in a row: a panel's menu button (the end of its tab strip).
    case panelMenu
    /// A funnel: the Media panel's filter button.
    case filter
    /// Any Phosphor glyph by name.
    case phosphor(PhosphorIcon)
}

public extension PanelIcon {
    /// Draws the icon fitted into `rect` (square box, centered). `lineWidth` is in 24-unit view-box units for
    /// the stroked markup icons (the SVG `strokeWidth`); Phosphor glyphs are filled outlines and ignore it.
    func draw(_ c: CanvasContext, in rect: CanvasRect, color: CanvasColor, lineWidth: Double = 1.5) {
        let side = min(rect.width, rect.height)
        let box = CanvasRect(x: rect.x + (rect.width - side) / 2, y: rect.y + (rect.height - side) / 2, width: side, height: side)
        func stroke(_ d: [String], _ w: Double = lineWidth) { c.strokeSVG(d, viewBox: 24, in: box, color, width: w) }
        func fill(_ d: [String], _ vb: Double = 24) { c.fillSVG(d, viewBox: vb, in: box, color) }
        switch self {
        case .sidebarShowLeft: stroke(["M5 4v16", "m10 7 5 5-5 5"])
        case .sidebarHideLeft: stroke(["m14 7-5 5 5 5", "M19 4v16"])
        // Chromium's disclosure marker: a solid triangle ~0.6em, the em box being the 12px summary text.
        case .caretRight: fill(["M1 4.2 L11 10 L1 15.8 Z"], 20)
        case .caretDown: fill(["M0.4 5 L11.6 5 L6 14.6 Z"], 20)
        case .groupCaretRight: fill(["M4 2l4 4-4 4z"], 12)
        case .groupCaretDown: fill(["M2 4l4 4 4-4z"], 12)
        case .selectCaret: stroke(["m6 9 6 6 6-6"], 2)
        case .play: fill(["M7 4.5 L19.5 12 L7 19.5 Z"])
        case .stop: fill(["M6.5 6.5 H17.5 V17.5 H6.5 Z"])
        case .chevronLeft: stroke(["m15 18-6-6 6-6"])
        case .chevronRight: stroke(["m9 18 6-6-6-6"])
        case .check: PhosphorIcon.check.draw(c, in: box, color: color)
        case .close: PhosphorIcon.x.draw(c, in: box, color: color)
        case .eye: PhosphorIcon.eyeBold.draw(c, in: box, color: color)
        case .eyeOff: PhosphorIcon.eyeSlashBold.draw(c, in: box, color: color)
        case .layers: PhosphorIcon.stack.draw(c, in: box, color: color)
        case .film: PhosphorIcon.filmStrip.draw(c, in: box, color: color)
        case .image: stroke(["M3 6a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z", "M3 17l6-5 4 3 3-3 5 4",
                             "M8.5 8a1.5 1.5 0 1 0 0 3 1.5 1.5 0 1 0 0-3Z"])
        case .music: PhosphorIcon.musicNote.draw(c, in: box, color: color)
        case .text, .font: PhosphorIcon.textT.draw(c, in: box, color: color)
        case .reset: PhosphorIcon.arrowCounterClockwise.draw(c, in: box, color: color)
        case .trash: PhosphorIcon.trash.draw(c, in: box, color: color)
        // MediaImportControl's inline plus (`M12 5v14M5 12h14`, strokeWidth 2.5 at the call site).
        case .plus: stroke(["M12 5v14M5 12h14"])
        // AssetsTab EmptyState upload glyph.
        case .upload: stroke(["M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4", "M17 8 12 3 7 8", "M12 3v12"])
        case .download: stroke(["M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4", "M7 10 12 15 17 10", "M12 15V3"])   // RenderQueueItem download
        case .help: stroke(["M22 12a10 10 0 1 1-20 0a10 10 0 1 1 20 0", "M9.09 9a3 3 0 015.83 1c0 2-3 3-3 3", "M12 17h.01"])   // FormatInfoTooltip
        case .spinnerArc: stroke(["M12 2a10 10 0 0 1 10 10"])
        case .diamond: stroke(["M12 4 20 12 12 20 4 12Z"])
        case .diamondFilled, .keyframeNav: fill(["M12 4 20 12 12 20 4 12Z"])
        case .panelMenu: fill(["M4 12a2 2 0 1 0 4 0a2 2 0 1 0-4 0Z", "M10 12a2 2 0 1 0 4 0a2 2 0 1 0-4 0Z", "M16 12a2 2 0 1 0 4 0a2 2 0 1 0-4 0Z"])
        case .filter: stroke(["M4 5h16l-6 7v6l-4 2v-8Z"])
        case .phosphor(let p): p.draw(c, in: box, color: color)
        }
    }
}
