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
import Foundation
import XCTest
@testable import MpvfxBackend
@testable import MpvfxDesktopCore
@testable import MpvfxRuntime
import MpvfxShared
#if os(Windows)
import WinSDK
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

final class SaveFailureMessageTests: XCTestCase {
    /// Setup writes succeed; an armed save fails at the actual durable-write boundary.
    private final class FailingWrite: DurableWrite, @unchecked Sendable {
        let base = NativeDurableWrite()
        let lock = NSLock()
        var failure: Error?
        func arm(_ error: Error) { lock.withLock { failure = error } }
        func write(_ data: Data, to path: String, tempName: String, preserveMode: Bool, beforeRename: () throws -> Void) throws {
            if let error = lock.withLock({ failure }) { throw error }
            try base.write(data, to: path, tempName: tempName, preserveMode: preserveMode, beforeRename: beforeRename)
        }
        func syncDirectory(_ path: String) throws { try base.syncDirectory(path) }
    }

    private func check(_ code: String, _ number: Int32, _ reason: DesktopError.SaveFailure, action: String,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let root = NSTemporaryDirectory() + "mpvfx-save-failure-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let writer = FailingWrite()
        let backend = RuntimeDesktopBackend(userData: root + "/user", durableWrite: writer)
        let project = try backend.createProject(name: "My Film", directory: root + "/My Film")
        var doc = try parseNativeProjectDocument(try NativeJSONValue.parse(project.content))
        doc.canvas.width += 10
        let content = try serializeNativeProjectDocument(doc)
        #if !os(Windows)
        XCTAssertEqual(fsError("write", project.directory, number).code, code, file: file, line: line)
        #endif
        // ProjectFS and the native durable writer have distinct error types. Both reach saveProject's mapper.
        let errors: [Error] = [
            ProjectFSError(code: code, syscall: "write", path: project.directory + "/.studio/temporary", errno: number),
            DurableWriteError(step: "write", path: project.directory + "/.studio/temporary", code: number),
        ]
        for error in errors {
            writer.arm(error)
            XCTAssertThrowsError(try backend.saveProject(id: project.id, content: content), file: file, line: line) { error in
                guard let error = error as? DesktopError else { return XCTFail("Untyped error: \(error)", file: file, line: line) }
                XCTAssertEqual(error.name, "SaveError", file: file, line: line)
                XCTAssertEqual(error.saveFailure, reason, file: file, line: line)
                XCTAssertTrue(error.message.contains(project.directory), file: file, line: line)
                XCTAssertTrue(error.message.contains(action), error.message, file: file, line: line)
                XCTAssertTrue(error.message.contains("kept in memory"), file: file, line: line)
                XCTAssertFalse(error.message.contains(".studio"), file: file, line: line)
                XCTAssertFalse(error.message.contains(code), file: file, line: line)
            }
            XCTAssertEqual(try String(contentsOfFile: project.directory + "/.studio/project.json", encoding: .utf8), project.content)
        }
    }

    #if os(Windows)
    func testDiskFull() throws { try check("ENOSPC", ERROR_DISK_FULL, .diskFull, action: "Free some space") }
    func testQuotaExceeded() throws { try check("EDQUOT", ERROR_DISK_QUOTA_EXCEEDED, .quotaExceeded, action: "increase the quota") }
    func testReadOnly() throws { try check("EROFS", ERROR_WRITE_PROTECT, .readOnly, action: "writable") }
    func testAccessDenied() throws { try check("EACCES", ERROR_ACCESS_DENIED, .permissionDenied, action: "permission to write") }
    func testOperationNotPermitted() throws { try check("EPERM", ERROR_ACCESS_DENIED, .permissionDenied, action: "permission to write") }
    func testFolderMissing() throws { try check("ENOENT", ERROR_PATH_NOT_FOUND, .folderMissing, action: "Reconnect its drive") }
    #else
    func testDiskFull() throws { try check("ENOSPC", ENOSPC, .diskFull, action: "Free some space") }
    func testQuotaExceeded() throws { try check("EDQUOT", EDQUOT, .quotaExceeded, action: "increase the quota") }
    func testReadOnly() throws { try check("EROFS", EROFS, .readOnly, action: "writable") }
    func testAccessDenied() throws { try check("EACCES", EACCES, .permissionDenied, action: "permission to write") }
    func testOperationNotPermitted() throws { try check("EPERM", EPERM, .permissionDenied, action: "permission to write") }
    func testFolderMissing() throws { try check("ENOENT", ENOENT, .folderMissing, action: "Reconnect its drive") }
    #endif

    func testRemovedProjectFolderNamesTheFolderAndKeepsTheSavedRevision() throws {
        let root = NSTemporaryDirectory() + "mpvfx-missing-save-folder-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let backend = RuntimeDesktopBackend(userData: root + "/user")
        let project = try backend.createProject(name: "Film", directory: root + "/Film")
        var doc = try parseNativeProjectDocument(try NativeJSONValue.parse(project.content))
        doc.canvas.width += 10
        let content = try serializeNativeProjectDocument(doc)
        try FileManager.default.moveItem(atPath: project.directory, toPath: root + "/Disconnected")
        XCTAssertThrowsError(try backend.saveProject(id: project.id, content: content)) { error in
            let error = error as? DesktopError
            XCTAssertEqual(error?.saveFailure, .folderMissing)
            XCTAssertTrue(error?.message.contains(project.directory) == true)
        }
        XCTAssertEqual(try String(contentsOfFile: root + "/Disconnected/.studio/project.json", encoding: .utf8), project.content)
    }
}
