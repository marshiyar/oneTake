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
// Text look (outlines, drop shadow): round trip, byte identity, one test per validator rule, unknown versions kept.
import XCTest
@testable import MpvfxShared

final class NativeTextLookTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func parse(_ d: NativeJSONValue) throws -> NativeProjectDocument { try parseNativeProjectDocument(d, engine: engine) }
    func serialize(_ d: NativeJSONValue) throws -> String { try serializeNativeProjectDocument(d, engine: engine) }

    func textDocument(_ text: String) -> NativeJSONValue {
        var d = validNativeDocument()
        d["assets"]?.append(J(##"{"id":"asset:title","kind":"element","name":"Title","durationFrames":40}"##))
        d["sequence"]?["tracks"]?[0]?["clips"]?.append(J(
            ##"{"id":"clip:title","assetId":"asset:title","startFrame":90,"durationFrames":120,"sourceInFrame":0,"effects":[],"parameterTracks":[],"text":\##(text)}"##))
        return d
    }

    func issues(_ look: String) -> String {
        do { _ = try parse(textDocument(##"{"content":"H","look":\##(look)}"##)); return "" }
        catch let e as NativeProjectDocumentValidationError { return e.message }
        catch { return "\(error)" }
    }

    func testAWorkingLookRoundTripsAndOmitsDefaults() throws {
        let look = ##"{"v":1,"outlines":[{"width":10,"color":"#000000"},{"width":4,"color":"#ff0000","position":"center"}],"shadow":{"x":4,"y":6,"blur":8,"color":"#00000080"}}"##
        let doc = textDocument(##"{"content":"H","look":\##(look)}"##)
        let serialized = try serialize(doc)
        let reopened = try parse(J(serialized))
        let typed = try XCTUnwrap(reopened.sequence.tracks[0].clips[1].text?.look)
        XCTAssertEqual(typed.outlines?.count, 2)
        XCTAssertEqual(typed.outlines?[0].resolvedPosition, "outside")
        XCTAssertEqual(typed.outlines?[1].resolvedPosition, "center")
        XCTAssertEqual(typed.shadow?.resolvedBlur, 8)
        XCTAssertEqual(try serialize(J(serialized)), serialized)
        let json = try NativeJSONValue.from(typed)
        XCTAssertEqual(json["outlines"]?[0]?["position"], nil, "a default position is omitted")
    }

    func testADocumentWithoutALookOpensAndSavesByteIdentical() throws {
        let doc = textDocument(##"{"content":"Title"}"##)
        let serialized = try serialize(doc)
        XCTAssertFalse(serialized.contains("look"))
        XCTAssertEqual(try serialize(J(serialized)), serialized)
        XCTAssertNil(try parse(doc).sequence.tracks[0].clips[1].text?.look)
        XCTAssertEqual(try parse(doc).undrawnContentNotices, [])
    }

    func testEveryBadValueIsATypedIssue() {
        XCTAssertTrue(issues(##"[]"##).contains("Text look must be an object"))
        XCTAssertTrue(issues(##"{"outlines":[]}"##).contains("look.v"))
        let three = ##"{"v":1,"outlines":[{"width":1,"color":"#000"},{"width":1,"color":"#000"},{"width":1,"color":"#000"}]}"##
        XCTAssertTrue(issues(three).contains("at most 2 outlines"))
        XCTAssertTrue(issues(##"{"v":1,"outlines":{}}"##).contains("Outlines must be an array"))
        XCTAssertTrue(issues(##"{"v":1,"outlines":[3]}"##).contains("An outline must be an object"))
        XCTAssertTrue(issues(##"{"v":1,"outlines":[{"color":"#000"}]}"##).contains("outlines[0].width"))
        XCTAssertTrue(issues(##"{"v":1,"outlines":[{"width":101,"color":"#000"}]}"##).contains("Outline width must be a number from 0 to 100"))
        XCTAssertTrue(issues(##"{"v":1,"outlines":[{"width":-1,"color":"#000"}]}"##).contains("outlines[0].width"))
        XCTAssertTrue(issues(##"{"v":1,"outlines":[{"width":"3","color":"#000"}]}"##).contains("outlines[0].width"))
        XCTAssertTrue(issues(##"{"v":1,"outlines":[{"width":3,"color":"red"}]}"##).contains("outlines[0].color"))
        XCTAssertTrue(issues(##"{"v":1,"outlines":[{"width":3}]}"##).contains("outlines[0].color"))
        XCTAssertTrue(issues(##"{"v":1,"outlines":[{"width":3,"color":"#000","position":"inside"}]}"##).contains("outlines[0].position"))
        XCTAssertTrue(issues(##"{"v":1,"shadow":5}"##).contains("Shadow must be an object"))
        XCTAssertTrue(issues(##"{"v":1,"shadow":{"x":501,"color":"#000"}}"##).contains("shadow.x"))
        XCTAssertTrue(issues(##"{"v":1,"shadow":{"y":-501,"color":"#000"}}"##).contains("shadow.y"))
        XCTAssertTrue(issues(##"{"v":1,"shadow":{"blur":201,"color":"#000"}}"##).contains("shadow.blur"))
        XCTAssertTrue(issues(##"{"v":1,"shadow":{"blur":-1,"color":"#000"}}"##).contains("shadow.blur"))
        XCTAssertTrue(issues(##"{"v":1,"shadow":{"x":1}}"##).contains("shadow.color"))
        XCTAssertTrue(issues(##"{"v":1,"shadow":{"x":1,"color":"zzz"}}"##).contains("shadow.color"))
        XCTAssertEqual(issues(##"{"v":1,"outlines":[{"width":100,"color":"#000"}],"shadow":{"x":-500,"y":500,"blur":200,"color":"#000"}}"##), "")
    }

    func testALookFromANewerVersionIsKeptUnchangedNotDrawnAndNoticedOnce() throws {
        let look = ##"{"v":2,"glow":{"radius":5},"outlines":[{"width":3,"color":"#000000"}]}"##
        let doc = textDocument(##"{"content":"H","look":\##(look)}"##)
        let serialized = try serialize(doc)
        let reopened = try parse(J(serialized))
        XCTAssertEqual(try serialize(J(serialized)), serialized)
        let kept = try XCTUnwrap(reopened.sequence.tracks[0].clips[1].text?.look)
        XCTAssertFalse(kept.isSupported)
        XCTAssertEqual(try NativeJSONValue.from(kept), J(look))
        XCTAssertEqual(reopened.undrawnContentNotices,
                       ["1 text look from a newer version of the editor is kept in the project but not drawn in preview or export."])
    }

    func testGlowPlateAndFillRoundTripAndOmitDefaults() throws {
        let look = ##"{"v":1,"glow":{"color":"#ff00ff"},"plate":{"mode":"block","paddingX":12,"radius":8,"color":"#00000080"},"fill":{"from":"#ff0000","to":"#0000ff","angle":45}}"##
        let doc = textDocument(##"{"content":"H","look":\##(look)}"##)
        let serialized = try serialize(doc)
        let typed = try XCTUnwrap(try parse(J(serialized)).sequence.tracks[0].clips[1].text?.look)
        XCTAssertEqual(typed.glow?.resolvedRadius, 12); XCTAssertEqual(typed.glow?.resolvedStrength, 1)
        XCTAssertEqual(typed.plate?.resolvedMode, "block"); XCTAssertEqual(typed.plate?.resolvedPaddingY, 0)
        XCTAssertEqual(typed.fill?.resolvedAngle, 45)
        XCTAssertEqual(try serialize(J(serialized)), serialized)
        let json = try NativeJSONValue.from(typed)
        XCTAssertEqual(json["glow"], J(##"{"color":"#ff00ff"}"##), "defaults are omitted")
        XCTAssertNil(json["outlines"]); XCTAssertNil(json["shadow"])
        XCTAssertEqual(NativeTextLook.Fill(from: "#000", to: "#fff").resolvedAngle, 0)
    }

    func testEveryNewBadValueIsATypedIssue() {
        XCTAssertTrue(issues(##"{"v":1,"glow":5}"##).contains("Glow must be an object"))
        XCTAssertTrue(issues(##"{"v":1,"glow":{"radius":201,"color":"#000"}}"##).contains("Glow radius must be a number from 0 to 200"))
        XCTAssertTrue(issues(##"{"v":1,"glow":{"strength":1.5,"color":"#000"}}"##).contains("glow.strength"))
        XCTAssertTrue(issues(##"{"v":1,"glow":{"strength":-0.1,"color":"#000"}}"##).contains("Glow strength must be a number from 0 to 1"))
        XCTAssertTrue(issues(##"{"v":1,"glow":{"radius":3}}"##).contains("glow.color"))
        XCTAssertTrue(issues(##"{"v":1,"plate":[]}"##).contains("Plate must be an object"))
        XCTAssertTrue(issues(##"{"v":1,"plate":{"mode":"row","color":"#000"}}"##).contains("plate.mode"))
        XCTAssertTrue(issues(##"{"v":1,"plate":{"paddingX":501,"color":"#000"}}"##).contains("plate.paddingX"))
        XCTAssertTrue(issues(##"{"v":1,"plate":{"paddingY":-1,"color":"#000"}}"##).contains("plate.paddingY"))
        XCTAssertTrue(issues(##"{"v":1,"plate":{"radius":501,"color":"#000"}}"##).contains("plate.radius"))
        XCTAssertTrue(issues(##"{"v":1,"plate":{"color":"blue"}}"##).contains("plate.color"))
        XCTAssertTrue(issues(##"{"v":1,"fill":"red"}"##).contains("Fill must be an object"))
        XCTAssertTrue(issues(##"{"v":1,"fill":{"from":"#000"}}"##).contains("fill.to"))
        XCTAssertTrue(issues(##"{"v":1,"fill":{"from":"nope","to":"#fff"}}"##).contains("fill.from"))
        XCTAssertTrue(issues(##"{"v":1,"fill":{"from":"#000","to":"#fff","angle":361}}"##).contains("Fill angle must be a number from -360 to 360"))
        XCTAssertEqual(issues(##"{"v":1,"glow":{"radius":200,"strength":1,"color":"#fff"},"plate":{"mode":"line","paddingX":500,"paddingY":0,"radius":500,"color":"#000000ff"},"fill":{"from":"#000","to":"#fff","angle":-360}}"##), "")
    }

    func testAnIdleGlowIsAnEmptyLookAndAPlateOrFillIsNot() {
        XCTAssertTrue(NativeTextLook(glow: .init(strength: 0, color: "#ff00ff")).isEmpty)
        XCTAssertTrue(NativeTextLook(glow: .init(color: "#ff00ff00")).isEmpty, "a clear colour draws nothing")
        XCTAssertFalse(NativeTextLook(glow: .init(color: "#ff00ff")).isEmpty)
        XCTAssertFalse(NativeTextLook(plate: .init(color: "#000000")).isEmpty)
        XCTAssertFalse(NativeTextLook(fill: .init(from: "#000", to: "#fff")).isEmpty)
    }
}
