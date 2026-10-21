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

final class NativeTextStyleTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func document() throws -> NativeProjectDocument {
        var raw = validNativeDocument()
        raw["assets"]?.append(J(#"{"id":"asset:text","kind":"element","name":"Text","durationFrames":120}"#))
        for n in 1...3 {
            raw["sequence"]?["tracks"]?[0]?["clips"]?.append(J("""
            {"id":"text:\(n)","assetId":"asset:text","startFrame":\(n * 120),"durationFrames":120,"sourceInFrame":0,
            "effects":[],"parameterTracks":[],"text":{"content":"Words \(n)","color":"#ffffff","fontSize":40}}
            """))
        }
        return try parseNativeProjectDocument(raw, engine: engine)
    }
    func run(_ d: NativeProjectDocument, _ command: NativeTextStyleCommand) throws -> NativeProjectDocument {
        try planNativeTextStyle(d, command, engine: engine)
    }
    func styled() throws -> NativeProjectDocument {
        let saved = try run(document(), .save(clipId: "text:1", styleId: "style:title", name: "Title"))
        return try run(saved, .apply(styleId: "style:title", clipIds: ["text:1", "text:2", "text:3"]))
    }
    func testA1ThreeLayersFollowStyleUpdateExceptTheirColorOverride() throws {
        var d = try styled()
        d.sequence.tracks[0].clips[1].text?.color = "#ff0000"
        d.sequence.tracks[0].clips[1].textStyle?.overrides = ["color"]
        d.sequence.tracks[0].clips[2].text?.color = "#0000ff"
        d.sequence.tracks[0].clips[2].textStyle?.overrides = ["color"]
        d = try run(d, .update(styleId: "style:title", fromClipId: "text:2"))
        let clips = d.sequence.tracks[0].clips
        XCTAssertEqual(resolvedText(clips[1], d.textStyles ?? [])?.color, "#ff0000")
        XCTAssertEqual(resolvedText(clips[2], d.textStyles ?? [])?.color, "#0000ff")
        XCTAssertEqual(resolvedText(clips[3], d.textStyles ?? [])?.color, "#0000ff")
        XCTAssertEqual(resolvedText(clips[3], d.textStyles ?? [])?.content, "Words 3")
        XCTAssertEqual(d.textStyles?[0].text?.content, "")
    }
    func testA2DetachKeepsEveryResolvedValueIncludingDefaultOverride() throws {
        var d = try styled()
        d.sequence.tracks[0].clips[1].text?.fontSize = nil
        d.sequence.tracks[0].clips[1].textStyle?.overrides = ["fontSize"]
        let before = d.sequence.tracks[0].clips.map { resolvedText($0, d.textStyles ?? []) }
        d = try run(d, .detach(clipIds: ["text:1", "text:2", "text:3"]))
        XCTAssertEqual(before, d.sequence.tracks[0].clips.map { resolvedText($0, d.textStyles ?? []) })
        XCTAssertTrue(d.sequence.tracks[0].clips.allSatisfy { $0.textStyle == nil })
        XCTAssertEqual(d.sequence.tracks[0].clips[1].text?.resolvedFontSize, 16)
    }
    func testA3RoundTripAndOldDocumentByteIdentity() throws {
        let old = try serializeNativeProjectDocument(document(), engine: engine)
        XCTAssertFalse(old.contains("textStyle"))
        XCTAssertEqual(try serializeNativeProjectDocument(J(old), engine: engine), old)
        let d = try styled(), saved = try serializeNativeProjectDocument(d, engine: engine)
        XCTAssertEqual(try serializeNativeProjectDocument(J(saved), engine: engine), saved)
        XCTAssertEqual(try parseNativeProjectDocument(J(saved), engine: engine), d)
    }
    func testA3UnknownStyleIdAndDuplicateIdsAreTypedIssues() throws {
        var raw = try NativeJSONValue.from(styled())
        raw["sequence"]?["tracks"]?[0]?["clips"]?[1]?["textStyle"]?["styleId"] = .string("missing")
        XCTAssertTrue(validateNativeProjectDocument(raw, engine: engine).contains { $0.code == .invalidClip && $0.path.hasSuffix("textStyle.styleId") })
        raw = try NativeJSONValue.from(styled())
        let duplicate = raw["textStyles"]![0]!
        raw["textStyles"]?.append(duplicate)
        XCTAssertTrue(validateNativeProjectDocument(raw, engine: engine).contains { $0.code == .duplicateId && $0.path == "textStyles[1].id" })
    }
    func testFutureRecordsRetainJSONAreUndrawnAndProduceOneNotice() throws {
        var raw = try NativeJSONValue.from(styled())
        let future = J(#"{"v":2,"kind":"future-style","id":"style:title","payload":{"foo":[1,2]}}"#)
        raw["textStyles"] = .array([future])
        let d = try parseNativeProjectDocument(raw, engine: engine)
        XCTAssertEqual(try NativeJSONValue.from(d.textStyles![0]), future)
        XCTAssertNil(resolvedText(d.sequence.tracks[0].clips[1], d.textStyles ?? []))
        XCTAssertTrue(d.isUndrawnClip(d.sequence.tracks[0].clips[1]))
        XCTAssertEqual(d.undrawnContentNotices.count, 1)
        let link = J(#"{"v":5,"kind":"future-link","stuff":{"nested":true}}"#)
        raw["sequence"]?["tracks"]?[0]?["clips"]?[1]?["textStyle"] = link
        let futureDoc = try parseNativeProjectDocument(raw, engine: engine)
        XCTAssertEqual(try NativeJSONValue.from(futureDoc.sequence.tracks[0].clips[1].textStyle!), link)
    }
    func testInvalidStyleAndOverrideValuesAreRejectedTogether() throws {
        var raw = try NativeJSONValue.from(styled())
        raw["textStyles"]?[0]?["text"]?["fontSize"] = .number(-10)
        raw["textStyles"]?[0]?["text"]?["color"] = .string("bad")
        raw["sequence"]?["tracks"]?[0]?["clips"]?[1]?["textStyle"]?["overrides"] = .array([.string("color"), .string("color"), .string("content")])
        let issues = validateNativeProjectDocument(raw, engine: engine)
        XCTAssertEqual(issues.filter { $0.path.hasPrefix("textStyles[0].text") }.count, 2)
        XCTAssertEqual(issues.filter { $0.path.contains("overrides[") }.count, 2)
    }
    func testApplyIsAtomicWhenAnyTargetIsMissingOrLocked() throws {
        let d = try styled()
        XCTAssertThrowsError(try run(d, .apply(styleId: "style:title", clipIds: ["text:1", "missing"])))
        var locked = d; locked.sequence.tracks[0].locked = true
        XCTAssertThrowsError(try run(locked, .detach(clipIds: ["text:1"])))
        XCTAssertEqual(d.sequence.tracks[0].clips[1].textStyle?.styleId, "style:title")
    }
}
