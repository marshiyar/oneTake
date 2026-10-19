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
#if os(Windows)
import CMpvfxWin32
import Foundation
import MpvfxDesktopCore
import WinSDK

/// The common item dialogs (IFileOpenDialog / IFileSaveDialog, folders included) for the library commands and
/// imports, MessageBoxW errors, and ShellExecuteW for shell.openPath. Every dialog runs modally on the UI thread:
/// `post` gets there from a Task, `owner` is the window it belongs to.
final class WindowsDialogs: NativeDialogs, @unchecked Sendable {
    let post: (@escaping () -> Void) -> Void
    let owner: () -> HWND?
    init(post: @escaping (@escaping () -> Void) -> Void, owner: @escaping () -> HWND?) { self.post = post; self.owner = owner }

    private final class Paths { var list: [String] = [] }

    /// Runs `body` on the UI thread with a path collector and the dialog's owner, then hands back the paths.
    private func run(_ body: @escaping (UnsafeMutableRawPointer, HWND?) -> Int32) async -> [String] {
        await withCheckedContinuation { (c: CheckedContinuation<[String], Never>) in
            post { [self] in
                let paths = Paths()
                let hr = body(Unmanaged.passUnretained(paths).toOpaque(), owner())
                if hr < 0 { box(owner(), "Could not show the dialog", "HRESULT 0x\(String(UInt32(bitPattern: hr), radix: 16, uppercase: true))") }
                c.resume(returning: hr == 0 ? paths.list : [])   // S_FALSE: cancelled
            }
        }
    }

    private static let collect: mpvfx_path_callback = { context, path in
        guard let context, let path else { return }
        Unmanaged<Paths>.fromOpaque(context).takeUnretainedValue().list.append(String(decodingCString: path, as: UTF16.self))
    }

    func showOpen(_ o: OpenDialogOptions) async -> [String] {
        await run { context, owner in
            o.title.withCString(encodedAs: UTF16.self) { title in
                var dialog = MpvfxDialog(owner: owner.map { UnsafeMutableRawPointer($0) }, title: title, folders: o.directory ? 1 : 0,
                                         multiple: o.multiple ? 1 : 0, default_name: nil, filter_name: nil, filter_spec: nil, button: nil)
                return mpvfx_dialog_open(&dialog, Self.collect, context)
            }
        }
    }

    /// All filters' extensions as one file type ("*.mp4;*.mov"), named after the filters.
    func showSave(_ o: SaveDialogOptions) async -> String? {
        let patterns = o.filters.flatMap(\.extensions).map { "*.\($0)" }.joined(separator: ";")
        let title = WideString(o.title), name = WideString(o.defaultPath), filter = WideString(o.filters.map(\.name).joined(separator: ", "))
        let button = o.buttonLabel.map(WideString.init), spec = patterns.isEmpty ? nil : WideString(patterns)
        let paths = await run { context, owner in
            var dialog = MpvfxDialog(owner: owner.map { UnsafeMutableRawPointer($0) }, title: title.pointer, folders: 0, multiple: 0,
                                     default_name: name.pointer, filter_name: filter.pointer, filter_spec: spec?.pointer,
                                     button: button?.pointer)
            return mpvfx_dialog_save(&dialog, Self.collect, context)
        }
        withExtendedLifetime((title, name, filter, button, spec)) {}
        return paths.first
    }

    func showError(title: String, message: String) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            post { [self] in box(owner(), title, message); c.resume() }
        }
    }

    /// shell.openPath: a folder opens in Explorer, a file in its default app.
    func openPath(_ path: String) async {
        let hr = path.withCString(encodedAs: UTF16.self) { mpvfx_shell_open($0) }
        if hr < 0 { await showError(title: "Could not open \(path)", message: "HRESULT 0x\(String(UInt32(bitPattern: hr), radix: 16, uppercase: true))") }
    }
}

/// A UTF-16, NUL-terminated copy of a string that stays valid as long as the object lives.
final class WideString {
    let pointer: UnsafeMutablePointer<UInt16>
    init(_ s: String) {
        let units = Array(s.utf16) + [0]
        pointer = .allocate(capacity: units.count)
        pointer.initialize(from: units, count: units.count)
    }
    deinit { pointer.deallocate() }
}

/// `s` as a UTF-16, NUL-terminated pointer for `body`; nil stays nil.
func withWide<R>(_ s: String?, _ body: (UnsafePointer<UInt16>?) -> R) -> R {
    guard let s else { return body(nil) }
    return s.withCString(encodedAs: UTF16.self) { body($0) }
}

/// An error message box owned by `owner`.
func box(_ owner: HWND?, _ title: String, _ message: String) {
    withWide(title) { t in withWide(message) { m in _ = MessageBoxW(owner, m, t, UINT(MB_OK | MB_ICONERROR)) } }
}
#endif
