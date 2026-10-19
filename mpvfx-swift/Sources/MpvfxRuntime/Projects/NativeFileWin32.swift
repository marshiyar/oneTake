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
// NativeFile and the path-level ProjectFS calls on Win32: CreateFileW handles, ReadFile/WriteFile/FlushFileBuffers,
// GetFileInformationByHandle(Ex) stats, GetFinalPathNameByHandleW (realpath), CreateDirectoryW, DeleteFileW,
// CreateHardLinkW, MoveFileExW, FindFirstFileW. Paths stay in "/" form above this layer; `win32Path` turns them into
// backslash paths (with the \\?\ prefix past MAX_PATH) and `posixForm` turns final paths back.
#if os(Windows)
import Foundation
import WinSDK
import MpvfxShared

private let accessGenericRead: DWORD = 0x8000_0000
private let accessGenericWrite: DWORD = 0x4000_0000
private let accessReadAttributes: DWORD = 0x0080
private let shareAll: DWORD = 0x1 | 0x2 | 0x4   // FILE_SHARE_READ | WRITE | DELETE
private let createNew: DWORD = 1, createAlways: DWORD = 2, openExisting: DWORD = 3, openAlways: DWORD = 4
private let flagBackupSemantics: DWORD = 0x0200_0000
private let flagOpenReparsePoint: DWORD = 0x0020_0000
private let attributeReadOnly: DWORD = 0x1
private let attributeDirectory: DWORD = 0x10
private let attributeReparsePoint: DWORD = 0x400
private let reparseTagSymlink: DWORD = 0xA000_000C
private let reparseTagMountPoint: DWORD = 0xA000_0003
/// 100 ns intervals between 1601-01-01 and 1970-01-01.
private let fileTimeUnixEpoch: Int128 = 116_444_736_000_000_000

/// C runtime errno for each Win32 error code that has one (the libuv mapping Node uses), so ProjectFSError codes
/// match POSIX; anything else is EIO.
private let errnoByWin32Error: [Int32: Int32] = {
    let groups: [(Int32, [Int32])] = [
        (ENOENT, [ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND, ERROR_INVALID_NAME, ERROR_BAD_NETPATH, ERROR_BAD_NET_NAME,
                  ERROR_INVALID_DRIVE, ERROR_DIRECTORY_NOT_SUPPORTED, ERROR_MOD_NOT_FOUND]),
        (EEXIST, [ERROR_FILE_EXISTS, ERROR_ALREADY_EXISTS]),
        (EPERM, [ERROR_ACCESS_DENIED, ERROR_CANT_ACCESS_FILE, ERROR_INVALID_ACCESS]),
        (EBUSY, [ERROR_SHARING_VIOLATION, ERROR_LOCK_VIOLATION, ERROR_BUSY, ERROR_PIPE_BUSY]),
        (EXDEV, [ERROR_NOT_SAME_DEVICE]),
        (ENOTEMPTY, [ERROR_DIR_NOT_EMPTY]),
        (ENOTDIR, [ERROR_DIRECTORY]),
        (ELOOP, [ERROR_CANT_RESOLVE_FILENAME]),
        (ENOTSUP, [ERROR_NOT_SUPPORTED, ERROR_INVALID_FUNCTION]),
        (EMLINK, [ERROR_TOO_MANY_LINKS]),
        (ENAMETOOLONG, [ERROR_FILENAME_EXCED_RANGE]),
        (ENOSPC, [ERROR_DISK_FULL, ERROR_HANDLE_DISK_FULL]),
        (EROFS, [ERROR_WRITE_PROTECT]),
        (EINVAL, [ERROR_INVALID_PARAMETER, ERROR_NEGATIVE_SEEK, ERROR_INVALID_HANDLE]),
        (ENOMEM, [ERROR_NOT_ENOUGH_MEMORY, ERROR_OUTOFMEMORY]),
    ]
    var table: [Int32: Int32] = [:]
    for (errnoValue, codes) in groups { for code in codes { table[code] = errnoValue } }
    return table
}()

func errnoForWin32Error(_ error: DWORD) -> Int32 { errnoByWin32Error[Int32(bitPattern: error)] ?? EIO }

func win32Error(_ syscall: String, _ path: String, _ error: DWORD = GetLastError()) -> ProjectFSError {
    fsError(syscall, path, errnoForWin32Error(error))
}

