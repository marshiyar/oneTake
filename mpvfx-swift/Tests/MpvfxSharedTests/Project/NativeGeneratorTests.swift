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

final class NativeGeneratorTests: XCTestCase {
    func input(_ fill: NativeFill) throws -> NativeJSONValue {
        var d = validNativeDocument()
        d["assets"]?[0]?["kind"] = .string("element")
        d["sequence"]?["tracks"]?[0]?["clips"]?[0]?["generator"] = try NativeJSONValue.from(fill)
        return d
    }
    func testAllThreeKindsValidateAndRoundTripIncludingUnknownFillKeys() throws {
        for kind in NativeGeneratorKind.allCases {
            var fill = kind.fill.raw; fill["future"] = .string("kept")
            let raw = try input(NativeFill(raw: fill))
            let text = try serializeNativeProjectDocument(raw)
            let doc = try parseNativeProjectDocument(try NativeJSONValue.parse(text))
            XCTAssertEqual(doc.sequence.tracks[0].clips[0].generator?.raw, fill)
            XCTAssertEqual(try serializeNativeProjectDocument(doc), text)
        }
    }
    func testMalformedColoursAngleCentreAndGeneratorAssetAreRefused() throws {
        var bad = NativeGeneratorKind.radial.fill.raw
        bad["gradient"]?["centerX"] = .number(1.01)
        XCTAssertThrowsError(try parseNativeProjectDocument(input(NativeFill(raw: bad))))
        bad = NativeGeneratorKind.linear.fill.raw; bad["gradient"]?["angle"] = .number(361)
        XCTAssertThrowsError(try parseNativeProjectDocument(input(NativeFill(raw: bad))))
        XCTAssertThrowsError(try parseNativeProjectDocument(input(NativeFill(kind: "color", color: "invalid"))))
        XCTAssertThrowsError(try parseNativeProjectDocument(input(NativeFill(kind: "blur"))))
        var raw = try input(NativeGeneratorKind.solid.fill); raw["assets"]?[0]?["kind"] = .string("video")
        XCTAssertThrowsError(try parseNativeProjectDocument(raw))
    }
    func testFutureGeneratorVersionAndKindArePreservedButUnsupported() throws {
        let fill = NativeFill(raw: try NativeJSONValue.parse(#"{"v":2,"kind":"noise","seed":42}"#))
        let doc = try parseNativeProjectDocument(input(fill))
        XCTAssertEqual(doc.sequence.tracks[0].clips[0].generator, fill)
        XCTAssertFalse(fill.isGenerator)
        XCTAssertEqual(try parseNativeProjectDocument(try NativeJSONValue.parse(serializeNativeProjectDocument(doc))), doc)
    }
    func testOlderProjectOmitsGeneratorOnSave() throws {
        let doc = try parseNativeProjectDocument(validNativeDocument())
        XCTAssertFalse(try serializeNativeProjectDocument(doc).contains("generator"))
    }
}
