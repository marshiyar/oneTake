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
import MpvfxTimeline

/// Undo history across restarts (usePersistentEditHistory): `<userData>/edit-history/<project>.json`, taken back
/// on open when the project file is still the one it was saved against; rewritten after every edit, undo and
/// redo. The UI thread only captures the stacks: replaying them into documents (a full document clone per entry,
/// up to 100 per stack) and writing run on the persister's worker, newest snapshot wins.
extension EditorSession {
    func installEditHistory(userData: String) {
        guard let projectId = project?.id else { return }
        let store = FileTimelineHistoryStore(directory: URL(fileURLWithPath: userData).appendingPathComponent("edit-history"))
        if let saved = store.load(projectId: projectId) { editor.restoreHistory(saved) }
        let persister = TimelineHistoryPersister(store: store, projectId: projectId)
        editHistory = persister
        editor.onHistoryChange = { [weak self] in
            guard let self else { return }
            self.editHistory?.submit(self.editor.historySnapshot())
        }
    }

    /// How long closing waits for the last undo-history write: far longer than one write takes (a replay and a
    /// file of at most 200 documents), short enough that a stuck disk does not keep the app from quitting.
    static let editHistoryCloseTimeout = 5.0

    /// For the save barrier on close/quit (every shell's prepareClose): saves the project, then waits for the
    /// history worker so an edit made just before quitting is still offered by Undo after the next launch.
    /// Returns flushSave's message; a history write that does not finish in time is reported and does not keep
    /// the window open (the project itself is saved; only its undo steps would be missing).
    func flushForClose() -> String? {
        let failure = flushSave()
        if let editHistory, !editHistory.waitUntilIdle(timeout: Self.editHistoryCloseTimeout) {
            FileHandle.standardError.write(Data("[MpVFX] the undo history was still being written after \(Self.editHistoryCloseTimeout) s; the last edits may be missing from Undo next time\n".utf8))
        }
        return failure
    }
}
