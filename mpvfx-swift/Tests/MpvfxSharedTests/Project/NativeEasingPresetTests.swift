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
@testable import MpvfxShared

/// `easingPresets` in the document (the Easing panel's custom presets, saved per project): round trip, absent stays
/// absent, and validation of every field.
final class NativeEasingPresetTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func parse(_ d: NativeJSONValue) throws -> NativeProjectDocument { try parseNativeProjectDocument(d, engine: engine) }
    func withPresets(_ json: String) -> NativeJSONValue {
        var d = validNativeDocument(); d["easingPresets"] = J(json); return d
    }
    func rejects(_ json: String, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        do { _ = try parse(withPresets(json)); XCTFail("accepted \(json)", file: file, line: line) }
        catch let e as NativeProjectDocumentValidationError { XCTAssertTrue(e.message.contains(text), e.message, file: file, line: line) }
        catch { XCTFail("\(error)", file: file, line: line) }
    }
    let snappy = #"{"id":"p1","name":"Snappy","outgoing":{"type":"cubic-bezier","controlPoints":{"x1":0.2,"y1":0,"x2":0,"y2":1}}}"#

    func testPresetsRoundTripInOrder() throws {
        let json = "[\(snappy),{\"id\":\"p2\",\"name\":\"Step\",\"outgoing\":{\"type\":\"hold\"}}]"
        let doc = try parse(withPresets(json))
        XCTAssertEqual(doc.easingPresets, [
            NativeEasingPreset(id: "p1", name: "Snappy", outgoing: .cubicBezier(.init(x1: 0.2, y1: 0, x2: 0, y2: 1))),
            NativeEasingPreset(id: "p2", name: "Step", outgoing: .hold),
        ])
        let again = try parse(J(try serializeNativeProjectDocument(doc, engine: engine)))
        XCTAssertEqual(again.easingPresets, doc.easingPresets)
    }

    func testAbsentPresetsStayAbsent() throws {
        let doc = try parse(validNativeDocument())
        XCTAssertNil(doc.easingPresets)
        XCTAssertFalse(try serializeNativeProjectDocument(doc, engine: engine).contains("easingPresets"))
    }

    func testRejectsMalformedPresets() {
        rejects(#"{"id":"p"}"#, "Easing presets must be an array")
        rejects(#"["x"]"#, "Easing preset must be an object")
        rejects(#"[{"id":" ","name":"A","outgoing":{"type":"linear"}}]"#, "Easing preset ID must be a non-empty string")
        rejects(#"[{"id":"a","name":"","outgoing":{"type":"linear"}}]"#, "Easing preset name must be 1 to 64 characters")
        rejects("[{\"id\":\"a\",\"name\":\"\(String(repeating: "n", count: 65))\",\"outgoing\":{\"type\":\"linear\"}}]",
                "Easing preset name must be 1 to 64 characters")
        rejects(#"[{"id":"a","name":"A","outgoing":{"type":"linear"}},{"id":"a","name":"B","outgoing":{"type":"hold"}}]"#,
                "Duplicate easing preset ID a")
        rejects(#"[{"id":"a","name":"A","outgoing":{"type":"spring"}}]"#, "Easing preset outgoing must be hold, linear or cubic-bezier")
        rejects(#"[{"id":"a","name":"A","outgoing":{"type":"cubic-bezier","controlPoints":{"x1":1.5,"y1":0,"x2":1,"y2":1}}}]"#,
                "Easing preset control points must be finite, with x1 and x2 in 0 to 1")
        rejects(#"[{"id":"a","name":"A","outgoing":{"type":"cubic-bezier","controlPoints":{"x1":0.5,"y1":"0","x2":1,"y2":1}}}]"#,
                "Easing preset control points must be finite, with x1 and x2 in 0 to 1")
        let many = (0...NATIVE_EASING_PRESET_LIMIT).map { #"{"id":"p\#($0)","name":"P","outgoing":{"type":"linear"}}"# }
        rejects("[\(many.joined(separator: ","))]", "At most \(NATIVE_EASING_PRESET_LIMIT) easing presets")
    }
}