/// "C:/a/b" -> "C:\a\b"; past MAX_PATH an absolute path gets the \\?\ (or \\?\UNC\) prefix. Callers pass
/// normalized paths (PosixPath), which the prefix requires.
func win32Path(_ path: String) -> String {
    let p = path.replacingOccurrences(of: "/", with: "\\")
    guard p.utf16.count >= 248, !p.hasPrefix("\\\\?\\") else { return p }
    if p.hasPrefix("\\\\") { return "\\\\?\\UNC\\" + p.dropFirst(2) }
    if HostPath.root(path, .windows).count == 3 { return "\\\\?\\" + p }
    return p
}

/// A final path from GetFinalPathNameByHandleW ("\\?\C:\x", "\\?\UNC\srv\share\x") in "/" form ("C:/x", "//srv/share/x").
func posixForm(finalPath: String) -> String {
    var p = finalPath
    if p.hasPrefix("\\\\?\\UNC\\") { p = "\\\\" + p.dropFirst(8) } else if p.hasPrefix("\\\\?\\") { p = String(p.dropFirst(4)) }
    return p.replacingOccurrences(of: "\\", with: "/")
}

private func withWide<T>(_ path: String, _ body: (UnsafePointer<WCHAR>) throws -> T) rethrows -> T {
    try win32Path(path).withCString(encodedAs: UTF16.self, body)
}

private func openHandle(_ path: String, access: DWORD, disposition: DWORD, flags: DWORD) -> HANDLE? {
    let h = withWide(path) { CreateFileW($0, access, shareAll, nil, disposition, flags, nil) }
    return h == INVALID_HANDLE_VALUE ? nil : h
}

private func unixNs(_ fileTime: Int64) -> Int128 { (Int128(fileTime) - fileTimeUnixEpoch) * 100 }

/// FileInfo of an open handle; `reparseTag` decides whether a reparse point reads as a symbolic link.
private func handleInfo(_ h: HANDLE, syscall: String, path: String) throws -> FileInfo {
    var byHandle = BY_HANDLE_FILE_INFORMATION()
    guard GetFileInformationByHandle(h, &byHandle) else { throw win32Error(syscall, path) }
    var basic = FILE_BASIC_INFO()
    guard GetFileInformationByHandleEx(h, FileBasicInfo, &basic, DWORD(MemoryLayout<FILE_BASIC_INFO>.size)) else {
        throw win32Error(syscall, path)
    }
    let attributes = byHandle.dwFileAttributes
    var type = attributes & attributeDirectory != 0 ? FileMode.directory : FileMode.regular
    if attributes & attributeReparsePoint != 0 {
        var tag = FILE_ATTRIBUTE_TAG_INFO()
        guard GetFileInformationByHandleEx(h, FileAttributeTagInfo, &tag, DWORD(MemoryLayout<FILE_ATTRIBUTE_TAG_INFO>.size)) else {
            throw win32Error(syscall, path)
        }
        if tag.ReparseTag == reparseTagSymlink || tag.ReparseTag == reparseTagMountPoint { type = FileMode.symbolicLink }
    }
    // Permission bits as libuv reports them: read-only clears the write bits.
    let permissions: UInt32 = attributes & attributeReadOnly != 0 ? 0o444 : 0o666
    let execute: UInt32 = type == FileMode.directory ? 0o111 : 0
    return FileInfo(dev: UInt64(byHandle.dwVolumeSerialNumber),
                    ino: UInt64(byHandle.nFileIndexHigh) << 32 | UInt64(byHandle.nFileIndexLow),
                    size: Int64(byHandle.nFileSizeHigh) << 32 | Int64(byHandle.nFileSizeLow),
                    mode: type | permissions | execute,
                    mtimeNs: unixNs(basic.LastWriteTime.QuadPart), ctimeNs: unixNs(basic.ChangeTime.QuadPart))
}

final class NativeFile {
    private var handle: HANDLE?
    /// A directory handle (opened for `sync`): FlushFileBuffers does not apply, so `sync` reports EISDIR.
    private let isDirectory: Bool
    private init(_ handle: HANDLE, isDirectory: Bool = false) { self.handle = handle; self.isDirectory = isDirectory }
    deinit { close() }

