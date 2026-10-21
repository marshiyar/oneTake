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

// File > Open: any project folder (one holding `.studio/project.json`) through the native folder dialog, and the
// projects opened before, which the backend records on every open (`DesktopBackend.recentProjects`).
extension EditorSession {
    /// Cmd/Ctrl+O, File > Open… and the sidebar's "Open project…": the folder dialog, then that project in this window.
    /// False without a backend or before the shell has installed its dialogs.
    @discardableResult
    func requestOpenProject() -> Bool {
        guard backend != nil, let dialogs = panels?.dialogs else { return false }
        Task { [weak self] in
            guard let dir = await dialogs.showOpen(.init(title: "Open Project", directory: true, multiple: false)).first else { return }
            self?.postToUI { self?.openProject(path: dir) }
        }
        return true
    }

    /// Opens the project at `path` (its folder, `.studio` or `.studio/project.json`) in this window; the open one is
    /// saved first. A folder that is not a project is reported through `onError` and the open project stays.
    func openProject(path: String) {
        switchProject { backend in try backend.openProject(path: path) }
    }

    /// Recently opened projects that still exist, newest first, without the one open in this window.
    static func recents(_ backend: DesktopBackend, excluding directory: String?) -> [DesktopProjectSummary] {
        backend.recentProjects().filter { $0.directory != directory }
    }

    var recentProjects: [DesktopProjectSummary] {
        guard let backend else { return [] }
        return Self.recents(backend, excluding: project?.directory)
    }

    /// File > Open Recent > Clear Menu.
    func clearRecentProjects() {
        guard let backend else { return }
        do { try backend.clearRecentProjects() }
        catch { onError("Could not clear the recent projects", "\(error)") }
        panels?.refreshRecents()
    }
}
