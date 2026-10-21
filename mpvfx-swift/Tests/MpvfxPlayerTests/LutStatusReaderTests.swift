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
import MpvfxColor
import MpvfxPanels
@testable import MpvfxPlayer
import XCTest

/// The inspector's LUT status (issue #182 A2, A3) reads the file the preview reads: grid size, the parser's
/// reason with its line, or a missing file.
internal final class LutStatusReaderTests: XCTestCase {
    private var dir: String = ""

    override internal func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "mpvfx-lut-status-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/luts", withIntermediateDirectories: true)
    }

    override internal func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    internal func testGridSizeErrorAndMissingFile() throws {
        try write("ok.cube", "LUT_3D_SIZE 2\n" + String(repeating: "0 0.5 1\n", count: 8))
        try write("bad.cube", "LUT_3D_SIZE 2\n0 0 0\n0 0\n")
        let cache: CubeLUTCache = CubeLUTCache()
        XCTAssertEqual(LutStatusReader.status("luts/ok.cube", projectDir: dir, cache: cache), .loaded(size: 2))
        let absolute: LutStatus = LutStatusReader.status("\(dir)/luts/ok.cube", projectDir: nil, cache: cache)
        XCTAssertEqual(absolute, .loaded(size: 2), "absolute src")
        let bad: LutStatus = LutStatusReader.status("luts/bad.cube", projectDir: dir, cache: cache)
        guard case .failed(let reason) = bad else {
            XCTFail("a bad .cube is a failure")
            return
        }
        XCTAssertTrue(reason.contains("line 3"), reason)
        let missing: LutStatus = LutStatusReader.status("luts/gone.cube", projectDir: dir, cache: cache)
        XCTAssertEqual(missing, .failed("the file is missing"))
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(toFile: "\(dir)/luts/\(name)", atomically: true, encoding: .utf8)
    }

    deinit {
        // Nothing to release: each test builds its own panel, editor and files.
    }
}
