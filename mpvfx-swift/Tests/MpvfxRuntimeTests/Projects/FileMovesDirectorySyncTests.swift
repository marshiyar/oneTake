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
// File moves and directory sync failures. The injected error
// comes from TestDurableWrite.syncDirectory (the route all directory syncs take).
import Foundation
import XCTest
@testable import MpvfxRuntime

final class FileMovesDirectorySyncTests: XCTestCase {
    let roots = TempRoots()
    override func tearDown() { roots.cleanup() }

    /// it.each(["EISDIR", "EPERM", "EACCES"])
    func testPreservesForwardAndRollbackBehaviorWhenDirectoryOpenFails() throws {
        for error in ["EISDIR", "EPERM", "EACCES"] {
            let root = try roots.make("mpvfx-directory-sync-")
            try mkdirP(join(root, "media"))
            let bytes = Data([0, 255, 128, 17, 192])
            try writeBytes(join(root, "media/a.mov"), bytes)
            let move = ProjectFileMove(from: "media/a.mov", to: "media/b.mov", expectedVersion: try binaryFileVersion(root, "media/a.mov")!)
            let dw = TestDurableWrite(directorySyncError: error)
            try applyFileMove(root, move, .forward, durableWrite: dw)
            XCTAssertEqual(try readBytes(join(root, "media/b.mov")), bytes, error)
            try applyFileMove(root, move, .rollback, durableWrite: dw)
            XCTAssertEqual(try readBytes(join(root, "media/a.mov")), bytes, error)
        }
    }

    /// An error outside the tolerated set still fails.
    func testUntoleratedDirectorySyncErrorPropagates() throws {
        let root = try roots.make("mpvfx-directory-sync-")
        try writeBytes(join(root, "a.mov"), Data([1]))
        let move = ProjectFileMove(from: "a.mov", to: "b.mov", expectedVersion: try binaryFileVersion(root, "a.mov")!)
        assertThrows(try applyFileMove(root, move, .forward, durableWrite: TestDurableWrite(directorySyncError: "EIO")), "EIO")
    }
}
