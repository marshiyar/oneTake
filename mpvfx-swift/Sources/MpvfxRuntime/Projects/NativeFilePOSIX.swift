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
// NativeFile and the path-level ProjectFS calls on POSIX (Linux, macOS): open/read/write/fsync/fstat on a descriptor,
// lstat, realpath(3), mkdir, unlink, link, readdir, rename, mkdtemp, access.
#if !os(Windows)
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class NativeFile {
    private var fd: Int32
    private init(_ fd: Int32) { self.fd = fd }
    deinit { close() }

    /// O_RDONLY; `noFollow` refuses a symbolic link (ELOOP).
    static func openRead(_ path: String, noFollow: Bool = false, syscall: String = "open") throws -> NativeFile {
        let fd = open(path, O_RDONLY | O_CLOEXEC | (noFollow ? O_NOFOLLOW : 0))
        guard fd >= 0 else { throw fsError(syscall, path) }
        return NativeFile(fd)
    }

    /// A descriptor `sync` can flush: files and directories, opened read-only.
    static func openForSync(_ path: String) throws -> NativeFile { try openRead(path) }

    /// O_WRONLY | O_CREAT and O_EXCL or O_TRUNC, created with `mode` & ~umask.
    static func create(_ path: String, _ creation: NativeFileCreation, mode: UInt32, syscall: String = "open") throws -> NativeFile {
        let fd = open(path, O_WRONLY | O_CREAT | O_CLOEXEC | (creation == .exclusive ? O_EXCL : O_TRUNC), mode_t(mode))
        guard fd >= 0 else { throw fsError(syscall, path) }
        return NativeFile(fd)
    }

    /// Opens (creating 0600) `path`, refusing a symbolic link, and takes an exclusive non-blocking flock (EWOULDBLOCK
    /// while another open file description holds it).
    static func lockExclusive(_ path: String) throws -> NativeFile {
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw fsError("open", path) }
        let file = NativeFile(fd)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw fsError("flock", path) }
        return file
    }

    /// Bytes read into `buffer`; 0 at end of file.
    func read(into buffer: UnsafeMutableRawPointer, count: Int, path: String) throws -> Int {
        while true {
            let n = Foundation.read(fd, buffer, count)
            if n >= 0 { return n }
            if errno != EINTR { throw fsError("read", path) }
        }
    }

    func writeAll(_ bytes: UnsafeRawBufferPointer, path: String) throws {
        var off = 0
        while off < bytes.count {
            let n = Foundation.write(fd, bytes.baseAddress! + off, bytes.count - off)
            if n < 0 { if errno == EINTR { continue }; throw fsError("write", path) }
            off += n
        }
    }

    func sync(path: String) throws {
        guard fsync(fd) == 0 else { throw fsError("fsync", path) }
    }

    func info(path: String) throws -> FileInfo {
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw fsError("fstat", path) }
        return FileInfo(st)
    }

    func close() {
        if fd >= 0 { _ = Foundation.close(fd); fd = -1 }
    }
}

extension FileInfo {
    init(_ st: stat) {
        dev = UInt64(st.st_dev); ino = UInt64(st.st_ino); size = Int64(st.st_size); mode = UInt32(st.st_mode)
        #if canImport(Darwin)
        mtimeNs = Int128(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int128(st.st_mtimespec.tv_nsec)
        ctimeNs = Int128(st.st_ctimespec.tv_sec) * 1_000_000_000 + Int128(st.st_ctimespec.tv_nsec)
        #else
        mtimeNs = Int128(st.st_mtim.tv_sec) * 1_000_000_000 + Int128(st.st_mtim.tv_nsec)
        ctimeNs = Int128(st.st_ctim.tv_sec) * 1_000_000_000 + Int128(st.st_ctim.tv_nsec)
        #endif
    }
}

extension ProjectFS {
    static func lstatInfo(_ path: String) throws -> FileInfo {
        var st = stat()
        guard lstat(path, &st) == 0 else { throw fsError("lstat", path) }
        return FileInfo(st)
    }
    static func statInfo(_ path: String) throws -> FileInfo {
        var st = stat()
        guard stat(path, &st) == 0 else { throw fsError("stat", path) }
        return FileInfo(st)
    }
    static func realpath(_ path: String) throws -> String {
        guard let p = Foundation.realpath(path, nil) else { throw fsError("realpath", path) }
        defer { free(p) }
        return String(cString: p)
    }
    static func mkdir(_ path: String) throws {
        guard Foundation.mkdir(path, 0o777) == 0 else { throw fsError("mkdir", path) }
    }
    static func unlink(_ path: String) throws {
        guard Foundation.unlink(path) == 0 else { throw fsError("unlink", path) }
    }
    static func link(_ from: String, _ to: String) throws {
        guard Foundation.link(from, to) == 0 else { throw fsError("link", from) }
    }
    /// rename(2): replaces an existing file at `to`.
    static func rename(_ from: String, _ to: String) throws {
        guard Foundation.rename(from, to) == 0 else { throw fsError("rename", from) }
    }
    static func readdir(_ path: String) throws -> [String] {
        guard let d = opendir(path) else { throw fsError("scandir", path) }
        defer { closedir(d) }
        var names: [String] = []
        while let ent = Foundation.readdir(d) {
            let name = withUnsafeBytes(of: ent.pointee.d_name) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }
    /// fs.mkdtemp(prefix): prefix + 6 random characters, created 0700.
    static func makeTemporaryDirectory(_ prefix: String) throws -> String {
        var template = Array((prefix + "XXXXXX").utf8CString)
        guard let p = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) else { throw fsError("mkdtemp", prefix) }
        return String(cString: p)
    }
    /// access(path, F_OK).
    static func exists(_ path: String) -> Bool { access(path, F_OK) == 0 }
}
#endif
