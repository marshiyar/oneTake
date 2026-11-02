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

/// The render history reads the loudness record an export writes in its `<id>.meta.json` sidecar.
final class ProjectRendersLoudnessTests: XCTestCase {
    private var dir = ""
    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "mpvfx-renders-loudness-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: dir); super.tearDown() }

    /// A finished render `<id>.mp4` with the given sidecar text (nil writes no sidecar).
    private func writeRender(_ id: String, meta: String?) throws {
        try Data("video".utf8).write(to: URL(fileURLWithPath: dir + "/\(id).mp4"))
        if let meta { try Data(meta.utf8).write(to: URL(fileURLWithPath: dir + "/\(id).meta.json")) }
    }

    func testSidecarWithLoudnessListsAllFourValues() throws {
        try writeRender("render-a", meta: #"{"status":"complete","durationMs":123,"loudness":{"v":1,"target":-23.0,"truePeak":-1.0,"measured":-23.1,"measuredTruePeak":-1.2}}"#)
        let r = try XCTUnwrap(ProjectRenders.list(dir).first)
        XCTAssertEqual(r.durationMs, 123)
        XCTAssertEqual(r.loudnessTarget, -23.0)
        XCTAssertEqual(r.loudnessCeiling, -1.0)
        XCTAssertEqual(r.loudnessMeasured, -23.1)
        XCTAssertEqual(r.loudnessMeasuredTruePeak, -1.2)
    }

    func testSidecarWithoutLoudnessListsNil() throws {
        try writeRender("render-plain", meta: #"{"status":"complete","durationMs":123}"#)
        let r = try XCTUnwrap(ProjectRenders.list(dir).first)
        XCTAssertEqual(r.durationMs, 123)
        XCTAssertNil(r.loudnessTarget)
        XCTAssertNil(r.loudnessCeiling)
        XCTAssertNil(r.loudnessMeasured)
        XCTAssertNil(r.loudnessMeasuredTruePeak)
    }

    func testUnknownVersionOrNonNumberListsNilAndKeepsTheRender() throws {
        try writeRender("render-v2", meta: #"{"status":"complete","durationMs":5,"loudness":{"v":2,"target":-23.0,"measured":-23.1}}"#)
        try writeRender("render-text", meta: #"{"status":"complete","durationMs":6,"loudness":{"v":1,"target":"-23.0","truePeak":"-1.0","measured":-23.1}}"#)
        let renders = Dictionary(uniqueKeysWithValues: ProjectRenders.list(dir).map { ($0.id, $0) })
        XCTAssertEqual(renders.count, 2)

        let v2 = try XCTUnwrap(renders["render-v2"])
        XCTAssertEqual(v2.durationMs, 5)
        XCTAssertNil(v2.loudnessTarget)
        XCTAssertNil(v2.loudnessMeasured)

        let text = try XCTUnwrap(renders["render-text"])
        XCTAssertEqual(text.durationMs, 6)
        XCTAssertNil(text.loudnessTarget)
        XCTAssertNil(text.loudnessCeiling)
        XCTAssertEqual(text.loudnessMeasured, -23.1)
    }
}