    /// GENERIC_READ, sharing read/write/delete like the C runtime's open; `noFollow` opens a reparse point itself and
    /// refuses it when it is a symbolic link or junction (ELOOP, as O_NOFOLLOW).
    static func openRead(_ path: String, noFollow: Bool = false, syscall: String = "open") throws -> NativeFile {
        guard let h = openHandle(path, access: accessGenericRead, disposition: openExisting,
                                 flags: noFollow ? flagOpenReparsePoint : 0) else { throw win32Error(syscall, path) }
        let file = NativeFile(h)
        if noFollow, try handleInfo(h, syscall: syscall, path: path).isSymbolicLink { throw fsError(syscall, path, ELOOP) }
        return file
    }

    /// FlushFileBuffers needs write access, so files open GENERIC_WRITE; a directory opens for attributes only.
    static func openForSync(_ path: String) throws -> NativeFile {
        if let h = openHandle(path, access: accessGenericWrite, disposition: openExisting, flags: 0) { return NativeFile(h) }
        let error = GetLastError()
        if let h = openHandle(path, access: accessReadAttributes, disposition: openExisting, flags: flagBackupSemantics) {
            let info: FileInfo
            do { info = try handleInfo(h, syscall: "open", path: path) } catch { CloseHandle(h); throw error }
            if info.isDirectory { return NativeFile(h, isDirectory: true) }
            CloseHandle(h)
        }
        throw win32Error("open", path, error)
    }

    /// CREATE_NEW (exclusive) or CREATE_ALWAYS (truncate). NTFS has no mode bits: a mode without owner write
    /// creates the file read-only, as the C runtime's _wopen does.
    static func create(_ path: String, _ creation: NativeFileCreation, mode: UInt32, syscall: String = "open") throws -> NativeFile {
        let attributes: DWORD = mode & 0o200 == 0 ? attributeReadOnly : 0x80   // FILE_ATTRIBUTE_NORMAL
        guard let h = openHandle(path, access: accessGenericWrite, disposition: creation == .exclusive ? createNew : createAlways,
                                 flags: attributes) else { throw win32Error(syscall, path) }
        return NativeFile(h)
    }

    /// Opens or creates `path` with no sharing (share mode 0: every other open fails, EBUSY, until this handle
    /// closes), refusing a reparse point (ELOOP).
    static func lockExclusive(_ path: String) throws -> NativeFile {
        let h = withWide(path) {
            CreateFileW($0, accessGenericRead | accessGenericWrite, 0, nil, openAlways, flagOpenReparsePoint, nil)
        }
        guard let h, h != INVALID_HANDLE_VALUE else { throw win32Error("open", path) }
        let file = NativeFile(h)
        if try !handleInfo(h, syscall: "open", path: path).isFile { throw fsError("open", path, ELOOP) }
        return file
    }

    func read(into buffer: UnsafeMutableRawPointer, count: Int, path: String) throws -> Int {
        var got: DWORD = 0
        guard ReadFile(handle, buffer, DWORD(min(count, Int(Int32.max))), &got, nil) else {
            if GetLastError() == DWORD(ERROR_HANDLE_EOF) { return 0 }
            throw win32Error("read", path)
        }
        return Int(got)
    }

    func writeAll(_ bytes: UnsafeRawBufferPointer, path: String) throws {
        var off = 0
        while off < bytes.count {
            var written: DWORD = 0
            guard WriteFile(handle, bytes.baseAddress! + off, DWORD(min(bytes.count - off, Int(Int32.max))), &written, nil) else {
                throw win32Error("write", path)
            }
            off += Int(written)
        }
    }

    func sync(path: String) throws {
        if isDirectory { throw fsError("fsync", path, EISDIR) }
        guard FlushFileBuffers(handle) else { throw win32Error("fsync", path) }
    }

    func info(path: String) throws -> FileInfo {
        guard let handle else { throw fsError("fstat", path, EBADF) }
        return try handleInfo(handle, syscall: "fstat", path: path)
    }

    func close() {
        if let h = handle { CloseHandle(h); handle = nil }
    }
}

