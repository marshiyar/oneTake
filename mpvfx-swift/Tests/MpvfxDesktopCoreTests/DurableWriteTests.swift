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
import XCTest
@testable import MpvfxDesktopCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import WinSDK
#endif

final class DurableWriteTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/test-tmp/mpvfx-dw-\(UUID().uuidString)")   // stay inside the package
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }
    func entries() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() }

    func testWriteReplaceAndNoTempLeft() throws {
        let target = dir.appendingPathComponent("project.json").path
        let w = NativeDurableWrite()
        try w.write(Data("one".utf8), to: target, tempName: ".project.json.tmp", preserveMode: false, beforeRename: {})
        try w.write(Data("two-longer".utf8), to: target, tempName: ".project.json.tmp", preserveMode: true, beforeRename: {})
        XCTAssertEqual(FileManager.default.contents(atPath: target), Data("two-longer".utf8))
        try w.write(Data(), to: target)
        XCTAssertEqual(FileManager.default.contents(atPath: target), Data())
        XCTAssertEqual(try entries(), ["project.json"])
    }

    /// Win32 file calls stop at MAX_PATH (260 with the NUL) unless the path is an extended-length "\\?\" path, which
    /// takes no "/", "." or ".." (learn.microsoft.com, "Maximum Path Length Limitation").
    func testWin32PathsAreExtendedLengthForAbsoluteDrivesAndShares() {
        XCTAssertEqual(NativeDurableWrite.win32Path("C:/Users/me/Film/.studio/project.json"), #"\\?\C:\Users\me\Film\.studio\project.json"#)
        XCTAssertEqual(NativeDurableWrite.win32Path(#"D:\a\b.json"#), #"\\?\D:\a\b.json"#)
        XCTAssertEqual(NativeDurableWrite.win32Path("//server/share/Film/project.json"), #"\\?\UNC\server\share\Film\project.json"#)
        XCTAssertEqual(NativeDurableWrite.win32Path(#"\\?\C:\x"#), #"\\?\C:\x"#, "already extended")
        // Not absolute, or not normalized: the prefix would turn "." and ".." into literal names, so they stay as they are.
        XCTAssertEqual(NativeDurableWrite.win32Path("relative/project.json"), #"relative\project.json"#)
        XCTAssertEqual(NativeDurableWrite.win32Path("C:/a/../b.json"), #"C:\a\..\b.json"#)
        XCTAssertEqual(NativeDurableWrite.win32Path("C:/a/./b.json"), #"C:\a\.\b.json"#)
    }

    func testWriteCreatesAndReplacesAFileWhosePathIsLongerThanMaxPath() throws {
        // A folder short enough to create with any API (under MAX_PATH - 12) holding a file whose full path passes 260,
        // as a library project's transaction journal does (.../Projects/<uuid>/.hyperframes/studio-transactions/<sha256>.json).
        let segments = max(1, (200 - dir.path.utf16.count) / 41 + 1)
        let folder = dir.path + String(repeating: "/" + String(repeating: "d", count: 40), count: segments)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let target = folder + "/" + String(repeating: "f", count: 64) + ".json"
        XCTAssertGreaterThan(target.utf16.count, 260)
        let w = NativeDurableWrite()
        try w.write(Data("one".utf8), to: target, tempName: ".\(UUID().uuidString.lowercased()).studio-transaction.tmp", preserveMode: true, beforeRename: {})
        try w.write(Data("two".utf8), to: target, tempName: ".\(UUID().uuidString.lowercased()).studio-transaction.tmp", preserveMode: true, beforeRename: {})
        try w.syncDirectory(folder)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder), [String(repeating: "f", count: 64) + ".json"])
        XCTAssertEqual(FileManager.default.contents(atPath: target), Data("two".utf8))
    }

    func testTempUsesTempNameInTargetDirectory() throws {
        let target = dir.appendingPathComponent("p.json").path
        var seen: [String] = []
        try NativeDurableWrite().write(Data("x".utf8), to: target, tempName: "p.json.custom-tmp", preserveMode: false) {
            seen = try self.entries()
        }
        XCTAssertEqual(seen, ["p.json.custom-tmp"], "temp exists, target not yet, right before rename")
        XCTAssertEqual(NativeDurableWrite.tempPath(for: "/a/b/p.json", tempName: "t"), "/a/b/t")
    }

    #if os(Windows)
    func attributes(_ p: String) -> DWORD { p.withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) } }

    /// NTFS has no mode bits: preserveMode keeps the replaced file's attributes (ReplaceFileW), a plain write does not.
    func testPreserveModeKeepsExistingAttributes() throws {
        let target = dir.appendingPathComponent("lib.db").path
        let hidden = DWORD(FILE_ATTRIBUTE_HIDDEN)
        let w = NativeDurableWrite()
        try w.write(Data("a".utf8), to: target, tempName: "t1", preserveMode: true, beforeRename: {})
        XCTAssertEqual(attributes(target) & hidden, 0, "new file")
        XCTAssertTrue(target.withCString(encodedAs: UTF16.self) { SetFileAttributesW($0, hidden) })
        try w.write(Data("b".utf8), to: target, tempName: "t2", preserveMode: true, beforeRename: {})
        XCTAssertEqual(attributes(target) & hidden, hidden, "preserved")
        XCTAssertEqual(FileManager.default.contents(atPath: target), Data("b".utf8))
        try w.write(Data("c".utf8), to: target, tempName: "t3", preserveMode: false, beforeRename: {})
        XCTAssertEqual(attributes(target) & hidden, 0, "not preserved -> plain attributes")
        XCTAssertEqual(try entries(), ["lib.db"])
    }
    #else
    func mode(_ p: String) -> mode_t { var st = stat(); _ = stat(p, &st); return st.st_mode & 0o7777 }

    func testNewFileIs0600AndPreserveModeKeepsExisting() throws {
        let target = dir.appendingPathComponent("lib.db").path
        let w = NativeDurableWrite()
        try w.write(Data("a".utf8), to: target, tempName: "t1", preserveMode: true, beforeRename: {})
        XCTAssertEqual(mode(target), 0o600, "new file")
        chmod(target, 0o644)
        try w.write(Data("b".utf8), to: target, tempName: "t2", preserveMode: true, beforeRename: {})
        XCTAssertEqual(mode(target), 0o644, "preserved")
        try w.write(Data("c".utf8), to: target, tempName: "t3", preserveMode: false, beforeRename: {})
        XCTAssertEqual(mode(target), 0o600, "not preserved -> 0600")
    }
    #endif

    func testBeforeRenameThrowDeletesTempAndRethrows() throws {
        struct Boom: Error {}
        let target = dir.appendingPathComponent("p.json").path
        try NativeDurableWrite().write(Data("old".utf8), to: target)
        XCTAssertThrowsError(try NativeDurableWrite().write(Data("new".utf8), to: target, tempName: "p.tmp", preserveMode: true) { throw Boom() }) {
            XCTAssertTrue($0 is Boom)
        }
        XCTAssertEqual(try entries(), ["p.json"])
        XCTAssertEqual(FileManager.default.contents(atPath: target), Data("old".utf8))
    }

    func testMissingDirectoryThrowsAndLeavesNothing() {
        let target = "/nonexistent-\(UUID().uuidString)/x.json"
        XCTAssertThrowsError(try NativeDurableWrite().write(Data("x".utf8), to: target)) { e in
            #if os(Windows)
            XCTAssertEqual((e as? DurableWriteError)?.step, "CreateFileW")
            #else
            XCTAssertEqual((e as? DurableWriteError)?.step, "open")
            #endif
        }
    }

    func testSyncDirectoryAndIgnorableErrnos() throws {
        try NativeDurableWrite().syncDirectory(dir.path)
        for e in [EISDIR, EINVAL, EPERM, EACCES, ENOTSUP] { XCTAssertTrue(NativeDurableWrite.isIgnorableDirectorySyncError(e)) }
        XCTAssertFalse(NativeDurableWrite.isIgnorableDirectorySyncError(EIO))
        XCTAssertThrowsError(try NativeDurableWrite().syncDirectory("/nonexistent-\(UUID().uuidString)"))   // ENOENT is real
    }
}
