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
// Renaming a library event or project (LibraryCommands "renameEvent", "renameProject"). No dialog: the navigator
// sends the new name it collected in its own text field.
import Foundation

extension LibraryCommands {
    /// Renames the event (`eventId`) or project (`projectId`) of `libraryId` to `name`; the library service trims and
    /// checks the name and refuses an id it does not hold. A command missing one of the fields is refused here.
    static func rename(service: LibraryService, command: JSONValue) async throws {
        let isEvent = command["type"]?.string == "renameEvent"
        guard let libraryId = command["libraryId"]?.string, let name = command["name"]?.string,
              let id = command[isEvent ? "eventId" : "projectId"]?.string else {
            throw DesktopError("Invalid library command")
        }
        if isEvent { try await service.renameEvent(libraryId: libraryId, eventId: id, name: name) }
        else { try await service.renameProject(libraryId: libraryId, projectId: id, name: name) }
    }
}
