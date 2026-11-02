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
// The LibraryCommands requests the library navigator's naming commands send (new event or project, rename).
import MpvfxDesktopCore
import MpvfxPanels

extension SessionPanels {
    /// Moves the editor off the open project when `doomed` names it, so its folder can be deleted: to another ready
    /// project of the library that stays, else to the standalone project. False (with the error shown) when the editor
    /// is still on it, which stops the delete.
    func leaveProject(libraryId: String, doomed: (DesktopLibraryProject) -> Bool) -> Bool {
        guard let current = left.library.currentProjectId,
              let library = libraryViews.first(where: { $0.id == libraryId }),
              let open = library.projects.first(where: { $0.id == current }), doomed(open) else { return true }
        if let next = library.projects.first(where: { $0.ready && !doomed($0) }) { switchToLibraryProject(next.id) } else { switchToStandalone() }
        guard session.project?.directory == open.directory else { return true }
        left.library.error = "Could not close \(open.name) to delete it"
        redraw()
        return false
    }


    /// The LibraryCommands request for a command that names an event or project: create one, or rename one.
    static func namedItemCommand(_ cmd: LibraryNavCommand) -> JSONObject {
        switch cmd {
        case .createEvent(let l, let name): return ["type": .string("event"), "libraryId": .string(l), "name": .string(name)]
        case .createProject(let l, let e, let name):
            return ["type": .string("project"), "libraryId": .string(l), "eventId": .string(e), "name": .string(name)]
        case .renameEvent(let l, let e, let name):
            return ["type": .string("renameEvent"), "libraryId": .string(l), "eventId": .string(e), "name": .string(name)]
        case .renameProject(let l, let p, let name):
            return ["type": .string("renameProject"), "libraryId": .string(l), "projectId": .string(p), "name": .string(name)]
        default: return ["type": .string("list")]
        }
    }
}
