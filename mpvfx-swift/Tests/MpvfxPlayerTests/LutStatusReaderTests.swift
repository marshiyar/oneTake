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
import MpvfxColor
import MpvfxPanels
@testable import MpvfxPlayer

/// The inspector's LUT status (issue #182 A2, A3) reads the file the preview reads: grid size, the parser's
/// reason with its line, or a missing file.
final class LutStatusReaderTests: XCTestCase {
    var dir = ""
    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "mpvfx-lut-status-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/luts", withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    func write(_ name: String, _ text: String) throws {
        try text.write(toFile: "\(dir)/luts/\(name)", atomically: true, encoding: .utf8)
    }

    func testGridSizeErrorAndMissingFile() throws {
        try write("ok.cube", "LUT_3D_SIZE 2\n" + String(repeating: "0 0.5 1\n", count: 8))
        try write("bad.cube", "LUT_3D_SIZE 2\n0 0 0\n0 0\n")
        let cache = CubeLUTCache()
        XCTAssertEqual(LutStatusReader.status("luts/ok.cube", projectDir: dir, cache: cache), .loaded(size: 2))
        XCTAssertEqual(LutStatusReader.status("\(dir)/luts/ok.cube", projectDir: nil, cache: cache), .loaded(size: 2), "absolute src")
        guard case .failed(let why) = LutStatusReader.status("luts/bad.cube", projectDir: dir, cache: cache) else {
            return XCTFail("a bad .cube is a failure")
        }
        XCTAssertTrue(why.contains("line 3"), why)
        XCTAssertEqual(LutStatusReader.status("luts/gone.cube", projectDir: dir, cache: cache), .failed("the file is missing"))
    }
}
