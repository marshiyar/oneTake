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
@testable import MpvfxRuntime
import MpvfxShared

final class StandaloneProjectTests: XCTestCase {
    var dir: String!
    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "standalone-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    func testCreatesANativeDocumentOnce() throws {
        XCTAssertEqual(try ensureStandaloneProject(dir, durableWrite: TestDurableWrite()), EnsureStandaloneProjectResult(created: true, id: STANDALONE_PROJECT_ID))
        let path = dir + "/" + STANDALONE_PROJECT_ID + "/" + NATIVE_PROJECT_DOCUMENT_PATH
        let document = try parseNativeProjectDocument(NativeJSONValue.parse(String(contentsOfFile: path, encoding: .utf8)))
        XCTAssertEqual(document.mediaEngine, .native)
        XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).contains("native"))
        XCTAssertEqual(document.canvas.width, 1920)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/" + STANDALONE_PROJECT_ID + "/index.html"))
        XCTAssertEqual(try ensureStandaloneProject(dir, durableWrite: TestDurableWrite()), EnsureStandaloneProjectResult(created: false, id: STANDALONE_PROJECT_ID))
    }

    func testNeverRewritesAnExistingDocument() throws {
        _ = try ensureStandaloneProject(dir, durableWrite: TestDurableWrite())
        let path = dir + "/" + STANDALONE_PROJECT_ID + "/" + NATIVE_PROJECT_DOCUMENT_PATH
        try Data("{\"edited\":true}".utf8).write(to: URL(fileURLWithPath: path))
        _ = try ensureStandaloneProject(dir, durableWrite: TestDurableWrite())
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "{\"edited\":true}")
    }
}
