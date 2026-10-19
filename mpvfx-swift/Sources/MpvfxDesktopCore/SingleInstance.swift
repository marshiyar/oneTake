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
// The single-instance lock without a toolkit.
// On Linux the GTK shell gets uniqueness from GApplication (D-Bus); this lock is the
// Foundation-only fallback / non-D-Bus path, and the identity rules shared by all hosts.
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import WinSDK
#endif

public enum SingleInstance {
    /// GApplication ids must be valid D-Bus names (g_application_id_is_valid rules).
    public static func isValidApplicationId(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 255, !id.hasPrefix("."), !id.hasSuffix(".") else { return false }
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        for p in parts {
            guard let f = p.first, !p.isEmpty, !f.isNumber else { return false }
            for c in p.unicodeScalars where !(c.isASCII && (CharacterSet.alphanumerics.contains(c) || c == "_" || c == "-")) { return false }
        }
        return true
    }

    /// Lock file path for an app id under a runtime directory.
    public static func lockPath(appId: String, runtimeDir: String) -> String {
        let safe = appId.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "_" }
        return (runtimeDir as NSString).appendingPathComponent(String(safe) + ".lock")
    }
}

/// Primary-instance lock.
/// - Linux/macOS: advisory flock on `path`, released on exit even after a crash.
/// - Windows: named mutex `Local\<appId>` (per session) via CreateMutexW, released with the handle (also on a crash).
/// (macOS app bundles also get single-instance from LaunchServices.)
public final class SingleInstanceLock {
    public let path: String
    #if os(Windows)
    private var handle: HANDLE?
    #else
    private var fd: Int32 = -1
    #endif
    public init(path: String) { self.path = path }

    /// Windows mutex name for an app id: `Local\` + sanitized id (backslash is not allowed after the prefix).
    public static func mutexName(appId: String) -> String {
        "Local\\" + String(appId.map { $0 == "\\" ? "_" : $0 })
    }

    #if os(Windows)
    public var isHeld: Bool { handle != nil }
    /// `path` is used as the app id on Windows.
    public func acquire() -> Bool {
        if handle != nil { return true }
        let name = Self.mutexName(appId: path)
        let h: HANDLE? = name.withCString(encodedAs: UTF16.self) { CreateMutexW(nil, true, $0) }
        guard let h else { return false }
        if GetLastError() == DWORD(ERROR_ALREADY_EXISTS) { CloseHandle(h); return false }
        handle = h
        return true
    }
    public func release() {
        if let h = handle { ReleaseMutex(h); CloseHandle(h); handle = nil }
    }
    #else
    public var isHeld: Bool { fd >= 0 }
    /// true = this process is the primary instance.
    public func acquire() -> Bool {
        if fd >= 0 { return true }
        let d = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard d >= 0 else { return false }
        if flock(d, LOCK_EX | LOCK_NB) != 0 { close(d); return false }
        fd = d
        return true
    }
    public func release() {
        if fd >= 0 { flock(fd, LOCK_UN); close(fd); fd = -1 }
    }
    #endif
    deinit { release() }
}
