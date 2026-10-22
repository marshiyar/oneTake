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
import MpvfxDesktopCore
import MpvfxPanels

final class UserLookDurableWriteTests: XCTestCase {
    func testTheHostDurableWriterCreatesAReopenableCatalogWithoutTemporaryFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("look-durable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("looks.json").path
        let writer: (Data, String) throws -> Void = { try NativeDurableWrite().write($0, to: $1) }
        let store = try UserLookStore(path: path, write: writer)
        _ = try store.save(name: "Neutral", effects: [])
        XCTAssertEqual(try UserLookStore(path: path, write: writer).looks.map(\.name), ["Neutral"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["looks.json"])
    }
}
