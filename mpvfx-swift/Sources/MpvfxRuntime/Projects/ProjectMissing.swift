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
// A project folder that was moved, renamed or deleted while it was open (issue #101). The store tells it apart from an
// external edit (a missing document is `.missing`, never `.conflict`), and the watcher reports it as its own event, so
// the editor can ask for the folder's new location instead of offering to reload a file that is not there.
import Foundation
import MpvfxShared

/// What `ProjectDocumentWatcher` saw on disk.
public enum ProjectDocumentEvent: Equatable, Sendable {
    /// The document now holds this text, which differs from what the store last read or saved.
    case changed(String)
    /// The document is gone: its folder was moved, renamed or deleted (reported once until it is back).
    case missing
}

extension ProjectDocumentError {
    /// The save, reload or edit found no document at `directory`.
    public static func missing(_ directory: String) -> ProjectDocumentError {
        ProjectDocumentError(.missing, "The project folder \(directory) was moved or deleted. Nothing was written; "
            + "your edits are kept in memory until you locate the folder.")
    }
}

enum ProjectDocumentPresence {
    /// True only when `path` is known to be absent (ENOENT, or ENOTDIR for a parent that is now a file); a
    /// permission or I/O error is not a missing project, so it never reports one.
    static func isGone(_ path: String) -> Bool {
        do { _ = try ProjectFS.statInfo(path); return false }
        catch let e as ProjectFSError { return e.code == "ENOENT" || e.code == "ENOTDIR" }
        catch { return false }
    }
}

extension ProjectDocumentStore {
    var documentPath: String { PosixPath.join(directory, NATIVE_PROJECT_DOCUMENT_PATH) }

    /// `.missing` when the document is gone, else `error` itself: a failed write or read into a vanished folder
    /// reads as a conflict (the file no longer matches) or as a raw ENOENT, and is neither.
    func missingOr(_ error: Error) -> Error {
        ProjectDocumentPresence.isGone(documentPath) ? ProjectDocumentError.missing(directory) : error
    }
}
