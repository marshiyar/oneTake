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
// Golden-message tests: validation text and order that reach the UI through
// NativeProjectDocumentValidationError.message (shown by the timeline's toasts).
import XCTest
@testable import MpvfxShared

final class NativeProjectIssueOrderTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func messages(_ track: String) -> [String] {
        var d = validNativeDocument()
        d["sequence"]?["tracks"]?[0]?["clips"]?[0]?["parameterTracks"] = .array([J(track)])
        do { _ = try parseNativeProjectDocument(d, engine: engine); return [] }
        catch let e as NativeProjectDocumentValidationError { return e.issues.map(\.message) } catch { return ["\(error)"] }
    }
    let base = #""schemaVersion":1,"frameRate":{"numerator":30000,"denominator":1001}"#

    func testMalformedTrackShapesUseCreateNativeParameterTrackText() {
        XCTAssertEqual(messages(#"{\#(base),"id":" ","parameterId":"p","valueType":"number","keyframes":[]}"#), ["Track ID must not be empty"])
        XCTAssertEqual(messages(#"{\#(base),"id":"t","parameterId":7,"keyframes":[]}"#), ["Parameter ID must not be empty"])
        XCTAssertEqual(messages(#"{\#(base),"id":"t","parameterId":"p","valueType":"number"}"#), ["Cannot read properties of undefined (reading 'length')"])
        XCTAssertEqual(messages(#"{\#(base),"id":"t","parameterId":"p","valueType":"number","keyframes":null}"#), ["Cannot read properties of null (reading 'length')"])
        XCTAssertEqual(messages(#"{\#(base),"id":"t","parameterId":"p","valueType":"number","keyframes":{}}"#), ["input.keyframes.map is not a function"])
        XCTAssertEqual(messages(#"{\#(base),"id":"t","parameterId":"p","valueType":"number","keyframes":[]}"#), ["Parameter track t must contain at least one keyframe"])
        XCTAssertEqual(messages(#"{\#(base),"id":"t","parameterId":"p","valueType":"nope","keyframes":[{"id":"","frame":0}]}"#), ["Keyframe ID must not be empty"])
        XCTAssertEqual(messages(#"{\#(base),"id":"t","parameterId":"p","valueType":"nope","keyframes":[null]}"#), ["Cannot read properties of null (reading 'id')"])
    }

    func testStaticParameterIssuesFollowJSKeyOrder() {
        var d = validNativeDocument()
        d["sequence"]?["tracks"]?[0]?["clips"]?[0]?["staticParameters"] = J(#"{"zeta":"bad","alpha":"bad","2":"bad"}"#)
        do { _ = try parseNativeProjectDocument(d, engine: engine); XCTFail("expected error") }
        catch let e as NativeProjectDocumentValidationError {
            XCTAssertEqual(e.issues.map(\.path).map { $0.components(separatedBy: ".").last! }, ["2", "zeta", "alpha"])
        } catch { XCTFail("\(error)") }
    }
}
