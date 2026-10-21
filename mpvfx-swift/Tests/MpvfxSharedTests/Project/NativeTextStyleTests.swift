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

internal final class NativeTextStyleTests: XCTestCase {
    private let engine = KeyframeEngineStandIn()

    private func document() throws -> NativeProjectDocument {
        var raw = validNativeDocument()
        raw["assets"]?.append(J(#"{"id":"asset:text","kind":"element","name":"Text","durationFrames":120}"#))
        for number in 1...3 {
            raw["sequence"]?["tracks"]?[0]?["clips"]?.append(
                J(
                    """
                    {"id":"text:\(number)","assetId":"asset:text","startFrame":\(number * 120),
                    "durationFrames":120,"sourceInFrame":0,"effects":[],"parameterTracks":[],
                    "text":{"content":"Words \(number)","color":"#ffffff","fontSize":40}}
                    """
                )
            )
        }
        return try parseNativeProjectDocument(raw, engine: engine)
    }
    private func run(_ document: NativeProjectDocument, _ command: NativeTextStyleCommand) throws
        -> NativeProjectDocument
    {
        try planNativeTextStyle(document, command, engine: engine)
    }
    private func styled() throws -> NativeProjectDocument {
        let saved = try run(document(), .save(clipId: "text:1", styleId: "style:title", name: "Title"))
        return try run(saved, .apply(styleId: "style:title", clipIds: ["text:1", "text:2", "text:3"]))
    }
    internal func testA1ThreeLayersFollowStyleUpdateExceptTheirColorOverride() throws {
        var document = try styled()
        document.sequence.tracks[0].clips[1].text?.color = "#ff0000"
        document.sequence.tracks[0].clips[1].textStyle?.overrides = ["color"]
        document.sequence.tracks[0].clips[2].text?.color = "#0000ff"
        document.sequence.tracks[0].clips[2].textStyle?.overrides = ["color"]
        document = try run(document, .update(styleId: "style:title", fromClipId: "text:2"))
        let clips = document.sequence.tracks[0].clips
        XCTAssertEqual(resolvedText(clips[1], document.textStyles ?? [])?.color, "#ff0000")
        XCTAssertEqual(resolvedText(clips[2], document.textStyles ?? [])?.color, "#0000ff")
        XCTAssertEqual(resolvedText(clips[3], document.textStyles ?? [])?.color, "#0000ff")
        XCTAssertEqual(resolvedText(clips[3], document.textStyles ?? [])?.content, "Words 3")
        XCTAssertEqual(document.textStyles?[0].text?.content, "")
    }
    internal func testA2DetachKeepsEveryResolvedValueIncludingDefaultOverride() throws {
        var document = try styled()
        document.sequence.tracks[0].clips[1].text?.fontSize = nil
        document.sequence.tracks[0].clips[1].textStyle?.overrides = ["fontSize"]
        let before = document.sequence.tracks[0].clips.map { resolvedText($0, document.textStyles ?? []) }
        document = try run(document, .detach(clipIds: ["text:1", "text:2", "text:3"]))
        XCTAssertEqual(before, document.sequence.tracks[0].clips.map { resolvedText($0, document.textStyles ?? []) })
        XCTAssertTrue(document.sequence.tracks[0].clips.allSatisfy { $0.textStyle == nil })
        XCTAssertEqual(document.sequence.tracks[0].clips[1].text?.resolvedFontSize, 16)
    }
    internal func testA3RoundTripAndOldDocumentByteIdentity() throws {
        let old = try serializeNativeProjectDocument(document(), engine: engine)
        XCTAssertFalse(old.contains("textStyle"))
        XCTAssertEqual(try serializeNativeProjectDocument(J(old), engine: engine), old)
        let document = try styled()
        let saved = try serializeNativeProjectDocument(document, engine: engine)
        XCTAssertEqual(try serializeNativeProjectDocument(J(saved), engine: engine), saved)
        XCTAssertEqual(try parseNativeProjectDocument(J(saved), engine: engine), document)
    }
    internal func testA3UnknownStyleIdAndDuplicateIdsAreTypedIssues() throws {
        var raw = try NativeJSONValue.from(styled())
        raw["sequence"]?["tracks"]?[0]?["clips"]?[1]?["textStyle"]?["styleId"] = .string("missing")
        XCTAssertTrue(
            validateNativeProjectDocument(raw, engine: engine).contains {
                issue in issue.code == .invalidClip && issue.path.hasSuffix("textStyle.styleId")
            }
        )
        raw = try NativeJSONValue.from(styled())
        let styles = try XCTUnwrap(raw["textStyles"])
        let duplicate = try XCTUnwrap(styles[0])
        raw["textStyles"]?.append(duplicate)
        XCTAssertTrue(
            validateNativeProjectDocument(raw, engine: engine).contains {
                issue in issue.code == .duplicateId && issue.path == "textStyles[1].id"
            }
        )
    }
    internal func testFutureRecordsRetainJSONAreUndrawnAndProduceOneNotice() throws {
        var raw = try NativeJSONValue.from(styled())
        let future = J(#"{"v":2,"kind":"future-style","id":"style:title","payload":{"foo":[1,2]}}"#)
        raw["textStyles"] = .array([future])
        let document = try parseNativeProjectDocument(raw, engine: engine)
        XCTAssertEqual(try NativeJSONValue.from(XCTUnwrap(document.textStyles?.first)), future)
        XCTAssertNil(resolvedText(document.sequence.tracks[0].clips[1], document.textStyles ?? []))
        XCTAssertTrue(document.isUndrawnClip(document.sequence.tracks[0].clips[1]))
        XCTAssertEqual(document.undrawnContentNotices.count, 1)
        let link = J(#"{"v":5,"kind":"future-link","stuff":{"nested":true}}"#)
        raw["sequence"]?["tracks"]?[0]?["clips"]?[1]?["textStyle"] = link
        let futureDoc = try parseNativeProjectDocument(raw, engine: engine)
        XCTAssertEqual(try NativeJSONValue.from(XCTUnwrap(futureDoc.sequence.tracks[0].clips[1].textStyle)), link)
    }
    internal func testInvalidStyleValuesAreRejectedTogether() throws {
        var raw = try NativeJSONValue.from(styled())
        raw["textStyles"]?[0]?["text"]?["fontSize"] = .number(-10)
        raw["textStyles"]?[0]?["text"]?["color"] = .string("bad")
        let issues = validateNativeProjectDocument(raw, engine: engine)
        XCTAssertEqual(issues.filter { $0.path.hasPrefix("textStyles[0].text") }.count, 2)
    }

    internal func testDuplicateAndUnknownOverridesAreRejectedTogether() throws {
        var raw = try NativeJSONValue.from(styled())
        raw["sequence"]?["tracks"]?[0]?["clips"]?[1]?["textStyle"]?["overrides"] = .array([
            .string("color"), .string("color"), .string("content"),
        ])
        let issues = validateNativeProjectDocument(raw, engine: engine)
        XCTAssertEqual(issues.filter { $0.path.contains("overrides[") }.count, 2)
    }

    internal func testApplyIsAtomicWhenAnyTargetIsMissingOrLocked() throws {
        let document = try styled()
        XCTAssertThrowsError(try run(document, .apply(styleId: "style:title", clipIds: ["text:1", "missing"])))
        var locked = document
        locked.sequence.tracks[0].locked = true
        XCTAssertThrowsError(try run(locked, .detach(clipIds: ["text:1"])))
        XCTAssertEqual(document.sequence.tracks[0].clips[1].textStyle?.styleId, "style:title")
    }
    internal func testResolvedFutureStyleLookProducesNoticeOnlyWhenUsed() throws {
        var raw = try NativeJSONValue.from(styled())
        let futureLook = J(#"{"v":2,"glow":{"radius":30}}"#)
        raw["textStyles"]?[0]?["text"]?["look"] = futureLook
        var document = try parseNativeProjectDocument(raw, engine: engine)
        XCTAssertEqual(document.undrawnContentNotices.count, 1)
        XCTAssertTrue(try XCTUnwrap(document.unsupportedTextLooksNotice).contains("3 text looks"))
        let saved = try serializeNativeProjectDocument(document, engine: engine)
        document = try parseNativeProjectDocument(J(saved), engine: engine)
        XCTAssertEqual(try NativeJSONValue.from(XCTUnwrap(document.textStyles?.first?.text?.look)), futureLook)
        for index in 1...3 {
            document.sequence.tracks[0].clips[index].textStyle?.overrides = ["look"]
        }
        XCTAssertNil(document.unsupportedTextLooksNotice, "An overridden style look is not rendered")
    }

    internal func testOrderedCodecPreservesUnknownStyleKeys() throws {
        var raw = try NativeJSONValue.from(styled())
        let payload = J(#"{"mixed":[true,"value",3]}"#)
        raw["textStyles"]?[0]?["custom"] = payload
        let before = try serializeNativeProjectDocument(raw, engine: engine)
        let document = try parseNativeProjectDocument(J(before), engine: engine)
        XCTAssertEqual(try serializeNativeProjectDocument(document, engine: engine), before)
        let style = try XCTUnwrap(document.textStyles?.first)
        XCTAssertEqual(try NativeJSONValue.from(style)["custom"], payload)
    }

    internal func testOrderedCodecPreservesUnknownLinkKeys() throws {
        var raw = try NativeJSONValue.from(styled())
        raw["sequence"]?["tracks"]?[0]?["clips"]?[1]?["textStyle"]?["customLink"] = .string("retained")
        let before = try serializeNativeProjectDocument(raw, engine: engine)
        let document = try parseNativeProjectDocument(J(before), engine: engine)
        XCTAssertEqual(try serializeNativeProjectDocument(document, engine: engine), before)
        let link = try XCTUnwrap(document.sequence.tracks[0].clips[1].textStyle)
        XCTAssertEqual(try NativeJSONValue.from(link)["customLink"], .string("retained"))
    }

    internal func testOverrideCollectionRetainsAbsentEmptyAndPopulatedWireForms() throws {
        for overrides in [nil, J("[]"), J(#"["fontSize"]"#)] {
            var raw = try NativeJSONValue.from(styled())
            raw["sequence"]?["tracks"]?[0]?["clips"]?[1]?["textStyle"]?["overrides"] = overrides
            let before = try serializeNativeProjectDocument(raw, engine: engine)
            let document = try parseNativeProjectDocument(J(before), engine: engine)
            let link = try XCTUnwrap(document.sequence.tracks[0].clips[1].textStyle)
            XCTAssertEqual(try NativeJSONValue.from(link)["overrides"], overrides)
            XCTAssertEqual(try serializeNativeProjectDocument(document, engine: engine), before)
        }
        let newLink = NativeTextStyleLink(styleId: "style:title")
        XCTAssertNil(try NativeJSONValue.from(newLink)["overrides"])
    }

}
