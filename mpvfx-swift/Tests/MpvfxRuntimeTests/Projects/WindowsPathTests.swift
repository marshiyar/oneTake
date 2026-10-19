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
// PosixPath with Windows roots (drive letters, UNC shares, backslashes), checked on every host.
import XCTest
import MpvfxShared
@testable import MpvfxRuntime

final class WindowsPathTests: XCTestCase {
    func testRoots() {
        XCTAssertEqual(HostPath.root("C:\\Users\\a", .windows), "C:/")
        XCTAssertEqual(HostPath.root("d:/x", .windows), "D:/")
        XCTAssertEqual(HostPath.root("\\\\server\\share\\dir\\f", .windows), "//server/share/")
        XCTAssertEqual(HostPath.root("/x", .windows), "/")
        XCTAssertEqual(HostPath.root("C:relative", .windows), "")
        XCTAssertEqual(HostPath.root("x\\y", .windows), "")
        XCTAssertEqual(HostPath.root("C:\\x", .posix), "")
        XCTAssertEqual(HostPath.root("\\x", .posix), "")
        XCTAssertTrue(PosixPath.isAbsolute("C:/a", .windows))
        XCTAssertFalse(PosixPath.isAbsolute("C:/a", .posix))
    }

    func testNormalizeAndJoin() {
        XCTAssertEqual(PosixPath.normalize("C:\\a\\.\\b\\..\\c\\", .windows), "C:/a/c/")
        XCTAssertEqual(PosixPath.normalize("C:/a/../..", .windows), "C:/")
        XCTAssertEqual(PosixPath.normalize("\\\\srv\\share\\a\\..\\b", .windows), "//srv/share/b")
        XCTAssertEqual(PosixPath.normalize("a\\..\\..\\b", .windows), "../b")
        XCTAssertEqual(PosixPath.join(["C:\\Users\\me\\Projects", "MpVFX", ".studio/project.json"], .windows),
                       "C:/Users/me/Projects/MpVFX/.studio/project.json")
        XCTAssertEqual(PosixPath.join(["a\\b", "c"], .posix), "a\\b/c", "POSIX keeps backslashes in names")
    }

    func testResolve() {
        XCTAssertEqual(PosixPath.resolve(["x", "..\\y"], cwd: "C:\\work", .windows), "C:/work/y")
        XCTAssertEqual(PosixPath.resolve(["D:/data", "f.mov"], cwd: "C:/work", .windows), "D:/data/f.mov")
        XCTAssertEqual(PosixPath.resolve(["/top"], cwd: "E:\\work", .windows), "E:/top", "rooted path takes the cwd's drive")
        XCTAssertEqual(PosixPath.resolve(["f"], cwd: "\\\\srv\\share\\dir", .windows), "//srv/share/dir/f")
        XCTAssertEqual(PosixPath.resolve(["../../.."], cwd: "C:/a", .windows), "C:/")
    }

    func testRelative() {
        XCTAssertEqual(PosixPath.relative("C:/Lib", "c:/lib/Media/a.mov", cwd: "C:/", .windows), "Media/a.mov")
        XCTAssertEqual(PosixPath.relative("C:/Lib/x", "C:/Lib/y/z", cwd: "C:/", .windows), "../y/z")
        XCTAssertEqual(PosixPath.relative("C:/Lib", "D:/Lib/a", cwd: "C:/", .windows), "D:/Lib/a", "other drive: absolute")
        XCTAssertEqual(PosixPath.relative("C:/Lib", "C:/Lib", cwd: "C:/", .windows), "")
    }

    func testDirnameBasename() {
        XCTAssertEqual(PosixPath.dirname("C:\\a\\b.txt", .windows), "C:/a")
        XCTAssertEqual(PosixPath.dirname("C:/a", .windows), "C:/")
        XCTAssertEqual(PosixPath.dirname("C:/", .windows), "C:/")
        XCTAssertEqual(PosixPath.dirname("//srv/share/a/", .windows), "//srv/share/")
        XCTAssertEqual(PosixPath.basename("C:/a/b.txt/", .windows), "b.txt")
        XCTAssertEqual(PosixPath.basename("C:/", .windows), "")
        XCTAssertEqual(PosixPath.basename("//srv/share/", .windows), "")
        XCTAssertEqual(PosixPath.dirname("/a/b", .windows), "/a")
    }
}
