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
// Crash-safe file replacement for project/library saves.
// Implements MpvfxRuntime.DurableWrite (Sources/MpvfxRuntime/Projects/DurableWrite.swift):
//   func write(_ data: Data, to path: String, tempName: String, preserveMode: Bool, beforeRename: () throws -> Void) throws
//   func syncDirectory(_ path: String) throws
// MpvfxDesktopCore does not depend on MpvfxRuntime; the conformance is declared in
// MpvfxBackend (RuntimeDesktopBackend.swift): `extension NativeDurableWrite: DurableWrite {}`.
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import WinSDK
#endif

public struct DurableWriteError: Error, Equatable, CustomStringConvertible {
    public var step: String, path: String, code: Int32
    public var description: String { "\(step) failed for \(path) (error \(code))" }
    /// Save failures use errno names across hosts; `code` itself is a Win32 error on Windows.
    public var filesystemCode: String? {
        #if os(Windows)
        switch code {
        case ERROR_DISK_FULL, ERROR_HANDLE_DISK_FULL: return "ENOSPC"
        case ERROR_DISK_QUOTA_EXCEEDED: return "EDQUOT"
        case ERROR_WRITE_PROTECT: return "EROFS"
        case ERROR_ACCESS_DENIED: return "EACCES"
        case ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND, ERROR_INVALID_DRIVE, ERROR_BAD_NETPATH, ERROR_BAD_NET_NAME: return "ENOENT"
        default: return nil
        }
        #else
        switch code {
        case ENOSPC: return "ENOSPC"
        case EDQUOT: return "EDQUOT"
        case EROFS: return "EROFS"
        case EACCES, EPERM: return "EACCES"
        case ENOENT: return "ENOENT"
        default: return nil
        }
        #endif
    }
}

public struct NativeDurableWrite: Sendable {
    public init() {}

    /// Directory-fsync errnos that mean "this filesystem cannot sync directories", not data loss.
    public static func isIgnorableDirectorySyncError(_ code: Int32) -> Bool {
        [EISDIR, EINVAL, EPERM, EACCES, ENOTSUP].contains(code)
    }

    /// Temp file `tempName` in the target's directory (same volume, so the rename is atomic).
    public static func tempPath(for path: String, tempName: String) -> String {
        guard let slash = path.lastIndex(where: { $0 == "/" || (Self.backslashSeparates && $0 == "\\") }) else { return tempName }
        return String(path[...slash]) + tempName
    }
    #if os(Windows)
    static let backslashSeparates = true
    #else
    static let backslashSeparates = false
    #endif

    /// The extended-length form ("\\?\C:\…", "\\?\UNC\server\share\…") of an absolute, normalized path, so a Win32 call
    /// is not cut off at MAX_PATH (260 characters with the NUL; learn.microsoft.com, "Maximum Path Length Limitation").
    /// ReplaceFileW also renames the replaced file internally, so a library project's journal at
    /// about 255 characters failed with ERROR_UNABLE_TO_REMOVE_REPLACED. The prefix turns "." and ".." into literal
    /// names, so a relative or non-normalized path keeps its plain form (separators as backslashes either way).
    public static func win32Path(_ path: String) -> String {
        let p = path.replacingOccurrences(of: "/", with: "\\")
        if p.hasPrefix("\\\\?\\") { return p }
        let parts = p.split(separator: "\\", omittingEmptySubsequences: true)
        if parts.contains(where: { $0 == "." || $0 == ".." }) { return p }
        if p.hasPrefix("\\\\") { return "\\\\?\\UNC\\" + p.dropFirst(2) }
        let u = Array(p.utf16)
        let isDrive = u.count >= 3 && u[1] == 0x3A && u[2] == 0x5C && ((0x41...0x5A).contains(u[0]) || (0x61...0x7A).contains(u[0]))
        return isDrive ? "\\\\?\\" + p : p
    }

    /// Convenience: generated temp name, mode not preserved, no hook.
    public func write(_ data: Data, to path: String) throws {
        let base = path.lastIndex(where: { $0 == "/" || (Self.backslashSeparates && $0 == "\\") }).map { String(path[path.index(after: $0)...]) } ?? path
        let name = ".\(base).\(UUID().uuidString.lowercased()).tmp"
        try write(data, to: path, tempName: name, preserveMode: false, beforeRename: {})
    }

    public func write(_ data: Data, to path: String, tempName: String, preserveMode: Bool, beforeRename: () throws -> Void) throws {
        let tmp = Self.tempPath(for: path, tempName: tempName)
        #if os(Windows)
        try writeTempWindows(data, tmp)
        do {
            try beforeRename()
            try replaceWindows(tmp: tmp, to: path, preserveMode: preserveMode)
        } catch {
            _ = Self.withWide(tmp) { DeleteFileW($0) }   // the error that stopped the write is the one reported
            throw error
        }
        #else
        try writePOSIX(data, tmp: tmp, to: path, preserveMode: preserveMode, beforeRename: beforeRename)
        #endif
    }

