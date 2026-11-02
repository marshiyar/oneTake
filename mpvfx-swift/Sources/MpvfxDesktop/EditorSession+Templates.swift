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
// File > Save as Template… and File > New from Template (#332). A template is the open project without its media;
// the clips marked as placeholders (⌥⌘P) are the slots a new project fills. The native dialogs name the template and
// the new project's folder and ask for each placeholder's media in turn; cancelling a placeholder's dialog leaves it
// for later.
import Foundation
import MpvfxShared
import MpvfxRuntime
import MpvfxDesktopCore

extension EditorSession {
    /// The user's templates, or none before the panels exist.
    var projectTemplates: ProjectTemplateStore? {
        panels.map { ProjectTemplateStore(userData: $0.userData, durableWrite: NativeDurableWrite()) }
    }

    /// File > Save as Template…: the save dialog names the template (its file name), then the open project is stored
    /// without its media. False without a project or before the shell has installed its dialogs.
    @discardableResult
    func requestSaveAsTemplate() -> Bool {
        guard let projectDir, let dialogs = panels?.dialogs, let store = projectTemplates else { return false }
        if let failure = flushSave() { onError("Could not save the project", failure); return true }
        let document = editor.document
        let suggested = projectDir.lastPathComponent
        Task { [weak self] in
            guard let chosen = await dialogs.showSave(.init(title: "Save as Template", defaultPath: suggested, buttonLabel: "Save Template",
                                                            filters: [])) else { return }
            let name = (chosen as NSString).lastPathComponent
            self?.postToUI {
                guard let self else { return }
                do {
                    let template = try store.save(projectDirectory: projectDir.path, document: document, name: name)
                    let count = template.slots.count
                    self.player.view.showToast("Saved template \(template.name) with \(count) placeholder\(count == 1 ? "" : "s")")
                } catch {
                    self.onError("Could not save the template", "\(error)")
                }
            }
        }
        return true
    }

    /// File > New from Template > <name>: the save dialog names the new project's folder, the project is created from
    /// the template and opened here, then the file dialog asks for each placeholder's media, in order.
    @discardableResult
    func requestNewFromTemplate(id: String) -> Bool {
        guard backend != nil, let dialogs = panels?.dialogs, let store = projectTemplates,
              let template = store.list().first(where: { $0.id == id }) else { return false }
        let projects = (panels?.userData).map { ($0 as NSString).appendingPathComponent("projects") } ?? ""
        Task { [weak self] in
            guard let chosen = await dialogs.showSave(.init(title: "New Project from \(template.name)",
                                                            defaultPath: (projects as NSString).appendingPathComponent(template.name),
                                                            buttonLabel: "Create Project", filters: [])) else { return }
            self?.postToUI {
                guard let self else { return }
                do {
                    _ = try store.createProject(templateId: id, name: (chosen as NSString).lastPathComponent, at: chosen)
                } catch {
                    self.onError("Could not create the project", "\(error)"); return
                }
                self.openProject(path: chosen)
                let opened = URL(fileURLWithPath: chosen).resolvingSymlinksInPath().path
                guard self.projectDir.map({ $0.resolvingSymlinksInPath().path == opened }) == true else { return }
                let missing = template.missingFonts { family in (self.backend?.installedFontFamilies() ?? []).contains(family) }
                if !missing.isEmpty {
                    self.onError("Fonts not installed", "This template uses \(missing.joined(separator: ", ")), which is not installed here, so its text is drawn in another font.")
                }
                self.fillPlaceholders(template.slots, dialogs: dialogs)
            }
        }
        return true
    }

    /// Asks for each slot's media in turn; a cancelled dialog leaves that placeholder for later.
    private func fillPlaceholders(_ slots: [ProjectTemplateSlot], dialogs: NativeDialogs) {
        guard let slot = slots.first else { return }
        let rest = Array(slots.dropFirst())
        let title = "Media for Placeholder \(slot.index)" + (slot.label.map { " – \($0)" } ?? "")
        Task { [weak self] in
            let paths = await dialogs.showOpen(.init(title: title, directory: false, multiple: false))
            self?.postToUI {
                guard let self else { return }
                guard let path = paths.first else { self.fillPlaceholders(rest, dialogs: dialogs); return }
                self.fillPlaceholder(number: slot.index, from: path) { self.fillPlaceholders(rest, dialogs: dialogs) }
            }
        }
    }

    /// Copies `path` into the project and swaps it into placeholder `number`, keeping the clip's edits. Refusals (media
    /// shorter than the clip) are shown as a toast with the frames missing, and the placeholder stays.
    func fillPlaceholder(number: Int, from path: String, then next: @escaping () -> Void = {}) {
        guard let clip = editor.document.sequence.tracks.flatMap(\.clips).first(where: { $0.placeholder?.number == number }) else { next(); return }
        replaceClipMedia(clipId: clip.id, from: path, label: "Placeholder \(number)", then: next)
    }

    /// Clip menu > Replace media…: the file dialog, then the file is copied into the project and swapped in, keeping the
    /// clip's trim, transform, grade, moves and effects, in one undo step with the import's asset.
    func requestReplaceMedia(clipId: String) {
        guard let dialogs = panels?.dialogs, editor.clip(clipId) != nil else { return }
        Task { [weak self] in
            let paths = await dialogs.showOpen(.init(title: "Replace Media", directory: false, multiple: false))
            guard let path = paths.first else { return }
            self?.postToUI { self?.replaceClipMedia(clipId: clipId, from: path, label: nil) }
        }
    }

    /// Copies `path` into the project and swaps it into clip `clipId`; a refusal is shown as a toast and changes nothing.
    func replaceClipMedia(clipId: String, from path: String, label: String?, then next: @escaping () -> Void = {}) {
        importMedia(paths: [path]) { [weak self] result in
            defer { next() }
            guard let self, let imported = result.media.first(where: { ["video", "audio", "image"].contains($0.kind) }),
                  let asset = self.editor.document.assets.first(where: { $0.source == imported.path }) else { return }
            if self.editor.replaceMedia(clipId: clipId, asset: asset) {
                self.composedDocument = nil
                self.syncStage(); self.panels?.syncItems()
            } else if let failure = self.editor.lastFailure {
                self.player.view.showToast((label.map { $0 + ": " } ?? "") + failure.message, isError: true)
            }
            self.redraw()
        }
    }
}
