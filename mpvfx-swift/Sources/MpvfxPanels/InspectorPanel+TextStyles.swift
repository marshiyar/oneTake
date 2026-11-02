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
import MpvfxTimeline

/// Drawn samples for the Style menu. The sample is the style's own name set with the style's values by the same
/// `TextBlock` mapping the preview uses (NativeTextRendering.block), shrunk to fit a menu row.
enum TextStyleSample {
    static let rowHeight = 36.0
    static let maxFontSize = 18.0

    /// The style's values for a sample line; nil for a record this version cannot read.
    static func text(_ style: NativeTextStyle) -> NativeClipText? {
        guard style.isSupported, var text = style.text else { return nil }
        text.content = style.name
        return text
    }

    static func block(_ text: NativeClipText) -> TextBlock {
        let s = min(1, maxFontSize / text.resolvedFontSize)
        let font = CanvasFont(family: text.resolvedFontFamily, size: text.resolvedFontSize * s, numericWeight: text.resolvedFontWeight, italic: text.isItalic)
        return TextBlock(text: text.displayContent, font: font, color: .documentColor(text.resolvedColor),
                         align: .left, letterSpacing: text.resolvedLetterSpacing * s,
                         lineHeight: text.resolvedLineHeight * text.resolvedFontSize * s)
    }

    /// Black or white plate, whichever the text colour stands out from, so a white title and a black one both read.
    static func plate(for color: CanvasColor) -> CanvasColor {
        let luminance = 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b
        return luminance > 0.5 ? CanvasColor(r: 0.12, g: 0.12, b: 0.12) : CanvasColor(r: 0.94, g: 0.94, b: 0.94)
    }

    /// Paints the sample into `rect` (clipped to it).
    static func draw(_ text: NativeClipText, in rect: CanvasRect, on c: CanvasContext) {
        let laid = block(text)
        c.fillRoundedRect(rect, radius: 3, plate(for: laid.color))
        c.withState {
            c.clip(rect)
            let height = laid.lineHeight
            TextLayout.draw(laid, in: CanvasRect(x: rect.x + 8, y: rect.midY - height / 2, width: rect.width - 16, height: height), on: c)
        }
    }
}

