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
import XCTest
import MpvfxShared
import OneTakeKeyframes
import MpvfxTimeline
import MpvfxPanels
@testable import MpvfxRuntime

/// Issue #281: a text layer with keyframed look values exports; the exporter never refuses an id the inspector keys.
final class TextLookExportAuditTests: XCTestCase {
    func testEveryKeyedLookValueIsAcceptedByTheExporter() throws {
        let editor = try TimelineEditor(json: InspectorRenderAuditTests.json, engine: try KeyframeRuntime())
        let id = try XCTUnwrap(editor.addTextClip(at: 0, content: "HI", seconds: 2))
        XCTAssertTrue(editor.setTextLook(clipId: id, NativeTextLook(
            outlines: [.init(width: 2, color: "#ff0000"), .init(width: 3, color: "#00ff00")],
            shadow: .init(x: 1, y: 1, blur: 2, color: "#0000ff"), glow: .init(color: "#ffffff"),
            plate: .init(color: "#000000cc"), fill: .init(from: "#ff0000", to: "#0000ff"))))
        for pid in NativeTextLookParameter.all {
            XCTAssertEqual(exportAnimatableValueTypes(pid), [.number], pid)
            let start = try XCTUnwrap(editor.textLookValue(clipId: id, pid, time: 0))
            XCTAssertTrue(editor.setAnimated(clipId: id, [(pid, .number(start))], true, time: 0), pid)
            XCTAssertTrue(editor.setTextLookValue(clipId: id, pid, start + 5, time: 1), pid)
        }
        XCTAssertNoThrow(try assertNativeTimelineSupported(editor.document))
        XCTAssertNil(exportAnimatableValueTypes("text.look.glow.radius"), "ids that are not text look values are still refused")
    }
}
