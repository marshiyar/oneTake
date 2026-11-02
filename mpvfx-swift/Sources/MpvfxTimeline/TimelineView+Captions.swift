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
// The caption lane (docs/TIMELINE.md "Caption lane"): the sequence's caption track drawn as a band under the last track,
// one block per cue at its time with its text, a handle on each end to trim it, and a text field to retype it. The lane
// only exists while the project has a caption track. Gestures and key handling are in TimelineController+Captions.swift.
import Foundation
import MpvfxCanvas
import MpvfxShared
import MpvfxTheme

/// The modal text field that retypes a cue; cancelling never touches the document.
public struct TimelineCueEdit: Equatable, Sendable {
    public var cueId: String, draft: String
    public var selectedAll = true
    public var cursor: Int
    public var rect: CanvasRect
    /// Why the draft cannot be saved (shown under the field), nil while it can.
    public var problem: String?
    public var confirmRect: CanvasRect { CanvasRect(x: rect.maxX - 90, y: rect.maxY - 34, width: 78, height: 24) }
    public var cancelRect: CanvasRect { CanvasRect(x: rect.maxX - 180, y: rect.maxY - 34, width: 78, height: 24) }
}

/// What the view holds for the caption lane: the cues to draw, the selected cue, the live drag result and the text field.
public struct TimelineCaptionLane: Equatable, Sendable {
    /// The project has a caption track (even with no cues): the lane is drawn and takes presses.
    public var isShown = false
    public var cues: [NativeCaptionCue] = []
    public var selectedCueId: String?
    /// The cue a move or trim is dragging, as it would land (clamped); drawn in place of the stored cue until release.
    public var preview: NativeCaptionCue?
    public var edit: TimelineCueEdit?

    /// Takes the cues of the editor's document, keeping the selection only while its cue exists.
    mutating func load(from editor: TimelineEditor) {
        isShown = editor.document.sequence.captions != nil
        cues = editor.captionCues
        let ids = Set(cues.map(\.id))
        if let id = selectedCueId, !ids.contains(id) { selectedCueId = nil }
        if let id = preview?.id, !ids.contains(id) { preview = nil }
        if let id = edit?.cueId, !ids.contains(id) { edit = nil }
        if !isShown { selectedCueId = nil; preview = nil; edit = nil }
    }
}

extension TimelineLayout {
    /// Width of the trim handle at each end of a cue block.
    public static let captionHandleWidth = 8.0
}

extension TimelineView {
    /// Content-space frame of the caption lane, or nil when the project has no caption track.
    var captionLaneFrame: TimelineBandFrame? { bandFrames().first { $0.band == .captions } }

    /// The cues as drawn: the dragged cue at its preview position.
    var displayedCaptionCues: [NativeCaptionCue] {
        guard let preview = captions.preview else { return captions.cues }
        return captions.cues.map { $0.id == preview.id ? preview : $0 }
    }

    /// View rectangle of a cue's block (at least 2 px wide so a short cue stays visible), or nil without the lane.
    func captionCueRect(_ cue: NativeCaptionCue) -> CanvasRect? {
        guard let f = captionLaneFrame else { return nil }
        let left = x(for: Double(cue.startMs) / 1000), right = x(for: Double(cue.endMs) / 1000)
        return CanvasRect(x: left, y: f.top - scrollY + 3, width: max(right - left, 2), height: f.height - 6)
    }

    /// The "+" in the lane's label column that adds a cue at the playhead.
    var captionAddButtonRect: CanvasRect? {
        guard let f = captionLaneFrame else { return nil }
        return CanvasRect(x: TimelineLayout.labelColumnWidth - 36, y: f.top - scrollY + 4, width: 24, height: f.height - 8)
    }

    /// The cue under a view point, and the end it is on when the point is inside a trim handle.
    func captionCueHit(x px: Double, y py: Double) -> (id: String, edge: NativeCaptionEdge?)? {
        guard px >= TimelineLayout.contentOrigin else { return nil }
        for cue in displayedCaptionCues.reversed() {
            guard let r = captionCueRect(cue), px >= r.x, px <= r.maxX, py >= r.y, py <= r.maxY else { continue }
            let w = min(TimelineLayout.captionHandleWidth, r.width / 3)
            return (cue.id, px <= r.x + w ? .start : px >= r.maxX - w ? .end : nil)
        }
        return nil
    }

