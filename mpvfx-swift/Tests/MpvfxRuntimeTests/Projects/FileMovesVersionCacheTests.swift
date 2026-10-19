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
// The file move version cache: FileMoveDigests.hashCount counts full hashes, so a cached
// version must not rehash an unchanged file.
import Foundation
#if os(Windows)
import WinSDK
#endif
import XCTest
@testable import MpvfxRuntime

final class FileMovesVersionCacheTests: XCTestCase {
    let roots = TempRoots()
    var reads: Int { FileMoveDigests.lock.withLock { FileMoveDigests.hashCount } }
    override func setUp() { FileMoveDigests.lock.withLock { FileMoveDigests.hashCount = 0 } }
    override func tearDown() { roots.cleanup() }

    /// Let the file's timestamps age past the racy window so its digest may be cached.
    func settle() { Thread.sleep(forTimeInterval: 0.25) }

    func fixture() throws -> String {
        let root = try roots.make("mpvfx-media-version-cache-")
        try writeText(join(root, "a.mov"), "original bytes")
        settle()
        return root
    }

    /// Restores the exact mtime `info` recorded: utimensat on POSIX (nanoseconds), SetFileTime on Windows (its
    /// 100 ns ticks, the resolution `info` was read at).
    func restoreMtime(_ path: String, _ info: FileInfo) throws {
        #if os(Windows)
        let ticks = UInt64(info.mtimeNs / 100 + 116_444_736_000_000_000)   // 100 ns ticks since 1601
        var mtime = FILETIME(dwLowDateTime: DWORD(truncatingIfNeeded: ticks), dwHighDateTime: DWORD(ticks >> 32))
        let h = win32Path(path).withCString(encodedAs: UTF16.self) {
            // FILE_WRITE_ATTRIBUTES, FILE_SHARE_READ | WRITE | DELETE, OPEN_EXISTING
            CreateFileW($0, DWORD(0x0100), DWORD(0x7), nil, DWORD(3), 0, nil)
        }
        guard let h, h != INVALID_HANDLE_VALUE else { throw fsError("utimes", path) }
        defer { CloseHandle(h) }
        guard SetFileTime(h, nil, nil, &mtime) else { throw fsError("utimes", path) }
        #else
        var times = [timespec(tv_sec: 0, tv_nsec: (1 << 30) - 2 /* Linux UTIME_OMIT */),
                     timespec(tv_sec: Int(info.mtimeNs / 1_000_000_000), tv_nsec: Int(info.mtimeNs % 1_000_000_000))]
        guard utimensat(AT_FDCWD, path, &times, 0) == 0 else { throw fsError("utimes", path) }
        #endif
    }

    /// Rewrites the file in place (same file, truncated first), as writeFile does: the identity stays, the bytes change.
    func overwriteInPlace(_ path: String, _ text: String) throws {
        guard let handle = FileHandle(forWritingAtPath: path) else { throw fsError("open", path) }
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(text.utf8))
    }

    func testReusesADigestOnlyWhileTheOpenedFileAndPathnameRetainTheSameExactVersion() throws {
        let root = try fixture()
        let first = try binaryFileVersion(root, "a.mov")
        XCTAssertEqual(try binaryFileVersion(root, "a.mov"), first)
        XCTAssertEqual(try binaryFileVersion(root, "a.mov"), first)
        XCTAssertEqual(reads, 1)
        try ProjectFS.unlink(join(root, "a.mov"))
        XCTAssertNil(try binaryFileVersion(root, "a.mov"))
    }

    func testReHashesSameSizeContentEditsEvenWhenTheOriginalModificationTimeIsRestored() throws {
        let root = try fixture()
        let first = try binaryFileVersion(root, "a.mov")
        let before = try ProjectFS.lstatInfo(join(root, "a.mov"))
        try overwriteInPlace(join(root, "a.mov"), "modified bytes")   // writeFile keeps the inode
        try restoreMtime(join(root, "a.mov"), before)
        XCTAssertEqual(try ProjectFS.lstatInfo(join(root, "a.mov")).size, before.size)
        XCTAssertNotEqual(try binaryFileVersion(root, "a.mov"), first)
        XCTAssertEqual(reads, 2)
    }

    func testNeverReusesALocationsDigestForAReplacementInodeWithRestoredTime() throws {
        let root = try fixture()
        let first = try binaryFileVersion(root, "a.mov")
        let before = try ProjectFS.lstatInfo(join(root, "a.mov"))
        try writeText(join(root, "replacement.mov"), "replaced bytes")
        try restoreMtime(join(root, "replacement.mov"), before)
        try ProjectFS.rename(join(root, "replacement.mov"), join(root, "a.mov"))
        XCTAssertNotEqual(try binaryFileVersion(root, "a.mov"), first)
        XCTAssertEqual(reads, 2)
    }

    func testNeverCachesADigestWhileTheFilesTimestampsAreRacy() throws {
        let root = try roots.make("mpvfx-media-version-cache-")
        try writeText(join(root, "a.mov"), "original bytes")
        let first = try binaryFileVersion(root, "a.mov")
        try overwriteInPlace(join(root, "a.mov"), "modified bytes")
        let second = try binaryFileVersion(root, "a.mov")
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(try binaryFileVersion(root, "a.mov"), second)
        XCTAssertEqual(reads, 3)
    }

    func testSharesAValidatedDigestBetweenHardlinksButReHashesWhenLinkChangesUpdateCtime() throws {
        let root = try fixture()
        let first = try binaryFileVersion(root, "a.mov")
        try ProjectFS.link(join(root, "a.mov"), join(root, "b.mov"))
        settle()
        XCTAssertEqual(try binaryFileVersion(root, "a.mov"), first)
        XCTAssertEqual(try binaryFileVersion(root, "b.mov"), first)
        XCTAssertEqual(reads, 2)
        try ProjectFS.unlink(join(root, "a.mov"))
        XCTAssertEqual(try binaryFileVersion(root, "b.mov"), first)
        XCTAssertEqual(reads, 3)
    }
}
