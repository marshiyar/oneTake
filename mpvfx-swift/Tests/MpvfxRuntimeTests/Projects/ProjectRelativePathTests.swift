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
// Project-relative path checks, POSIX and Windows-style inputs.
import XCTest
@testable import MpvfxRuntime

final class ProjectRelativePathTests: XCTestCase {
    // describe("project-relative path checks")
    func testAcceptsNestedForwardSlashPaths() {
        for path in ["project.json", ".studio/project.json", "src/index.html", "compositions/scenes/intro.html"] {
            XCTAssertNil(projectRelativePathProblem(path), path)
        }
    }

    func testRejectsNonRelativePaths() {
        for path in ["", "/etc/passwd", "\\\\server\\share\\file", "src\\index.html", "C:/Windows/win.ini", "C:relative.html", "c:\\Windows", "bad\0name"] {
            XCTAssertEqual(projectRelativePathProblem(path), .notRelative, path)
        }
    }

    func testRejectsTraversalOrNonCanonicalPaths() {
        for path in ["..", "../outside.html", "src/../../outside.html", "src/./index.html", "./index.html", "src//index.html", "src/"] {
            XCTAssertEqual(projectRelativePathProblem(path), .traversal, path)
        }
    }

    func testDoesNotDependOnTheHostSeparatorWindowsRegression() {
        // The check never consults a host
        // separator (PosixPath only), so only the result matters.
        XCTAssertNil(projectRelativePathProblem(".studio/project.json"))
    }

    // describe("project-relative path checks on a Windows host"): the check is host independent in Swift.
    func testWindowsHostAccepts() {
        for path in [".studio/project.json", "src/index.html", "compositions/intro.html", "project.json"] {
            XCTAssertNil(projectRelativePathProblem(path), path)
        }
    }

    func testWindowsHostRejects() {
        for (path, problem) in [("../outside.html", "traversal"), ("src/../../outside.html", "traversal"), ("src\\index.html", "not-relative"),
                                ("/etc/passwd", "not-relative"), ("C:/Windows/win.ini", "not-relative")] {
            XCTAssertEqual(projectRelativePathProblem(path)?.rawValue, problem, path)
        }
    }
}
