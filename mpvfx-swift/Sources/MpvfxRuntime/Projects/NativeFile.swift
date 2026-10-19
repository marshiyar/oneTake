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
// An open file on the host: a POSIX descriptor (NativeFilePOSIX.swift) or a Win32 handle (NativeFileWin32.swift).
// Everything the runtime reads, writes, hashes or fsyncs goes through it, so the project, library and import code
// above it has no per-platform branches. Failures are ProjectFSError with Node-style errno names; Win32 error codes
// are mapped to the C runtime's errno values (`errnoForWin32Error`).
import Foundation

/// File-type bits of `FileInfo.mode`: the POSIX S_IF* values, which Windows stats synthesize.
enum FileMode {
    static let typeMask: UInt32 = 0o170000
    static let regular: UInt32 = 0o100000
    static let directory: UInt32 = 0o040000
    static let symbolicLink: UInt32 = 0o120000
}

/// lstat/fstat result with nanosecond stamps (Node `{ bigint: true }`). On Windows `dev` is the volume serial number,
/// `ino` the file index, `mtimeNs` LastWriteTime and `ctimeNs` ChangeTime (both since 1970).
struct FileInfo: Equatable {
    var dev: UInt64, ino: UInt64, size: Int64, mode: UInt32
    var mtimeNs: Int128, ctimeNs: Int128
    var isFile: Bool { mode & FileMode.typeMask == FileMode.regular }
    var isDirectory: Bool { mode & FileMode.typeMask == FileMode.directory }
    var isSymbolicLink: Bool { mode & FileMode.typeMask == FileMode.symbolicLink }
    /// fileFingerprint.
    var fingerprint: String { "\(dev):\(ino):\(size):\(mtimeNs):\(ctimeNs)" }
}

/// How `NativeFile.create` treats an existing file: fail with EEXIST (O_EXCL) or truncate it (O_TRUNC).
enum NativeFileCreation { case exclusive, truncate }

/// Shared by both backends: read to the end, write everything.
extension NativeFile {
    func readToEnd(path: String) throws -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = try buf.withUnsafeMutableBytes { try read(into: $0.baseAddress!, count: $0.count, path: path) }
            if n == 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }

    /// Streams the whole file through `body` in chunks of at most `chunk` bytes.
    func forEachChunk(path: String, chunk: Int = 65536, _ body: (ArraySlice<UInt8>) throws -> Void) throws {
        var buf = [UInt8](repeating: 0, count: chunk)
        while true {
            let n = try buf.withUnsafeMutableBytes { try read(into: $0.baseAddress!, count: $0.count, path: path) }
            if n == 0 { break }
            try body(buf[0..<n])
        }
    }

    func writeAll(_ data: Data, path: String) throws {
        try data.withUnsafeBytes { try writeAll($0, path: path) }
    }
}

/// copyFile(src, dst, COPYFILE_EXCL | COPYFILE_FICLONE) without loading the file into memory: never replaces an
/// existing destination, copies the source mode like Node. FICLONE (reflink) is not attempted; this is always a byte
/// copy (see docs/IMPLEMENTATION_NOTES.md).
func copyFileExclusiveStreaming(_ from: String, _ to: String) throws {
    let input = try NativeFile.openRead(from, syscall: "copyfile")
    defer { input.close() }
    let mode = try input.info(path: from).mode & 0o7777
    let output = try NativeFile.create(to, .exclusive, mode: mode, syscall: "copyfile")
    do {
        try input.forEachChunk(path: from, chunk: 1 << 20) { slice in
            try slice.withUnsafeBytes { try output.writeAll($0, path: to) }
        }
        output.close()
    } catch {
        output.close()
        try ProjectFS.rmForce(to)   // the partial copy goes; failing to remove it is reported instead
        throw error
    }
}