    func drawCaptionLane(_ c: CanvasContext, size: CanvasSize) {
        typealias L = TimelineLayout
        guard captions.isShown, let f = captionLaneFrame else { return }
        let top = f.top - scrollY
        c.fillRect(CanvasRect(x: 0, y: top, width: size.width, height: f.height), theme.rowBackground)
        c.fillRect(CanvasRect(x: 0, y: top + f.height - 1, width: size.width, height: 1), theme.rowBorder)
        let font = CanvasFont(family: Self.uiFontFamily, size: 11, weight: .medium)
        c.withState {
            c.clip(CanvasRect(x: L.contentOrigin, y: max(top, L.rulerHeight), width: max(0, size.width - L.contentOrigin), height: f.height))
            for cue in displayedCaptionCues {
                guard let r = captionCueRect(cue), r.maxX >= L.contentOrigin, r.x <= size.width else { continue }
                let selected = captions.selectedCueId == cue.id
                c.fillRoundedRect(r, radius: theme.clipRadius, theme.accent.withAlpha(selected ? 0.34 : 0.2))
                c.strokeRoundedRect(r.insetBy(0.5), radius: theme.clipRadius, theme.accent.withAlpha(selected ? 0.95 : 0.45), width: 1)
                if selected {
                    let w = min(L.captionHandleWidth, r.width / 3)
                    c.fillRect(CanvasRect(x: r.x, y: r.y, width: w, height: r.height), theme.accent.withAlpha(0.5))
                    c.fillRect(CanvasRect(x: r.maxX - w, y: r.y, width: w, height: r.height), theme.accent.withAlpha(0.5))
                }
                let label = cue.text.replacingOccurrences(of: "\n", with: " ")
                if let shown = Self.ellipsize(c, label, font: font, maxWidth: r.width - 12) {
                    c.drawText(shown, at: .init(r.x + 6, r.y + (r.height - 12) / 2), font: font, color: theme.textPrimary)
                }
            }
        }
        c.fillRect(CanvasRect(x: 0, y: top, width: L.labelColumnWidth, height: f.height), theme.gutterBackground)
        c.fillRect(CanvasRect(x: L.labelColumnWidth - 1, y: top, width: 1, height: f.height), theme.gutterBorder)
        c.fillRect(CanvasRect(x: 0, y: top + f.height - 1, width: L.labelColumnWidth, height: 1), theme.rowBorder)
        c.drawText("Captions", at: .init(22, top + (f.height - 12) / 2), font: font, color: theme.textSecondary)
        if let add = captionAddButtonRect {
            c.fillRoundedRect(add, radius: 3, theme.accent.withAlpha(0.15))
            c.drawText("+", at: .init(add.x + 8, add.y + (add.height - 12) / 2), font: font, color: theme.textPrimary)
        }
    }

    func drawCueEdit(_ c: CanvasContext) {
        guard let edit = captions.edit else { return }
        let r = edit.rect, font = CanvasFont(family: Self.uiFontFamily, size: 12)
        // The field is one line: a line break shows as ⏎, one character for one, so the cursor index stays the same.
        let shown = edit.draft.replacingOccurrences(of: "\n", with: "⏎")
        c.fillRoundedRect(r, radius: 6, theme.rowBackground)
        c.strokeRoundedRect(r.insetBy(0.5), radius: 6, theme.accent, width: 1)
        c.drawText("Edit caption (⇧Enter adds a line)", at: .init(r.x + 12, r.y + 10), font: font, color: theme.textPrimary)
        let field = CanvasRect(x: r.x + 12, y: r.y + 32, width: r.width - 24, height: 28)
        c.fillRoundedRect(field, radius: 3, CanvasColor(ThemeTokens.neutral900))
        c.strokeRoundedRect(field.insetBy(0.5), radius: 3, theme.accent, width: 1)
        c.withState {
            c.clip(field.insetBy(4))
            let cursorX = field.x + 6 + c.measureText(String(shown.prefix(edit.cursor)), font: font).width
            if edit.selectedAll {
                c.fillRect(CanvasRect(x: field.x + 5, y: field.y + 4, width: c.measureText(shown, font: font).width + 2, height: 20),
                           theme.accent.withAlpha(0.3))
            }
            c.drawText(shown, at: .init(field.x + 6, field.y + 7), font: font, color: CanvasColor(ThemeTokens.white))
            if !edit.selectedAll { c.fillRect(CanvasRect(x: cursorX, y: field.y + 5, width: 1, height: 18), theme.accent) }
        }
        if let problem = edit.problem {
            c.drawText(problem, at: .init(r.x + 12, r.y + 66), font: CanvasFont(family: Self.uiFontFamily, size: 11), color: theme.textSecondary)
        }
        for (rect, title) in [(edit.cancelRect, "Cancel"), (edit.confirmRect, "Save")] {
            c.fillRoundedRect(rect, radius: 3, theme.accent.withAlpha(0.15))
            c.drawText(title, at: .init(rect.x + 10, rect.y + 6), font: font, color: theme.textPrimary)
        }
    }
}
