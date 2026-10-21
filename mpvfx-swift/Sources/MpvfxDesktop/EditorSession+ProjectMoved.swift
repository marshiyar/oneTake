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
import MpvfxDesktopCore

// The open project's folder was moved, renamed or deleted (issue #101). The watch reports it within a second, a save into
// the vanished folder throws `DesktopError.projectMovedName`; either way autosave pauses and the user is asked once:
// "Locate Folder…" points the session at the moved copy, "Keep Editing" keeps the edits in memory. It is never the
// external-change question, whose both answers would reload a file that is not there.
extension EditorSession {
    /// Watches the open project's document: external edits go to `externalChange`, a vanished folder to
    /// `projectFolderVanished`. Called at launch and after every project switch.
    func watchOpenProject() {
        guard let backend, let project else { return }
        let directory = project.directory
        do {
            try backend.watchProjectEvents(id: project.id) { [weak self] event in
                // postToUI hops to the UI thread; an event about a folder the session has left since is dropped.
                self?.postToUI { if self?.project?.directory == directory { self?.projectEvent(event) } }
            }
        } catch { FileHandle.standardError.write(Data("[MpVFX] not watching the project file: \(error)\n".utf8)) }
    }

    func projectEvent(_ event: DesktopProjectEvent) {
        switch event {
        case .changed(let text):
            if !projectFolderMissing { externalChange(text) }
        case .missing:
            guard project != nil, !projectFolderMissing else { return }
            projectFolderMissing = true
            askAboutMovedFolder(movedFolderMessage)
        }
    }

    var movedFolderMessage: String {
        let folder = project?.directory ?? "of this project"
        return "The project folder \(folder) was moved or deleted. Your edits are kept in memory; "
            + "autosave is paused until you locate the folder."
    }

    /// True when `error` is a save into a vanished project folder: autosave pauses and the user is asked (once for the
    /// watch and autosave, again on every explicit save). False for any other error, which the caller reports.
    func projectFolderVanished(_ error: Error, explicitSave: Bool) -> Bool {
        guard (error as? DesktopError)?.isProjectMoved == true, project != nil else { return false }
        let first = !projectFolderMissing
        projectFolderMissing = true
        if first || explicitSave { askAboutMovedFolder(movedFolderMessage) }
        return true
    }

    private func askAboutMovedFolder(_ message: String) {
        guard !projectMovedPromptOpen else { return }
        projectMovedPromptOpen = true   // set before the shell's modal runs a nested event loop
        let answer: (Bool) -> Void = { [weak self] locate in
            self?.projectMovedPromptOpen = false
            if locate { self?.requestLocateProjectFolder() }
        }
        if let onProjectMoved { onProjectMoved(message, answer) }
        else { onError("The project folder is missing", message); answer(false) }
    }

    /// "Locate Folder…": the folder dialog, then `locateProjectFolder(path:)`. False before the shell has installed its
    /// dialogs.
    @discardableResult
    func requestLocateProjectFolder() -> Bool {
        guard backend != nil, let dialogs = panels?.dialogs else { return false }
        Task { [weak self] in
            let options = OpenDialogOptions(title: "Locate Project Folder", directory: true, multiple: false)
            guard let dir = await dialogs.showOpen(options).first else { return }
            self?.postToUI { self?.locateProjectFolder(path: dir) }
        }
        return true
    }

    /// Points the session at the project's new folder. When the document there is the one last saved, the in-memory
    /// document (edits and undo history included) is saved into it; when it differs, the usual external-change choice
    /// decides. A folder that is not this project is reported and the session stays paused.
    func locateProjectFolder(path: String) {
        guard let backend, let project else { return }
        let lastSaved = project.content
        let moved: DesktopProject
        do { moved = try backend.relocateProject(id: project.id, to: path) }
        catch { onError("Could not use that folder", "\(error)"); return }
        projectFolderMissing = false
        adoptMovedFolder(moved)
        watchOpenProject()   // events about the new folder; the old folder's late ones are dropped
        panels?.projectSwitched()   // the media bin and renders now list the new folder
        guard moved.content == lastSaved else { externalChange(moved.content); return }
        do { try save() }
        catch { if !projectFolderVanished(error, explicitSave: true) { onError("Could not save the project", "\(error)") } }
    }
}
