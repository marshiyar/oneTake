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
// Reference tables in Fixtures/projectsParity.json: SHA-256 and the transaction journal byte format
// (journals written by earlier versions stay readable).
import Foundation
import XCTest
import MpvfxShared
@testable import MpvfxRuntime

final class ProjectsJournalTests: XCTestCase {
    func testSha256() {
        let rows = pfRows("sha256")
        XCTAssertEqual(rows.count, 8)
        for r in rows { XCTAssertEqual(sha256Hex(pfStr(r["s"])!), pfStr(r["hex"])) }
    }

    /// Replays the generator's scenario against the Swift store; journal file text and JSON.stringify of every
    /// result must be byte-identical to the recorded store's.
    func testJournalAndReceiptBytesMatchTheTSStore() throws {
        let fx = try XCTUnwrap(projectsFixture["journal"])
        let inputs = try XCTUnwrap(fx["inputs"]?.arrayValue)
        let steps = try XCTUnwrap(fx["steps"]?.arrayValue)
        XCTAssertEqual(steps.count, 6)
        let roots = TempRoots(); defer { roots.cleanup() }
        let root = try roots.make("gen-journal-")
        try mkdirP(join(root, "src"))
        try writeText(join(root, "src/index.html"), "before-html"); try writeText(join(root, "project.json"), "before-project")
        try writeText(join(root, "delete-me.txt"), "old"); try mkdirP(join(root, "media"))
        try writeBytes(join(root, "media/a.mp4"), Data([0, 255, 192, 128, 10, 13, 240]))
        XCTAssertEqual(try binaryFileVersion(root, "media/a.mp4"), pfStr(fx["mediaVersion"]))
        final class Clock: @unchecked Sendable { var ms = jsDateParseISO("2026-03-04T05:06:07.089Z") }
        let clock = Clock()
        let now = { Date(timeIntervalSince1970: clock.ms / 1000) }
        let s = store(root, now: now)
        let journalDir = join(root, ".hyperframes/studio-transactions")
        func check(_ i: Int, _ result: NativeJSONValue) {
            let step = steps[i], id = pfStr(step["id"])!
            XCTAssertEqual(jsISOString(now()), pfStr(step["now"]), "step \(i)")
            XCTAssertEqual(jsJSONStringify(result), pfStr(step["result"]), "step \(i) \(pfStr(step["label"])!)")
            XCTAssertEqual(try? readText(join(journalDir, sha256Hex(id) + ".json")), pfStr(step["journal"]), "step \(i) journal")
        }
        check(0, try s.commit(inputs[0]).jsonValue)
        clock.ms += 1234
        check(1, try s.commit(inputs[1]).jsonValue)
        clock.ms += 1
        let crashing = store(root, afterTargetWrite: { _, _ in throw PowerLoss("crash") }, now: now)
        XCTAssertThrowsError(try crashing.commit(inputs[2]))
        check(2, try s.status("crash.tx")?.jsonValue ?? .null)
        clock.ms += 86_400_000
        check(3, .array(try s.recover().map(\.jsonValue)))
        check(4, try s.status("tx-1")?.jsonValue ?? .null)
        check(5, .array(try s.listReceipts().map(\.jsonValue)))
    }
}
