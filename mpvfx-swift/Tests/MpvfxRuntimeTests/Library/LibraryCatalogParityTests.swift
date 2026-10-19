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
// Parity of LibraryCatalog (library_node.cpp port) against Fixtures/catalogParity.json and originalCatalog.sqlite,
// produced by Fixtures/gen/generateCatalogFixture.py from the SQL text extracted out of library_node.cpp (see there
// for why the N-API module itself could not be run).
import Foundation
import XCTest
@testable import MpvfxShared
@testable import MpvfxRuntime

final class LibraryCatalogParityTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    var dir = ""
    override func setUpWithError() throws { dir = try makeMediaTempDir("catalog-parity-") }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    func fixture() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixtures.appendingPathComponent("catalogParity.json"))) as! [String: Any]
    }

    func testReplaysEveryCommandWithTheOriginalSnapshotsAndErrors() throws {
        let path = "\(dir)/Catalog.sqlite"
        for step in try fixture()["steps"] as! [[String: Any]] {
            let action = step["action"] as! String, args = step["args"] as! [String]
            if step["ok"] as! Bool {
                XCTAssertEqual(try LibraryCatalog.command(path, action, args), step["snapshot"] as? String, action)
            } else {
                XCTAssertThrowsError(try LibraryCatalog.command(path, action, args), action) { error in
                    let want = step["error"] as! String
                    // A wrong argument count is rejected by the C++ before SQLite sees it (library_node.cpp:45).
                    XCTAssertEqual("\(error)", want.hasPrefix("Incorrect number of bindings") ? "Invalid command arguments" : want)
                }
            }
        }
    }

    func testOpensTheOriginalDatabaseAndReturnsTheSameQueryResults() throws {
        let path = "\(dir)/Catalog.sqlite"
        try FileManager.default.copyItem(atPath: Self.fixtures.appendingPathComponent("originalCatalog.sqlite").path, toPath: path)
        let f = try fixture()
        XCTAssertEqual(try LibraryCatalog.command(path, "read", []), (f["finalRead"] as! [String: Any])["snapshot"] as? String)
        XCTAssertEqual(try LibraryCatalog.command(path, "recover", []), (f["recoverOnReopen"] as! [String: Any])["snapshot"] as? String)
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(try LibraryCatalog.command(path, "read", []).utf8))
        XCTAssertEqual(catalog.jobs.map(\.status), ["complete", "interrupted"])
        XCTAssertEqual(catalog.placements.map(\.path), ["assets/55555555-5555-4555-8555-555555555555/renamed.png"])
        XCTAssertEqual(catalog.assets.map(\.source), ["Media/Originals/55555555-5555-4555-8555-555555555555/Khé¿.png", "/media/moved.wav"])
    }

    func testRejectsUnknownCommandsReadArgumentsAndForeignVersions() throws {
        let path = "\(dir)/Catalog.sqlite"
        _ = try LibraryCatalog.command(path, "create", ["11111111-1111-4111-8111-111111111111", "Film"])
        XCTAssertThrowsError(try LibraryCatalog.command(path, "drop", [])) { XCTAssertEqual("\($0)", "Unknown library command") }
        XCTAssertThrowsError(try LibraryCatalog.command(path, "read", ["x"])) { XCTAssertEqual("\($0)", "Invalid read arguments") }
        XCTAssertThrowsError(try LibraryCatalog.command(path, "read", Array(repeating: "x", count: 17))) { XCTAssertEqual("\($0)", "Too many arguments") }
        XCTAssertThrowsError(try LibraryCatalog.command(path, "event", ["a\u{0}b", "x"])) { XCTAssertEqual("\($0)", "Embedded NUL is not permitted") }
        XCTAssertThrowsError(try LibraryCatalog.command("\(dir)/missing.sqlite", "read", []))
        XCTAssertThrowsError(try LibraryCatalog.command(path, "create", ["22222222-2222-4222-8222-222222222222", "Again"]))
    }

    func testLockIsExclusiveAndReleasedOnClose() throws {
        let first = try LibraryLock("\(dir)/.mpvfx-lock")
        XCTAssertThrowsError(try LibraryLock("\(dir)/.mpvfx-lock")) {
            XCTAssertEqual("\($0)", "Library is already open in another process or is not writable")
        }
        first.close()
        XCTAssertNoThrow(try LibraryLock("\(dir)/.mpvfx-lock"))
        try FileManager.default.createSymbolicLink(atPath: "\(dir)/link-lock", withDestinationPath: "\(dir)/target")
        XCTAssertThrowsError(try LibraryLock("\(dir)/link-lock"), "O_NOFOLLOW")
    }

    func testSystemSQLiteHasEveryFeatureTheCatalogUses() throws {
        XCTAssertNoThrow(try SQLiteRequirements.verify())
        XCTAssertEqual(SQLiteRequirements.probes.count, 9)
        let error = SQLiteRequirementError(feature: "JSON functions json() (:71-75)", detail: "no such function: json")
        XCTAssertEqual("\(error)", "The system SQLite library is missing JSON functions json() (:71-75), which the media library catalog requires (no such function: json).")
    }
}
