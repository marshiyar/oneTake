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
// Deleting a library event or project (LibraryCommands "deleteEvent", "deleteProject"). The navigator asks the user
// first and moves the editor off the project, so this only has to make sure the backend lets go of it.
import Foundation

extension LibraryCommands {
    /// Deletes the event (`eventId`) or project (`projectId`) of `libraryId`. The backend closes every project that is
    /// about to go (its watcher and edit state) before its folder is removed. A command missing a field is refused here.
    static func delete(service: LibraryService, backend: DesktopBackend, command: JSONValue) async throws {
        let isEvent = command["type"]?.string == "deleteEvent"
        guard let libraryId = command["libraryId"]?.string, let id = command[isEvent ? "eventId" : "projectId"]?.string else {
            throw DesktopError("Invalid library command")
        }
        if isEvent {
            let library = try await service.views().array?.first { $0["id"]?.string == libraryId }
            let projects = library?["projects"]?.array?.filter { $0["eventId"]?.string == id }.compactMap { $0["id"]?.string } ?? []
            for projectId in projects { backend.closeProject(id: projectId) }
            try await service.deleteEvent(libraryId: libraryId, eventId: id)
        } else {
            backend.closeProject(id: id)
            try await service.deleteProject(libraryId: libraryId, projectId: id)
        }
    }
}
