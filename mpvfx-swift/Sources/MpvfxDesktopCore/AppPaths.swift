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
// Paths and identity for the Swift shell.
import Foundation

public struct AppPaths: Sendable {
    public var userData: String
    public var appId: String

    /// Environment: MPVFX_USER_DATA_DIR (isolated profile), else $XDG_CONFIG_HOME/MpVFX (~/.config/MpVFX).
    public static func resolve(env: [String: String], executable: String) -> AppPaths {
        let isolated = env["MPVFX_USER_DATA_DIR"].map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let config = env["XDG_CONFIG_HOME"] ?? (NSHomeDirectory() + "/.config")
        let userData = isolated ?? config + "/MpVFX"
        // The single-instance lock is scoped to userData; scope the application id the same way.
        var appId = "com.mpvfx.editor"
        if let isolated { appId += ".u" + String(format: "%08x", fnv1a(isolated)) }
        return AppPaths(userData: userData, appId: appId)
    }

    static func fnv1a(_ s: String) -> UInt32 {
        var h: UInt32 = 0x811c9dc5
        for b in s.utf8 { h ^= UInt32(b); h = h &* 0x01000193 }
        return h
    }
}