    /// POSIX: open + fsync the directory (ignorable errnos skipped). Windows: the directory must exist, but a directory
    /// handle cannot be flushed; the rename itself is written through (MOVEFILE_WRITE_THROUGH).
    public func syncDirectory(_ path: String) throws {
        #if os(Windows)
        let attributes = Self.withWide(path) { GetFileAttributesW($0) }
        if attributes == DWORD.max {   // INVALID_FILE_ATTRIBUTES
            throw DurableWriteError(step: "open directory", path: path, code: Int32(bitPattern: GetLastError()))
        }
        #else
        let dfd = open(path, O_RDONLY | O_CLOEXEC)
        guard dfd >= 0 else {
            if Self.isIgnorableDirectorySyncError(errno) { return }
            throw DurableWriteError(step: "open directory", path: path, code: errno)
        }
        defer { close(dfd) }
        if fsync(dfd) != 0 && !Self.isIgnorableDirectorySyncError(errno) {
            throw DurableWriteError(step: "fsync directory", path: path, code: errno)
        }
        #endif
    }

    #if !os(Windows)
    /// write temp -> fsync file -> beforeRename -> rename over target -> fsync directory.
    private func writePOSIX(_ data: Data, tmp: String, to path: String, preserveMode: Bool, beforeRename: () throws -> Void) throws {
        func fail(_ step: String, _ p: String) -> DurableWriteError { DurableWriteError(step: step, path: p, code: errno) }
        var mode: mode_t = 0o600
        if preserveMode {
            var st = stat()
            if stat(path, &st) == 0 { mode = st.st_mode & 0o7777 }
        }
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard fd >= 0 else { throw fail("open", tmp) }
        var ok = false
        defer { if !ok { unlink(tmp) } }
        do {
            defer { close(fd) }
            if fchmod(fd, mode) != 0 { throw fail("fchmod", tmp) }   // umask must not narrow the mode
            try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                var off = 0
                while off < buf.count {
                    let n = Foundation.write(fd, buf.baseAddress! + off, buf.count - off)
                    if n < 0 { if errno == EINTR { continue }; throw fail("write", tmp) }
                    off += n
                }
            }
            #if canImport(Darwin)
            if fcntl(fd, F_FULLFSYNC) != 0 && fsync(fd) != 0 { throw fail("fsync", tmp) }
            #else
            if fsync(fd) != 0 { throw fail("fsync", tmp) }
            #endif
        }
        try beforeRename()   // throws -> defer unlinks the temp file, error rethrown
        if rename(tmp, path) != 0 { throw fail("rename", path) }
        ok = true
        try syncDirectory(URL(fileURLWithPath: path).deletingLastPathComponent().path)
    }
    #endif

    #if os(Windows)
    private static func withWide<T>(_ path: String, _ body: (UnsafePointer<WCHAR>) throws -> T) rethrows -> T {
        try win32Path(path).withCString(encodedAs: UTF16.self, body)
    }

    /// The temp file, created exclusively, written and flushed (FlushFileBuffers); deleted again when that fails.
    private func writeTempWindows(_ data: Data, _ tmp: String) throws {
        func fail(_ step: String) -> DurableWriteError { DurableWriteError(step: step, path: tmp, code: Int32(bitPattern: GetLastError())) }
        let h: HANDLE? = Self.withWide(tmp) {
            CreateFileW($0, DWORD(GENERIC_WRITE), 0, nil, DWORD(CREATE_NEW), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let h, h != INVALID_HANDLE_VALUE else { throw fail("CreateFileW") }
        var ok = false
        defer { if !ok { _ = Self.withWide(tmp) { DeleteFileW($0) } } }
        defer { CloseHandle(h) }   // runs first: a handle still open would block the delete
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            while off < buf.count {
                var written: DWORD = 0
                let chunk = DWORD(min(buf.count - off, Int(Int32.max)))
                guard WriteFile(h, buf.baseAddress! + off, chunk, &written, nil) else { throw fail("WriteFile") }
                off += Int(written)
            }
        }
        guard FlushFileBuffers(h) else { throw fail("FlushFileBuffers") }
        ok = true
    }

    /// Replaces the target with the flushed temp file. NTFS has no POSIX mode: with `preserveMode` an existing target
    /// is replaced by ReplaceFileW, which keeps its attributes and ACL; otherwise (or when there is no target yet)
    /// MoveFileExW(REPLACE_EXISTING | WRITE_THROUGH) moves the temp file in with the directory's inherited ACL and
    /// plain attributes.
    private func replaceWindows(tmp: String, to path: String, preserveMode: Bool) throws {
        if preserveMode {
            let replaced = Self.withWide(path) { dst in
                Self.withWide(tmp) { src in
                    ReplaceFileW(dst, src, nil, DWORD(0x2), nil, nil)   // REPLACEFILE_IGNORE_MERGE_ERRORS
                }
            }
            if replaced { return }
            let error = GetLastError()
            guard error == DWORD(ERROR_FILE_NOT_FOUND) else {
                throw DurableWriteError(step: "ReplaceFileW", path: path, code: Int32(bitPattern: error))
            }
        }
        let moved = Self.withWide(tmp) { src in
            Self.withWide(path) { dst in
                MoveFileExW(src, dst, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
            }
        }
        guard moved else { throw DurableWriteError(step: "MoveFileExW", path: path, code: Int32(bitPattern: GetLastError())) }
    }
    #endif
}
