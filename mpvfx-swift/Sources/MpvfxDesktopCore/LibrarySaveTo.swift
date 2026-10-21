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
// "Save to…" on a library export record (LibraryCommands "saveOutput"): the save dialog, then the library's copy.
import Foundation

extension LibraryCommands {
    /// "Save to…" on a library export record: asks where, then copies the finished file there. Nothing is written when
    /// the dialog is cancelled.
    static func saveOutput(service: LibraryService, dialogs: NativeDialogs?, libraryId: String, jobId: String) async throws {
        let job = try await service.views().array?.first { $0["id"]?.string == libraryId }?["jobs"]?.array?
            .first { $0["id"]?.string == jobId }
        guard let job, job["status"]?.string == "complete", let output = job["output"]?.string, !output.isEmpty else {
            throw DesktopError("Export is not complete")
        }
        let ext = (output as NSString).pathExtension
        let options = SaveDialogOptions(title: "Save Export To", defaultPath: (output as NSString).lastPathComponent,
                                        buttonLabel: nil, filters: [.init(name: "Rendered media", extensions: [ext])])
        guard let selected = await dialogs?.showSave(options), !selected.isEmpty else { return }
        let target = saveOutputTarget(selected, extension: ext)
        try await service.saveOutput(libraryId: libraryId, jobId: jobId, destination: target.path,
                                     overwrite: target.replaceApproved)
    }

    /// The path a "Save to…" writes and whether replacing a file there was approved. Each save dialog asks before it
    /// returns an existing path, but the GTK and Windows dialogs are given no default extension (`GtkDialogs.swift`,
    /// `dialogs.cpp`), so a name typed without the export's extension comes back as typed: the extension is added here,
    /// and since the dialog asked about the typed name, not this path, a file already at this path is kept (the save
    /// fails with an error) instead of replaced.
    static func saveOutputTarget(_ selected: String, extension ext: String) -> (path: String, replaceApproved: Bool) {
        let typed = (selected as NSString).pathExtension
        if ext.isEmpty || typed.lowercased() == ext.lowercased() { return (selected, true) }
        return (selected + "." + ext, false)
    }
}