extension InspectorPanel {
    /// What the Style menu lists and ⌥⌘1…9 apply: the user's library, then the starter styles it lacks, then the
    /// project's own styles neither has. The project's copy of a style replaces the listed one of the same id.
    func textStyleChoices(_ editor: TimelineEditor) -> [NativeTextStyle] {
        let library = textStyleLibrary?.menuStyles ?? []
        let libraryIds = Set(library.map(\.id))
        let starters = TextStarterStyles.styles.filter { !libraryIds.contains($0.id) }
        let listed = Set(library.map(\.id) + starters.map(\.id))
        let projectStyles = (editor.document.textStyles ?? [])
        let projectOnly = projectStyles.filter { $0.isSupported && !listed.contains($0.id) }
        let projectCopy = Dictionary(projectStyles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return (library + starters).map { projectCopy[$0.id].flatMap { $0.isSupported ? $0 : nil } ?? $0 } + projectOnly
    }

    /// Selected layers that hold text.
    func selectedTextClipIds(_ editor: TimelineEditor) -> [String] {
        selection.filter { editor.clipText(clipId: $0) != nil }
    }

    func textStyleRows(_ editor: TimelineEditor, _ s: Selected) -> [InspectorRow] {
        let linked = s.clip.textStyle.flatMap { link in editor.document.textStyles?.first { $0.id == link.styleId } }
        var rows: [InspectorRow] = [.init(.buttons([
            .init(key: "textStyle:menu", label: "Style: \(linked?.name ?? "None")", style: textStyleMenuOpen ? .chipActive : .muted) { [weak self] in
                guard let self else { return }
                textStyleMenuOpen.toggle()
                if textStyleMenuOpen { textStyleLibrary?.reload() }
                textStyleError = nil
                onOpenGroupChanged?("text")
            },
        ]))]
        guard textStyleMenuOpen else { return rows }
        let choices = textStyleChoices(editor)
        for (index, style) in choices.enumerated() {
            guard let text = TextStyleSample.text(style) else { continue }
            let key = "textStyle:pick:\(style.id)"
            let shortcut = index < 9 ? "⌥⌘\(index + 1)" : ""
            rows.append(.init(.custom(InspectorCustomRow(id: key, height: TextStyleSample.rowHeight, draw: { [weak self] c, r, _ in
                guard let self else { return }
                let sample = CanvasRect(x: r.x, y: r.y + 2, width: r.width - 52, height: r.height - 4)
                TextStyleSample.draw(text, in: sample, on: c)
                let hit = Hit.custom(key, 0)
                if self.hovered == hit || linked?.id == style.id {
                    c.strokeRoundedRect(sample.insetBy(0.5), radius: 3, linked?.id == style.id ? PanelTheme.text0 : PanelTheme.panelBorderInput, width: 1)
                }
                PanelDraw.text(c, shortcut, in: CanvasRect(x: sample.maxX + 6, y: r.midY - 7, width: 46, height: 14), font: PanelTheme.mono(11), color: PanelTheme.text2)
                self.addHit(r, hit, label: "Apply text style \(style.name)")
            }, pointer: { [weak self] _, _, phase in
                if phase == 0 { self?.applyTextStyleFromMenu(style) }
            }))))
        }
        if choices.isEmpty { rows.append(.init(.note("No text styles yet. Name this layer’s look below, then choose Save current as style."))) }
        if let loadError = textStyleLibrary?.loadError { rows.append(.init(.note(loadError.localizedDescription))) }
        rows.append(.init(.number(.init(key: "textStyle:name", label: "Style name", text: textStyleNameDraft ?? "", tier: .explicitCustom,
            commit: { [weak self] in self?.textStyleNameDraft = $0 }))))
        rows.append(.init(.buttons([
            .init(key: "textStyle:save", label: "Save current as style", style: .accent, action: { [weak self] in _ = self?.saveTextStyleFromLayer() },
                  disabled: selection.count != 1),
            .init(key: "textStyle:update", label: "Update style", style: .muted, action: { [weak self] in self?.updateLinkedTextStyle(editor, s) },
                  disabled: linked == nil),
            .init(key: "textStyle:detach", label: "Detach", style: .muted, action: { [weak self] in self?.detachTextStyles(editor) },
                  disabled: linked == nil),
        ])))
        rows.append(.init(.buttons([
            .init(key: "textStyle:delete", label: "Delete from my styles", style: .danger,
                  action: { [weak self] in self?.deleteLibraryTextStyle(id: linked?.id) },
                  disabled: linked.map { style in !(textStyleLibrary?.menuStyles.contains { $0.id == style.id } ?? false) } ?? true),
        ])))
        if let error = textStyleError { rows.append(.init(.note(error))) }
        return rows
    }

    /// One named undo step through the inspector's usual refresh; false when the command was refused.
    private func runTextStyleEdit(_ label: String, _ op: () -> Bool) -> Bool {
        var ok = false
        edited({ ok = op(); return ok }(), label: label)
        return ok
    }

    private func reportTextStyle(_ message: String?) {
        textStyleError = message
        onOpenGroupChanged?("text")
    }

    func applyTextStyleFromMenu(_ style: NativeTextStyle) {
        guard let editor, applyTextStyle(style, editor) else { return }
        reportTextStyle(nil)
    }

    @discardableResult
    private func applyTextStyle(_ style: NativeTextStyle, _ editor: TimelineEditor) -> Bool {
        let ids = selectedTextClipIds(editor)
        guard !ids.isEmpty else { reportTextStyle("Select a text layer to apply a style."); return false }
        // Already following this style with no override: nothing to change, and nothing went wrong.
        let links = editor.document.sequence.tracks.flatMap(\.clips).filter { ids.contains($0.id) }.map(\.textStyle)
        if links.allSatisfy({ $0?.styleId == style.id && $0?.overrides.isEmpty == true }) { return true }
        let ok = runTextStyleEdit("Apply text style") { editor.applyLibraryTextStyle(style, clipIds: ids) }
        if !ok { reportTextStyle("The style could not be applied. Unlock the layer’s track and try again.") }
        return ok
    }

    /// ⌥⌘1…9: the n-th style of the menu on the selected text layers. False when there is no such style or layer.
    public func applyTextStyle(number: Int) -> Bool {
        guard let editor, number >= 1, !selectedTextClipIds(editor).isEmpty else { return false }
        let choices = textStyleChoices(editor)
        guard number <= choices.count else { return false }
        return applyTextStyle(choices[number - 1], editor)
    }

    /// Whether ⌥⌘S means "save the selected text layer as a style" (it splits scenes otherwise).
    public var canSaveTextStyle: Bool {
        guard let editor, selection.count == 1 else { return false }
        return !selectedTextClipIds(editor).isEmpty
    }

    /// ⌥⌘S and the button: the layer becomes a new style (named by the field, else "Text style N"), is added to the
    /// user's library and the layer is linked to it, as one undo step in the project.
    @discardableResult
    public func saveTextStyleFromLayer() -> Bool {
        guard let editor, selection.count == 1, let clipId = selection.first, editor.clipText(clipId: clipId) != nil else {
            reportTextStyle("Select one text layer to save its style."); return false
        }
        let existing = Set(textStyleChoices(editor).map(\.name))
        var name = (textStyleNameDraft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            var n = existing.count + 1
            while existing.contains("Text style \(n)") { n += 1 }
            name = "Text style \(n)"
        }
        guard !existing.contains(name) else { reportTextStyle("A style named ‘\(name)’ already exists. Choose another name."); return false }
        if let loadError = textStyleLibrary?.loadError { reportTextStyle(loadError.localizedDescription); return false }
        let styleId = "text-style:" + UUID().uuidString.lowercased()
        let ok = runTextStyleEdit("Save text style") { editor.createTextStyle(clipId: clipId, styleId: styleId, name: name) }
        guard ok, let style = editor.document.textStyles?.first(where: { $0.id == styleId }) else {
            reportTextStyle("The style could not be saved."); return false
        }
        textStyleNameDraft = nil
        do { try textStyleLibrary?.save(style); reportTextStyle(nil) }
        catch { reportTextStyle("Saved in this project only. \(error.localizedDescription)") }
        return true
    }

    private func updateLinkedTextStyle(_ editor: TimelineEditor, _ s: Selected) {
        guard let styleId = s.clip.textStyle?.styleId else { return }
        let ok = runTextStyleEdit("Update text style") { editor.updateTextStyle(styleId: styleId, fromClipId: s.id) }
        guard ok else { reportTextStyle("The style could not be updated."); return }
        if let style = editor.document.textStyles?.first(where: { $0.id == styleId }),
           textStyleLibrary?.menuStyles.contains(where: { $0.id == styleId }) == true {
            do { try textStyleLibrary?.save(style); reportTextStyle(nil) }
            catch { reportTextStyle("Updated in this project only. \(error.localizedDescription)") }
        } else { reportTextStyle(nil) }
    }

    private func detachTextStyles(_ editor: TimelineEditor) {
        let linked = Set(editor.document.sequence.tracks.flatMap(\.clips).filter { $0.textStyle != nil }.map(\.id))
        let ids = selectedTextClipIds(editor).filter { linked.contains($0) }
        guard !ids.isEmpty else { return }
        let ok = runTextStyleEdit("Detach text style") { editor.detachTextStyle(clipIds: ids) }
        reportTextStyle(ok ? nil : "The layer could not be detached from its style.")
    }

    /// The project keeps its own copy and every layer keeps its look; only the user's list changes.
    private func deleteLibraryTextStyle(id: String?) {
        guard let id, let library = textStyleLibrary else { return }
        do { try library.delete(id: id); reportTextStyle(nil) }
        catch { reportTextStyle(error.localizedDescription) }
    }
}
