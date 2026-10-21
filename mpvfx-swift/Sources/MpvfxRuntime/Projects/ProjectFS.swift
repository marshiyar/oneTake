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
// The filesystem calls runtime/projects makes through node:fs (lstat with bigint ns stamps, realpath, mkdir,
// rename, unlink, link, copyFile EXCL, readdir, readFile, file and directory fsync). Durable whole-file
// replacement goes through `DurableWrite`; everything else is here, on NativeFile and the per-platform calls in
// NativeFilePOSIX.swift (Glibc/Darwin) and NativeFileWin32.swift (Win32).
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import CRT
#endif

/// A failed system call, carrying the Node-style errno name (`code`, e.g. "ENOENT") and Node's message format.
public struct ProjectFSError: Error, Equatable, CustomStringConvertible {
    public let code: String
    public let syscall: String
    public let path: String
    public let errno: Int32
    public var message: String { "\(code): \(systemErrorMessage(errno).lowercased()), \(syscall) '\(path)'" }
    public var description: String { message }
}

private func systemErrorMessage(_ error: Int32) -> String {
    #if os(Windows)
    var buffer = [CChar](repeating: 0, count: 256)
    strerror_s(&buffer, buffer.count, error)
    return String(cString: buffer)
    #else
    return String(cString: strerror(error))
    #endif
}

let errnoNames: [Int32: String] = {
    let names: [Int32: String] = [ENOENT: "ENOENT", EEXIST: "EEXIST", EISDIR: "EISDIR", EINVAL: "EINVAL", EPERM: "EPERM",
    EACCES: "EACCES", ENOTSUP: "ENOTSUP", EXDEV: "EXDEV", ENOSYS: "ENOSYS", ENOTDIR: "ENOTDIR", ELOOP: "ELOOP",
    ENOTEMPTY: "ENOTEMPTY", EBUSY: "EBUSY", EMLINK: "EMLINK", ENOSPC: "ENOSPC", EROFS: "EROFS"]
    #if os(Windows)
    return names
    #else
    return names.merging([EDQUOT: "EDQUOT"]) { _, name in name }   // no EDQUOT in the Windows C runtime
    #endif
}()

func fsError(_ syscall: String, _ path: String, _ e: Int32 = errno) -> ProjectFSError {
    ProjectFSError(code: errnoNames[e] ?? "E\(e)", syscall: syscall, path: path, errno: e)
}
func isMissing(_ error: Error) -> Bool { (error as? ProjectFSError)?.code == "ENOENT" }

enum ProjectFS {
    /// entry / pathEntry: nil when missing.
    static func entry(_ path: String) throws -> FileInfo? {
        do { return try lstatInfo(path) } catch where isMissing(error) { return nil }
    }
    /// mkdir -p (fs.mkdir recursive).
    static func mkdirRecursive(_ path: String) throws {
        if let e = try entry(path), e.isDirectory { return }
        let parent = PosixPath.dirname(path)
        if parent != path { try mkdirRecursive(parent) }
        do { try mkdir(path) } catch let e as ProjectFSError where e.code == "EEXIST" {}
    }
    /// fs.rm(path, { force: true }) on a file: missing is fine.
    static func rmForce(_ path: String) throws {
        do { try unlink(path) } catch where isMissing(error) {}
    }
    static func readData(_ path: String) throws -> Data {
        let file = try NativeFile.openRead(path)
        defer { file.close() }
        return try file.readToEnd(path: path)
    }
    /// readFile(path, "utf8"): invalid UTF-8 becomes U+FFFD, a BOM is kept.
    static func readUTF8(_ path: String) throws -> String { String(decoding: try readData(path), as: UTF8.self) }
    /// readExact: nil when missing.
    static func readExact(_ path: String) throws -> String? {
        do { return try readUTF8(path) } catch where isMissing(error) { return nil }
    }
    static func fsyncFile(_ path: String) throws {
        let file = try NativeFile.openForSync(path)
        defer { file.close() }
        try file.sync(path: path)
    }

    /// syncDirectory through `DurableWrite.syncDirectory`, ignoring
    /// filesystems that do not allow directory handles.
    static func syncDirectory(_ path: String, _ durableWrite: DurableWrite) throws {
        let tolerated: Set<String> = ["EISDIR", "EINVAL", "EPERM", "EACCES", "ENOTSUP"]
        do { try durableWrite.syncDirectory(path) }
        catch let e as ProjectFSError where tolerated.contains(e.code) {}
    }

    /// copyFile(src, dst, COPYFILE_EXCL): never replaces an existing destination.
    static func copyExclusive(_ from: String, _ to: String) throws {
        try copyFileExclusiveStreaming(from, to)
    }
}

/// The canonical path of an existing file or directory as project stores record it: realpath(3) on POSIX,
/// GetFinalPathNameByHandleW in "/" form on Windows.
public func nativeRealPath(_ path: String) throws -> String { try ProjectFS.realpath(path) }
