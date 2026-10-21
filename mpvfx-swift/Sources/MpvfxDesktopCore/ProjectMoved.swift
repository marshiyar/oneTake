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
// The open project's folder was moved or deleted (issue #101): the watch event the editor reacts to, the error name a
// save into the vanished folder carries, and defaults for backends without relocation.
import Foundation

/// What a project watch reports (`DesktopBackend.watchProjectEvents(id:onEvent:)`).
public enum DesktopProjectEvent: Equatable, Sendable {
    /// The document was changed on disk by something other than this backend; the new text.
    case changed(String)
    /// The document is gone: the project's folder was moved, renamed or deleted.
    case missing
}

extension DesktopError {
    /// `name` of a save, reload or edit that found the project's folder gone.
    public static let projectMovedName = "ProjectMovedError"
    public var isProjectMoved: Bool { name == Self.projectMovedName }
}

extension DesktopBackend {
    /// A backend without folder events reports only external edits.
    public func watchProjectEvents(id: String, onEvent: @escaping @Sendable (DesktopProjectEvent) -> Void) throws {
        try watchProject(id: id) { text in onEvent(.changed(text)) }
    }

    public func relocateProject(id: String, to path: String) throws -> DesktopProject {
        throw DesktopError.notImplemented("Locating a moved project")
    }
}
