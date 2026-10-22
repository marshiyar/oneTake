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
// Canvas fill (project and clip): round trip, byte identity, one test per validator rule, unknown versions kept.
import XCTest
@testable import MpvfxShared

final class NativeFillTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func parse(_ d: NativeJSONValue) throws -> NativeProjectDocument { try parseNativeProjectDocument(d, engine: engine) }
    func serialize(_ d: NativeJSONValue) throws -> String { try serializeNativeProjectDocument(d, engine: engine) }

    func document(project: String? = nil, clip: String? = nil) -> NativeJSONValue {
        var d = validNativeDocument()
        d["assets"]?.append(J(##"{"id":"asset:photo","kind":"image","name":"photo.png","durationFrames":1}"##))
        if let project { d["compositionFill"] = J(project) }
        if let clip { d["sequence"]?["tracks"]?[0]?["clips"]?[0]?["fill"] = J(clip) }
        return d
    }

    func issues(project: String? = nil, clip: String? = nil) -> String {
        do { _ = try parse(document(project: project, clip: clip)); return "" }
        catch let e as NativeProjectDocumentValidationError { return e.message }
        catch { return "\(error)" }
    }

    func testFillsRoundTripAndAreTypedWithDefaultsOmitted() throws {
        let d = document(project: ##"{"v":1,"kind":"gradient","gradient":{"angle":90,"stops":[{"offset":0,"color":"#ff0000"},{"offset":1,"color":"#0000ff"}]}}"##,
                         clip: ##"{"v":1,"kind":"blur"}"##)
        let serialized = try serialize(d)
        XCTAssertEqual(try serialize(J(serialized)), serialized)
        let doc = try parse(J(serialized))
        XCTAssertEqual(doc.compositionFill?.kind, "gradient")
        XCTAssertEqual(doc.compositionFill?.stops.map(\.color), ["#ff0000", "#0000ff"])
        XCTAssertEqual(doc.compositionFill?.resolvedAngle, 90)
        let clip = try XCTUnwrap(doc.sequence.tracks[0].clips[0].fill)
        XCTAssertEqual(clip.resolvedBlur, NativeFill.defaultBlur)
        XCTAssertEqual(clip.resolvedDarken, NativeFill.defaultDarken)
        XCTAssertNil(clip.blur, "a default is not stored")
        XCTAssertTrue(clip.isSupported)
        XCTAssertEqual(NativeFill(kind: "blur", blur: 20), NativeFill(raw: J(##"{"v":1,"kind":"blur","blur":20}"##)))
    }

    func testADocumentWithoutFillsOpensAndSavesByteIdentical() throws {
        let serialized = try serialize(document())
        XCTAssertFalse(serialized.contains("ompositionFill") || serialized.contains("\"fill\""))
        XCTAssertEqual(try serialize(J(serialized)), serialized)
        XCTAssertNil(try parse(document()).compositionFill)
        XCTAssertEqual(try parse(document()).undrawnContentNotices, [])
    }

    func testEveryBadValueIsATypedIssue() {
        XCTAssertTrue(issues(project: ##"[]"##).contains("Fill must be an object"))
        XCTAssertTrue(issues(project: ##"{"kind":"none"}"##).contains("compositionFill.v"))
        XCTAssertTrue(issues(project: ##"{"v":1,"kind":"inherit"}"##).contains("cannot inherit"))
        XCTAssertEqual(issues(clip: ##"{"v":1,"kind":"inherit"}"##), "")
        XCTAssertTrue(issues(project: ##"{"v":1,"kind":"color"}"##).contains("compositionFill.color"))
        XCTAssertTrue(issues(project: ##"{"v":1,"kind":"color","color":"red"}"##).contains("compositionFill.color"))
        XCTAssertTrue(issues(project: ##"{"v":1,"kind":"gradient"}"##).contains("needs a gradient"))
        XCTAssertTrue(issues(project: ##"{"v":1,"kind":"gradient","gradient":{"stops":[{"offset":0,"color":"#000"}]}}"##).contains("2 to 8 stops"))
        XCTAssertTrue(issues(project: ##"{"v":1,"kind":"gradient","gradient":{"angle":400,"stops":[{"offset":0,"color":"#000"},{"offset":1,"color":"#fff"}]}}"##).contains("gradient.angle"))
        XCTAssertTrue(issues(project: ##"{"v":1,"kind":"gradient","gradient":{"stops":[{"offset":0.8,"color":"#000"},{"offset":0.2,"color":"#fff"}]}}"##).contains("stops[1].offset"))
        XCTAssertTrue(issues(project: ##"{"v":1,"kind":"gradient","gradient":{"stops":[{"offset":0,"color":"#000"},{"offset":1,"color":"nope"}]}}"##).contains("stops[1].color"))
        XCTAssertTrue(issues(project: ##"{"v":1,"kind":"image"}"##).contains("needs an assetId"))
        XCTAssertTrue(issues(project: ##"{"v":1,"kind":"image","assetId":"asset:none"}"##).contains("does not exist"))
        XCTAssertTrue(issues(project: ##"{"v":1,"kind":"image","assetId":"asset:camera-a"}"##).contains("needs an image asset"))
        XCTAssertEqual(issues(project: ##"{"v":1,"kind":"image","assetId":"asset:photo"}"##), "")
        XCTAssertTrue(issues(project: ##"{"v":1,"kind":"blur","blur":201}"##).contains("compositionFill.blur"))
        XCTAssertTrue(issues(project: ##"{"v":1,"kind":"blur","blur":-1}"##).contains("compositionFill.blur"))
        XCTAssertTrue(issues(project: ##"{"v":1,"kind":"blur","darken":1.5}"##).contains("compositionFill.darken"))
        XCTAssertTrue(issues(clip: ##"{"v":1,"kind":"blur","darken":"x"}"##).contains("clips[0].fill.darken"))
    }

    func testAnUnknownVersionOrKindIsKeptUnchangedNotDrawnAndNoticedOnce() throws {
        let future = ##"{"v":2,"kind":"mesh","points":[1,2,3]}"##
        let d = document(project: future, clip: ##"{"v":1,"kind":"sparkle"}"##)
        let serialized = try serialize(d)
        XCTAssertEqual(try serialize(J(serialized)), serialized)
        let doc = try parse(J(serialized))
        XCTAssertEqual(try NativeJSONValue.from(try XCTUnwrap(doc.compositionFill)), J(future))
        XCTAssertFalse(try XCTUnwrap(doc.compositionFill).isSupported)
        XCTAssertEqual(doc.undrawnContentNotices,
                       ["2 canvas fills from a newer version of the editor are kept in the project but not drawn in preview or export."])
    }
}
