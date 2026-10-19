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
// Shared helpers for the file-move and file-transaction tests.
import Foundation
import XCTest
import MpvfxShared
@testable import MpvfxRuntime
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import CRT
#endif

/// Test-only DurableWrite (the shipped POSIX/Windows versions live in MpvfxDesktopCore).
/// `directorySyncError` lets fileMoves.directorySync.test's mocked directory `open` failure be injected.
final class TestDurableWrite: DurableWrite, @unchecked Sendable {
    private let lock = NSLock()
    private var _directorySyncError: String?
    var directorySyncError: String? {
        get { lock.withLock { _directorySyncError } }
        set { lock.withLock { _directorySyncError = newValue } }
    }
    init(directorySyncError: String? = nil) { _directorySyncError = directorySyncError }

    func write(_ data: Data, to path: String, tempName: String, preserveMode: Bool, beforeRename: () throws -> Void) throws {
        let temporary = PosixPath.join(PosixPath.dirname(path), tempName)
        var mode: UInt32 = 0o600
        if preserveMode {
            do { mode = try ProjectFS.statInfo(path).mode & 0o7777 } catch where isMissing(error) {}
        }
        let file = try NativeFile.create(temporary, .exclusive, mode: mode)
        var renamed = false
        defer { if !renamed { try? ProjectFS.unlink(temporary) } }
        do {
            defer { file.close() }
            try file.writeAll(data, path: temporary)
            try file.sync(path: temporary)
        }
        try beforeRename()
        try ProjectFS.rename(temporary, path)
        renamed = true
        try ProjectFS.syncDirectory(PosixPath.dirname(path), self)
    }

    func syncDirectory(_ path: String) throws {
        if let code = directorySyncError {
            let e: Int32 = ["EISDIR": EISDIR, "EPERM": EPERM, "EACCES": EACCES, "EINVAL": EINVAL, "ENOTSUP": ENOTSUP, "EIO": EIO][code]!
            throw ProjectFSError(code: code, syscall: "open", path: path, errno: e)
        }
        let file = try NativeFile.openForSync(path)
        defer { file.close() }
        try file.sync(path: path)
    }
}

/// mkdtemp under swift/.build/port-tmp (never the system temp directory).
func makeTempDir(_ prefix: String, file: String = #filePath) throws -> String {
    var url = URL(fileURLWithPath: file)
    while url.lastPathComponent != "Tests" { url.deleteLastPathComponent() }
    let dir = url.deletingLastPathComponent().appendingPathComponent(".build/port-tmp/\(prefix)\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return try ProjectFS.realpath(dir.path)
}

/// Removes every directory a test created.
final class TempRoots {
    private(set) var roots: [String] = []
    func make(_ prefix: String) throws -> String { let r = try makeTempDir(prefix); roots.append(r); return r }
    func cleanup() { for r in roots { try? FileManager.default.removeItem(atPath: r) }; roots = [] }
}

func join(_ parts: String...) -> String { parts.dropFirst().reduce(parts[0]) { PosixPath.join($0, $1) } }
func writeText(_ path: String, _ s: String) throws { try writeBytes(path, Data(s.utf8)) }
/// fs.writeFile: truncate in place (same inode), create with 0666 & ~umask.
func writeBytes(_ path: String, _ d: Data) throws {
    let file = try NativeFile.create(path, .truncate, mode: 0o666)
    defer { file.close() }
    try file.writeAll(d, path: path)
}
func readText(_ path: String) throws -> String { try ProjectFS.readUTF8(path) }
func readBytes(_ path: String) throws -> Data { try ProjectFS.readData(path) }
func mkdirP(_ path: String) throws { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
func makeSymlink(_ target: String, at path: String) throws { try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target) }
func rmrf(_ path: String) throws { try FileManager.default.removeItem(atPath: path) }
func isENOENT(_ body: () throws -> Any) -> Bool { do { _ = try body(); return false } catch { return isMissing(error) } }

/// `rejects.toThrow(/pattern/flags)`.
func assertThrows<T>(_ body: @autoclosure () throws -> T, _ pattern: String, caseInsensitive: Bool = false,
                     file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try body(); XCTFail("expected a throw matching /\(pattern)/", file: file, line: line) }
    catch {
        let message = projectsErrorMessage(error)
        let re = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        XCTAssertNotNil(re.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
                        "\(message) !~ /\(pattern)/", file: file, line: line)
    }
}

func store(_ root: String, _ dw: DurableWrite = TestDurableWrite(),
           afterPrepared: ((DurableFileTransactionReceipt) throws -> Void)? = nil,
           afterTargetWrite: ((Int, DurableFileTransactionChange) throws -> Void)? = nil,
           afterMoveLink: ((Int, ProjectFileMove) throws -> Void)? = nil,
           afterMove: ((Int, ProjectFileMove) throws -> Void)? = nil,
           now: (() -> Date)? = nil) -> DurableFileTransactionStore {
    DurableFileTransactionStore(.init(projectRoot: root, durableWrite: dw, afterPrepared: afterPrepared, afterTargetWrite: afterTargetWrite,
                                      afterMoveLink: afterMoveLink, afterMove: afterMove, now: now))
}

struct PowerLoss: Error, CustomStringConvertible { var description: String; init(_ s: String) { description = s } }

/// Runs `body` on a new thread; `join()` waits and returns its result.
final class Spawned<T>: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var result: Result<T, Error>?
    init(_ body: @escaping () throws -> T) {
        Thread { self.result = Result(catching: body); self.done.signal() }.start()
    }
    func join() -> Result<T, Error> { done.wait(); return result! }
}
