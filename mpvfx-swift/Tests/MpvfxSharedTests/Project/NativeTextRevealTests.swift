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
// Text reveals: round trip, byte identity, one test per validator rule, unknown versions kept, and the timing of units.
import XCTest
@testable import MpvfxShared

final class NativeTextRevealTests: XCTestCase {
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

    func issues(_ reveal: String, key: String = "reveal") -> String {
        do { _ = try parse(textDocument(##"{"content":"H","\##(key)":\##(reveal)}"##)); return "" }
        catch let e as NativeProjectDocumentValidationError { return e.message }
        catch { return "\(error)" }
    }

    func testARevealAndAnUnrevealRoundTripAndOmitDefaults() throws {
        let reveal = ##"{"v":1,"unit":"characters","style":"typeOn","staggerFrames":2,"unitFrames":8,"order":"random","seed":7,"cursor":true}"##
        let doc = textDocument(##"{"content":"Hello","reveal":\##(reveal),"unreveal":{"v":1}}"##)
        let serialized = try serialize(doc)
        let text = try XCTUnwrap(try parse(J(serialized)).sequence.tracks[0].clips[1].text)
        XCTAssertEqual(text.reveal?.resolvedUnit, "characters")
        XCTAssertEqual(text.reveal?.resolvedSeed, 7)
        XCTAssertTrue(text.reveal?.hasCursor == true)
        XCTAssertEqual(text.unreveal?.resolvedUnit, "words", "an empty reveal holds every default")
        XCTAssertEqual(text.unreveal?.resolvedStaggerFrames, 3)
        XCTAssertEqual(try serialize(J(serialized)), serialized)
        XCTAssertEqual(try NativeJSONValue.from(try XCTUnwrap(text.unreveal)), J(##"{"v":1}"##), "defaults are omitted")
    }

    func testADocumentWithoutARevealOpensAndSavesByteIdentical() throws {
        let doc = textDocument(##"{"content":"Title"}"##)
        let serialized = try serialize(doc)
        XCTAssertFalse(serialized.contains("reveal"))
        XCTAssertEqual(try serialize(J(serialized)), serialized)
        let text = try XCTUnwrap(try parse(doc).sequence.tracks[0].clips[1].text)
        XCTAssertNil(text.reveal); XCTAssertNil(text.unreveal)
        XCTAssertEqual(try parse(doc).undrawnContentNotices, [])
    }

    func testEveryBadValueIsATypedIssue() {
        XCTAssertTrue(issues("[]").contains("Text reveal must be an object"))
        XCTAssertTrue(issues(##"{"unit":"words"}"##).contains("reveal.v"))
        XCTAssertTrue(issues(##"{"v":1,"unit":"letters"}"##).contains("reveal.unit"))
        XCTAssertTrue(issues(##"{"v":1,"unit":3}"##).contains("reveal.unit"))
        XCTAssertTrue(issues(##"{"v":1,"style":"spin"}"##).contains("reveal.style"))
        XCTAssertTrue(issues(##"{"v":1,"order":"sideways"}"##).contains("reveal.order"))
        XCTAssertTrue(issues(##"{"v":1,"staggerFrames":-1}"##).contains("Stagger must be a number of frames from 0 to 600"))
        XCTAssertTrue(issues(##"{"v":1,"staggerFrames":601}"##).contains("reveal.staggerFrames"))
        XCTAssertTrue(issues(##"{"v":1,"unitFrames":0}"##).contains("Unit length must be a number of frames from 1 to 600"))
        XCTAssertTrue(issues(##"{"v":1,"unitFrames":"5"}"##).contains("reveal.unitFrames"))
        XCTAssertTrue(issues(##"{"v":1,"seed":1.5}"##).contains("Seed must be a whole number"))
        XCTAssertTrue(issues(##"{"v":1,"seed":-1}"##).contains("reveal.seed"))
        XCTAssertTrue(issues(##"{"v":1,"cursor":"yes"}"##).contains("Cursor must be true or false"))
        XCTAssertTrue(issues(##"{"v":1,"style":"x"}"##, key: "unreveal").contains("unreveal.style"))
        XCTAssertEqual(issues(##"{"v":1,"unit":"lines","style":"grow","staggerFrames":0,"unitFrames":600,"order":"center","seed":0,"cursor":false}"##), "")
    }

    func testARevealFromANewerVersionIsKeptUnchangedNotDrawnAndNoticedOnce() throws {
        let reveal = ##"{"v":2,"unit":"syllables","style":"spin"}"##
        let doc = textDocument(##"{"content":"H","reveal":\##(reveal)}"##)
        let serialized = try serialize(doc)
        let reopened = try parse(J(serialized))
        XCTAssertEqual(try serialize(J(serialized)), serialized)
        let kept = try XCTUnwrap(reopened.sequence.tracks[0].clips[1].text?.reveal)
        XCTAssertFalse(kept.isSupported)
        XCTAssertEqual(try NativeJSONValue.from(kept), J(reveal))
        XCTAssertEqual(reopened.undrawnContentNotices,
                       ["1 text reveal from a newer version of the editor is kept in the project but not drawn in preview or export."])
        let timing = NativeTextRevealTiming(unitCount: 3, clipFrames: 60, reveal: kept, unreveal: nil)
        XCTAssertFalse(timing.isAnimating(atFrame: 0), "an unreadable reveal shows the text in full")
    }

    func testAStyleLinkedLayerKeepsItsOwnRevealAndTheStyleDoesNotStoreOne() throws {
        var raw = textDocument(##"{"content":"Words","reveal":{"v":1,"unit":"lines"},"unreveal":{"v":1,"style":"grow"}}"##)
        raw["sequence"]?["tracks"]?[0]?["clips"]?.append(J(
            ##"{"id":"clip:other","assetId":"asset:title","startFrame":300,"durationFrames":60,"sourceInFrame":0,"effects":[],"parameterTracks":[],"text":{"content":"Other"}}"##))
        var document = try parse(raw)
        document = try planNativeTextStyle(document, .save(clipId: "clip:title", styleId: "style:a", name: "A"), engine: engine)
        document = try planNativeTextStyle(document, .apply(styleId: "style:a", clipIds: ["clip:title", "clip:other"]), engine: engine)
        XCTAssertNil(document.textStyles?[0].text?.reveal, "a style holds typography, not animation")
        let clips = document.sequence.tracks[0].clips
        XCTAssertEqual(resolvedText(clips[1], document.textStyles ?? [])?.reveal?.resolvedUnit, "lines")
        XCTAssertEqual(resolvedText(clips[1], document.textStyles ?? [])?.unreveal?.resolvedStyle, "grow")
        XCTAssertNil(resolvedText(clips[2], document.textStyles ?? [])?.reveal)
    }

    // MARK: timing

    func timing(_ n: Int, clip: Double = 120, _ reveal: NativeTextReveal?, _ unreveal: NativeTextReveal? = nil) -> NativeTextRevealTiming {
        NativeTextRevealTiming(unitCount: n, clipFrames: clip, reveal: reveal, unreveal: unreveal)
    }

    func testWordThreeStartsAtFrameTenAndIsFullyShownAtFrameTwenty() {
        let t = timing(5, NativeTextReveal(unit: "words", staggerFrames: 5, unitFrames: 10))
        XCTAssertEqual(t.amounts(ofUnit: 2, atFrame: 9).arrived, 0)
        XCTAssertEqual(t.amounts(ofUnit: 2, atFrame: 10).arrived, 0)
        XCTAssertEqual(t.amounts(ofUnit: 2, atFrame: 15).arrived, 0.5, accuracy: 1e-9)
        XCTAssertEqual(t.amounts(ofUnit: 2, atFrame: 20).arrived, 1)
        XCTAssertEqual(t.amounts(ofUnit: 0, atFrame: 0).arrived, 0)
        XCTAssertEqual(t.revealFrames, 30, "the last unit starts at 4 * 5 and takes 10")
        XCTAssertTrue(t.isAnimating(atFrame: 29)); XCTAssertFalse(t.isAnimating(atFrame: 30))
    }

    func testOrdersForwardBackwardAndFromTheCentre() {
        XCTAssertEqual(NativeTextRevealTiming.ranks(5, NativeTextReveal(order: "forward")), [0, 1, 2, 3, 4])
        XCTAssertEqual(NativeTextRevealTiming.ranks(5, NativeTextReveal(order: "backward")), [4, 3, 2, 1, 0])
        XCTAssertEqual(NativeTextRevealTiming.ranks(5, NativeTextReveal(order: "center")), [3, 1, 0, 2, 4],
                       "the middle unit first, then its neighbours, the left one before the right")
        XCTAssertEqual(NativeTextRevealTiming.ranks(4, NativeTextReveal(order: "center")), [2, 0, 1, 3])
    }

    func testARandomOrderIsAPermutationFixedBySeedAndDiffersBetweenSeeds() {
        let a = NativeTextRevealTiming.ranks(12, NativeTextReveal(order: "random", seed: 5))
        XCTAssertEqual(a, NativeTextRevealTiming.ranks(12, NativeTextReveal(order: "random", seed: 5)))
        XCTAssertEqual(a.sorted(), Array(0..<12))
        XCTAssertNotEqual(a, NativeTextRevealTiming.ranks(12, NativeTextReveal(order: "random", seed: 6)))
        XCTAssertEqual(a, [6, 1, 11, 9, 10, 7, 4, 0, 2, 5, 3, 8], "pinned: the same on every platform and run")
    }

    func testRevealAndUnrevealCompressToFitTheClip() {
        let reveal = NativeTextReveal(staggerFrames: 10, unitFrames: 10)
        let t = timing(11, clip: 100, reveal, reveal)
        XCTAssertEqual(t.compression, 99.0 / 220.0, accuracy: 1e-9, "the last frame shown is frame 99")
        XCTAssertTrue(t.isCompressed)
        XCTAssertEqual(t.revealFrames + t.unrevealFrames, 99, accuracy: 1e-9)
        XCTAssertEqual(t.amounts(ofUnit: 10, atFrame: 99).remaining, 0, accuracy: 1e-9, "everything is gone on the last frame")
        XCTAssertEqual(t.amounts(ofUnit: 0, atFrame: 50).arrived, 1, accuracy: 1e-9)
        XCTAssertFalse(timing(3, clip: 100, reveal).isCompressed)
    }

    func testAnUnrevealLeavesTheLastUnitOnTheLastFrameOfTheClip() {
        let t = timing(3, clip: 60, nil, NativeTextReveal(staggerFrames: 4, unitFrames: 6))
        XCTAssertEqual(t.unrevealFrames, 14)
        XCTAssertEqual(t.amounts(ofUnit: 0, atFrame: 45).remaining, 1)
        XCTAssertEqual(t.amounts(ofUnit: 0, atFrame: 48).remaining, 0.5, accuracy: 1e-9)
        XCTAssertEqual(t.amounts(ofUnit: 2, atFrame: 59).remaining, 0, accuracy: 1e-9, "frame 59 is the last of a 60 frame clip")
        XCTAssertFalse(t.isAnimating(atFrame: 45)); XCTAssertTrue(t.isAnimating(atFrame: 46))
    }

    func testAOneFrameClipWithAnUnrevealDoesNotDivideByZero() {
        let t = timing(3, clip: 1, nil, NativeTextReveal(staggerFrames: 4, unitFrames: 6))
        XCTAssertEqual(t.compression, 0)
        for unit in 0..<3 { XCTAssertEqual(t.amounts(ofUnit: unit, atFrame: 0).remaining, 0) }
    }

    func testTypeOnShowsEachUnitAtOnceAtItsStart() {
        let t = timing(4, NativeTextReveal(style: "typeOn", staggerFrames: 3, unitFrames: 99))
        XCTAssertEqual(t.revealFrames, 9)
        XCTAssertEqual(t.amounts(ofUnit: 1, atFrame: 2.9).arrived, 0)
        XCTAssertEqual(t.amounts(ofUnit: 1, atFrame: 3).arrived, 1)
    }
}