extension ProjectFS {
    /// Stats `path` itself (a symbolic link or junction is reported as a link).
    static func lstatInfo(_ path: String) throws -> FileInfo {
        guard let h = openHandle(path, access: accessReadAttributes, disposition: openExisting,
                                 flags: flagBackupSemantics | flagOpenReparsePoint) else { throw win32Error("lstat", path) }
        defer { CloseHandle(h) }
        return try handleInfo(h, syscall: "lstat", path: path)
    }
    static func statInfo(_ path: String) throws -> FileInfo {
        guard let h = openHandle(path, access: accessReadAttributes, disposition: openExisting,
                                 flags: flagBackupSemantics) else { throw win32Error("stat", path) }
        defer { CloseHandle(h) }
        return try handleInfo(h, syscall: "stat", path: path)
    }
    /// The final path of the file or directory (links resolved, the drive letter form), in "/" form.
    static func realpath(_ path: String) throws -> String {
        guard let h = openHandle(path, access: accessReadAttributes, disposition: openExisting,
                                 flags: flagBackupSemantics) else { throw win32Error("realpath", path) }
        defer { CloseHandle(h) }
        var buffer = [WCHAR](repeating: 0, count: 512)
        var n = GetFinalPathNameByHandleW(h, &buffer, DWORD(buffer.count), 0)   // FILE_NAME_NORMALIZED | VOLUME_NAME_DOS
        if n >= DWORD(buffer.count) {
            buffer = [WCHAR](repeating: 0, count: Int(n) + 1)
            n = GetFinalPathNameByHandleW(h, &buffer, DWORD(buffer.count), 0)
        }
        guard n > 0, n < DWORD(buffer.count) else { throw win32Error("realpath", path) }
        return posixForm(finalPath: String(decoding: buffer[0..<Int(n)], as: UTF16.self))
    }
    static func mkdir(_ path: String) throws {
        guard withWide(path, { CreateDirectoryW($0, nil) }) else { throw win32Error("mkdir", path) }
    }
    static func unlink(_ path: String) throws {
        guard withWide(path, { DeleteFileW($0) }) else { throw win32Error("unlink", path) }
    }
    static func link(_ from: String, _ to: String) throws {
        let ok = withWide(to) { dst in withWide(from) { src in CreateHardLinkW(dst, src, nil) } }
        guard ok else { throw win32Error("link", from) }
    }
    /// MoveFileExW(REPLACE_EXISTING): replaces an existing file at `to` like rename(2).
    static func rename(_ from: String, _ to: String) throws {
        let ok = withWide(from) { src in withWide(to) { dst in MoveFileExW(src, dst, DWORD(MOVEFILE_REPLACE_EXISTING)) } }
        guard ok else { throw win32Error("rename", from) }
    }
    static func readdir(_ path: String) throws -> [String] {
        var data = WIN32_FIND_DATAW()
        let h = withWide(PosixPath.join(path, "*")) { FindFirstFileW($0, &data) }
        guard let h, h != INVALID_HANDLE_VALUE else { throw win32Error("scandir", path) }
        defer { FindClose(h) }
        var names: [String] = []
        repeat {
            let name = withUnsafeBytes(of: data.cFileName) { raw in
                String(decoding: raw.bindMemory(to: WCHAR.self).prefix(while: { $0 != 0 }), as: UTF16.self)
            }
            if name != "." && name != ".." { names.append(name) }
        } while FindNextFileW(h, &data)
        let error = GetLastError()
        guard error == DWORD(ERROR_NO_MORE_FILES) else { throw win32Error("scandir", path, error) }
        return names
    }
    /// fs.mkdtemp(prefix): prefix + 6 random characters from Node's alphabet; retried while the name exists.
    static func makeTemporaryDirectory(_ prefix: String) throws -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        for _ in 0..<100 {
            let path = prefix + String((0..<6).map { _ in alphabet.randomElement()! })
            do { try mkdir(path); return path } catch let e as ProjectFSError where e.code == "EEXIST" { continue }
            catch let e as ProjectFSError { throw ProjectFSError(code: e.code, syscall: "mkdtemp", path: prefix, errno: e.errno) }
        }
        throw fsError("mkdtemp", prefix, EEXIST)
    }
    static func exists(_ path: String) -> Bool {
        withWide(path) { GetFileAttributesW($0) } != DWORD.max   // INVALID_FILE_ATTRIBUTES
    }
}
#endif
