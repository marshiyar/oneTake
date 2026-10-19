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
#if os(Linux)
import CGtk3
import Foundation
import MpvfxDesktopCore

/// GtkFileChooserNative (portal-aware) dialogs for the library commands, and error boxes.
final class GtkDialogs: NativeDialogs, @unchecked Sendable {
    var parent: () -> UnsafeMutablePointer<GtkWindow>?
    init(parent: @escaping () -> UnsafeMutablePointer<GtkWindow>?) { self.parent = parent }

    private func run(title: String, action: GtkFileChooserAction, accept: String?, configure: (OpaquePointer) -> Void) -> [String] {
        let native = gtk_file_chooser_native_new(title, parent(), action, accept, nil)!
        let chooser = native
        configure(chooser)
        defer { g_object_unref(raw(native)) }
        let response = gtk_native_dialog_run(typed(raw(native), GtkNativeDialog.self))
        guard response == GTK_RESPONSE_ACCEPT.rawValue else { return [] }
        var out: [String] = []
        var node = gtk_file_chooser_get_filenames(chooser)
        let head = node
        while let n = node {
            if let s = n.pointee.data { out.append(String(cString: s.assumingMemoryBound(to: CChar.self))); g_free(s) }
            node = n.pointee.next
        }
        g_slist_free(head)
        return out
    }

    private func addFilters(_ chooser: OpaquePointer, _ filters: [FileFilter]) {
        for f in filters where !f.extensions.isEmpty {
            let filter = gtk_file_filter_new()
            gtk_file_filter_set_name(filter, f.name)
            for e in f.extensions { gtk_file_filter_add_pattern(filter, "*.\(e)") }
            gtk_file_chooser_add_filter(chooser, filter)
        }
    }

    func showSave(_ o: SaveDialogOptions) async -> String? {
        await withCheckedContinuation { c in
            onMain {
                let r = self.run(title: o.title, action: GTK_FILE_CHOOSER_ACTION_SAVE, accept: o.buttonLabel ?? "_Save") { ch in
                    gtk_file_chooser_set_do_overwrite_confirmation(ch, 1)
                    gtk_file_chooser_set_current_name(ch, o.defaultPath)
                    self.addFilters(ch, o.filters)
                }
                c.resume(returning: r.first)
            }
        }
    }

    func showOpen(_ o: OpenDialogOptions) async -> [String] {
        await withCheckedContinuation { c in
            onMain {
                let action = o.directory ? GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER : GTK_FILE_CHOOSER_ACTION_OPEN
                c.resume(returning: self.run(title: o.title, action: action, accept: "_Open") { ch in
                    gtk_file_chooser_set_select_multiple(ch, o.multiple ? 1 : 0)
                })
            }
        }
    }

    func showError(title: String, message: String) async {
        await withCheckedContinuation { c in onMain { mpvfx_error_box(self.parent(), title, message); c.resume() } }
    }

    /// shell.openPath
    func openPath(_ path: String) async {
        await withCheckedContinuation { c in
            onMain {
                if let uri = takeString(g_filename_to_uri(path, nil, nil)) { _ = g_app_info_launch_default_for_uri(uri, nil, nil) }
                c.resume()
            }
        }
    }
}
#endif
