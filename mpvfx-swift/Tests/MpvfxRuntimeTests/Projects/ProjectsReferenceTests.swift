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
// Reference tables in Fixtures/projectsParity.json (recorded once from the original implementation): project-relative
// path checks and POSIX path arithmetic.
import XCTest
import MpvfxShared
@testable import MpvfxRuntime

final class ProjectsReferenceTests: XCTestCase {
    var skipped = 0
    func usable(_ strings: String?...) -> Bool {
        if strings.contains(where: { $0.map(pfHasLoneSurrogate) ?? false }) { skipped += 1; return false }
        return true
    }

    func testProjectRelativePathProblem() {
        let rows = pfRows("relativePath"); XCTAssertEqual(rows.count, 56)
        for r in rows {
            let p = pfStr(r["p"])!
            guard usable(p) else { continue }
            XCTAssertEqual(projectRelativePathProblem(p)?.rawValue, pfStr(r["problem"]), p.debugDescription)
        }
        XCTAssertEqual(skipped, 1)
    }

    // The tables are Node path.posix; the POSIX flavor is checked on every host (Windows hosts use .windows).
    func testPathNormalizeIsAbsoluteJoin() {
        for r in pfRows("normalize") {
            let p = pfStr(r["p"])!
            guard usable(p) else { continue }
            XCTAssertEqual(PosixPath.normalize(p, .posix), pfStr(r["out"]), p.debugDescription)
            XCTAssertEqual(PosixPath.isAbsolute(p, .posix), r["abs"] == .bool(true), p.debugDescription)
            XCTAssertEqual(PosixPath.isWindowsAbsolute(p), r["win32Abs"] == .bool(true), p.debugDescription)
            XCTAssertEqual(PosixPath.join(["x", p, "y"], .posix), pfStr(r["join"]), p.debugDescription)
        }
    }

    func testPathResolveAndRelative() {
        let res = pfRows("resolve"); XCTAssertEqual(res.count, 168)
        for r in res {
            let cwd = pfStr(r["cwd"])!, p = pfStr(r["p"])!
            guard usable(p) else { continue }
            XCTAssertEqual(PosixPath.resolve([p], cwd: cwd, .posix), pfStr(r["out"]), "\(cwd) \(p.debugDescription)")
            XCTAssertEqual(PosixPath.resolve(["/base", p, "z"], cwd: cwd, .posix), pfStr(r["two"]), "\(cwd) \(p.debugDescription)")
        }
        let rel = pfRows("relative"); XCTAssertEqual(rel.count, 270)
        for r in rel {
            let cwd = pfStr(r["cwd"])!, a = pfStr(r["a"])!, b = pfStr(r["b"])!
            XCTAssertEqual(PosixPath.relative(a, b, cwd: cwd, .posix), pfStr(r["out"]), "\(cwd) \(a) -> \(b)")
        }
    }
}
