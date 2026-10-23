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

/// Modal timeline-local name editor; cancelling never touches the document.
public struct TimelineClipRename: Equatable, Sendable {
    public var clipId: String, draft: String
    public var selectedAll = true
    public var cursor: Int
    public var rect: CanvasRect
    public var confirmRect: CanvasRect { CanvasRect(x: rect.maxX - 90, y: rect.maxY - 34, width: 78, height: 24) }
    public var cancelRect: CanvasRect { CanvasRect(x: rect.maxX - 180, y: rect.maxY - 34, width: 78, height: 24) }
}

public extension TimelineController {
    @discardableResult func requestRenameSelection() -> Bool {
        guard view.selection.count == 1, let id = view.selection.first else { return false }
        return requestRenameClip(id)
    }

    @discardableResult func requestRenameClip(_ id: String) -> Bool {
        guard let editor, !editor.isClipLocked(id), let (_, clip) = editor.clip(id) else { return false }
        let label = clip.name ?? editor.document.assets.first { $0.id == clip.assetId }?.name ?? clip.assetId
        let width = max(220, min(340, viewport.width - 16))
        view.clipMenu = nil
        view.selection = [id]
        view.clipRename = TimelineClipRename(clipId: id, draft: label, cursor: label.count,
            rect: CanvasRect(x: max(8, (viewport.width - width) / 2), y: 12, width: width, height: 116))
        needsDisplay?()
        return true
    }

    @discardableResult func commitClipRename() -> Bool {
        guard let rename = view.clipRename else { return false }
        view.clipRename = nil
        let changed = editor?.renameClip(rename.clipId, name: rename.draft) ?? false
        needsDisplay?()
        return changed
    }

    /// All keys stay in the modal. Arrows/Home/End move the insertion point; Ctrl/Cmd+A selects the name.
    @discardableResult func renameClipKey(_ key: EditorKey) -> Bool {
        guard var rename = view.clipRename else { return false }
        defer { needsDisplay?() }
        switch key.code {
        case .escape: view.clipRename = nil; return true
        case .enter: _ = commitClipRename(); return true
        case .char(let ch) where key.command && ch.lowercased() == "a":
            rename.selectedAll = true
        case .left:
            rename.cursor = rename.selectedAll ? 0 : max(0, rename.cursor - 1); rename.selectedAll = false
        case .right:
            rename.cursor = rename.selectedAll ? rename.draft.count : min(rename.draft.count, rename.cursor + 1); rename.selectedAll = false
        case .home: rename.cursor = 0; rename.selectedAll = false
        case .end: rename.cursor = rename.draft.count; rename.selectedAll = false
        case .backspace, .delete:
            var chars = Array(rename.draft)
            if rename.selectedAll { chars = []; rename.cursor = 0 }
            else if key.code == .backspace, rename.cursor > 0 { chars.remove(at: rename.cursor - 1); rename.cursor -= 1 }
            else if key.code == .delete, rename.cursor < chars.count { chars.remove(at: rename.cursor) }
            rename.draft = String(chars); rename.selectedAll = false
        case .char(let ch) where !key.command && !key.alt:
            insertRenameText(String(ch), into: &rename)
        case .space where !key.command && !key.alt:
            insertRenameText(" ", into: &rename)
        default: break
        }
        view.clipRename = rename
        return true
    }

    internal func insertRenameText(_ text: String, into rename: inout TimelineClipRename) {
        var chars = rename.selectedAll ? [] : Array(rename.draft)
        if rename.selectedAll { rename.cursor = 0 }
        chars.insert(contentsOf: text, at: rename.cursor)
        rename.cursor += text.count
        rename.draft = String(chars); rename.selectedAll = false
    }

    internal func renameClipPointerDown(x: Double, y: Double) {
        guard let rename = view.clipRename else { return }
        if rename.confirmRect.contains(x: x, y: y) { _ = commitClipRename() }
        else if rename.cancelRect.contains(x: x, y: y) || !rename.rect.contains(x: x, y: y) {
            view.clipRename = nil; needsDisplay?()
        }
    }
}

extension TimelineView {
    func drawClipRename(_ c: CanvasContext, _ rename: TimelineClipRename) {
        let r = rename.rect, font = CanvasFont(family: Self.uiFontFamily, size: 12)
        c.fillRoundedRect(r, radius: 6, theme.rowBackground)
        c.strokeRoundedRect(r.insetBy(0.5), radius: 6, theme.accent, width: 1)
        c.drawText("Rename clip", at: .init(r.x + 12, r.y + 10), font: font, color: theme.textPrimary)
        let field = CanvasRect(x: r.x + 12, y: r.y + 32, width: r.width - 24, height: 28)
        c.fillRoundedRect(field, radius: 3, CanvasColor(ThemeTokens.neutral900))
        c.strokeRoundedRect(field.insetBy(0.5), radius: 3, theme.accent, width: 1)
        c.withState {
            c.clip(field.insetBy(4))
            let before = String(rename.draft.prefix(rename.cursor))
            let cursorX = field.x + 6 + c.measureText(before, font: font).width
            if rename.selectedAll {
                c.fillRect(CanvasRect(x: field.x + 5, y: field.y + 4,
                    width: c.measureText(rename.draft, font: font).width + 2, height: 20), theme.accent.withAlpha(0.3))
            }
            c.drawText(rename.draft, at: .init(field.x + 6, field.y + 7), font: font, color: CanvasColor(ThemeTokens.white))
            if !rename.selectedAll { c.fillRect(CanvasRect(x: cursorX, y: field.y + 5, width: 1, height: 18), theme.accent) }
        }
        for (rect, title) in [(rename.cancelRect, "Cancel"), (rename.confirmRect, "Rename")] {
            c.fillRoundedRect(rect, radius: 3, theme.accent.withAlpha(0.15))
            c.drawText(title, at: .init(rect.x + 10, rect.y + 6), font: font, color: theme.textPrimary)
        }
    }
}
