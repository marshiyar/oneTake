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
#if os(macOS)
import AppKit
import Foundation
import MpvfxDesktopCore
import UniformTypeIdentifiers

/// NSSavePanel / NSOpenPanel dialogs for the library commands (save and open dialogs),
/// NSAlert errors, and NSWorkspace for shell.openPath. Every panel runs on the main thread.
final class MacDialogs: NativeDialogs, @unchecked Sendable {
    func showSave(_ o: SaveDialogOptions) async -> String? {
        await MainActor.run {
            let panel = NSSavePanel()
            panel.title = o.title
            panel.nameFieldStringValue = o.defaultPath
            if let label = o.buttonLabel { panel.prompt = label }
            let extensions = o.filters.flatMap(\.extensions)
            let types = extensions.compactMap { UTType(filenameExtension: $0) }
            if !types.isEmpty { panel.allowedContentTypes = types }
            panel.canCreateDirectories = true
            return panel.runModal() == .OK ? panel.url?.path : nil
        }
    }

    func showOpen(_ o: OpenDialogOptions) async -> [String] {
        await MainActor.run {
            let panel = NSOpenPanel()
            panel.title = o.title
            panel.canChooseDirectories = o.directory
            panel.canChooseFiles = !o.directory
            panel.allowsMultipleSelection = o.multiple
            // "treatsFilePackagesAsDirectories": a .mpvfxlibrary package can be picked as a folder.
            panel.treatsFilePackagesAsDirectories = o.directory
            return panel.runModal() == .OK ? panel.urls.map(\.path) : []
        }
    }

    func showError(title: String, message: String) async {
        await MainActor.run {
            let alert = NSAlert(); alert.alertStyle = .critical
            alert.messageText = title; alert.informativeText = message
            alert.runModal()
        }
    }

    /// shell.openPath: opens a folder in Finder, a file in its default app.
    func openPath(_ path: String) async {
        await MainActor.run { _ = NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    }
}
#endif
