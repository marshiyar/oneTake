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
#if os(Linux)
import Foundation
import XCTest
import MpvfxPanels
@testable import MpvfxDesktop

final class DockLayoutStoreTests: XCTestCase {
    func file(_ name: String) -> DockFile {
        DockFile(current: name, workspaces: [name: DockDefaults.layout(.editor)])
    }

    func directory() throws -> String {
        let path = NSTemporaryDirectory() + "mpvfx-dock-persistence-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func read(_ directory: String) throws -> DockFile {
        let data = try Data(contentsOf: URL(fileURLWithPath: directory + "/dock-layout.json"))
        return try DockCodec.decode(data, registry: .editor).get().file
    }

    func testBurstWritesKeepNewestAndLeaveNoTemps() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = DockLayoutStore(userData: dir)
        for i in 0..<100 { store.save(file("edit-\(i)")) }
        store.flush()
        XCTAssertEqual(try read(dir), file("edit-99"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir), ["dock-layout.json"])
    }

    func testFlushBeforeReleasePreservesNewest() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var store: DockLayoutStore? = DockLayoutStore(userData: dir)
        store?.save(file("before")); store?.flush()
        store?.save(file("after")); store?.flush()
        store = nil
        XCTAssertEqual(try read(dir), file("after"))
    }

    func testWriteRecoversAfterTransientDestinationFailure() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let destination = dir + "/dock-layout.json"
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        let store = DockLayoutStore(userData: dir)
        var errors = 0
        store.onWriteError = { _ in errors += 1 }
        store.save(file("blocked")); store.flush()
        store.save(file("still-blocked")); store.flush()
        XCTAssertEqual(errors, 1)
        try FileManager.default.removeItem(atPath: destination)
        store.save(file("recovered")); store.flush()
        XCTAssertEqual(try read(dir), file("recovered"))
        XCTAssertEqual(errors, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir), ["dock-layout.json"])
    }

    func testReleasingStoreMustNotDropAnAlreadyQueuedCommit() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var store: DockLayoutStore? = DockLayoutStore(userData: dir)
        store?.save(file("before")); store?.flush()
        // Hold the real production queue before enqueueing: deterministic slow-scheduling
        // control, with no replacement writer or production source edits.
        let queue = try XCTUnwrap(Mirror(reflecting: try XCTUnwrap(store)).children.first { $0.label == "queue" }?.value as? DispatchQueue)
        weak let observed = store
        queue.suspend()
        store?.save(file("after"))
        store = nil
        queue.resume()
        queue.sync {}
        let saved = try read(dir)
        XCTAssertEqual(saved, file("after"), "A committed layout must survive release of its store before queued work starts")
        XCTAssertNil(observed, "The completed write must release the store")
    }
}
#endif
