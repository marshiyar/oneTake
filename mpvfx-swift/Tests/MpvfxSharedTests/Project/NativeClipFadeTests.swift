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

/// Clip fades (`fadeInFrames` / `fadeOutFrames`, issue #85): the document round trip, the validator, the gain ramp,
/// and what split and trim do to them. Uses `clip:audio` and `clip:second` of the clip-command fixture, which have no
/// parameter tracks, so the stand-in engine never slices.
final class NativeClipFadeTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    let audio = NativeProjectClipAddress(sequenceId: "sequence:main", trackId: "track:a1", clipId: "clip:audio")

    func parse(_ d: NativeJSONValue) throws -> NativeProjectDocument { try parseNativeProjectDocument(d, engine: engine) }
    func serialize(_ d: NativeJSONValue) throws -> String { try serializeNativeProjectDocument(d, engine: engine) }
    func serialize(_ d: NativeProjectDocument) throws -> String { try serializeNativeProjectDocument(d, engine: engine) }
    func fixture() throws -> NativeProjectDocument { try parse(J(clipCommandsFixtureJSON)) }
    /// The fixture with `clip:audio` (120 frames) faded in over `fadeIn` and out over `fadeOut` frames.
    func faded(_ fadeIn: Double?, _ fadeOut: Double?) throws -> NativeProjectDocument {
        var d = try fixture()
        mutateClip(&d, "clip:audio") { $0.fadeInFrames = fadeIn; $0.fadeOutFrames = fadeOut }
        return try parseNativeProjectDocument(d, engine: engine)
    }
    func withFades(_ fields: [String: NativeJSONValue]) -> NativeJSONValue {
        var d = J(clipCommandsFixtureJSON)
        for (k, v) in fields { d["sequence"]?["tracks"]?[2]?["clips"]?[0]?[k] = v }
        return d
    }
    func issues(_ d: NativeJSONValue, file: StaticString = #filePath, line: UInt = #line) -> [NativeProjectDocumentValidationIssue] {
        do { _ = try parse(d); XCTFail("accepted", file: file, line: line); return [] }
        catch let e as NativeProjectDocumentValidationError { return e.issues }
        catch { XCTFail("wrong error \(error)", file: file, line: line); return [] }
    }

    // MARK: A clip with fades saves and reopens unchanged. A document without fades opens and saves byte-identical.

    func testClipWithFadesSavesAndReopensUnchanged() throws {
        let doc = try faded(15, 30.5)
        let text = try serialize(doc)
        XCTAssertTrue(text.contains("\"fadeInFrames\": 15"), text)
        XCTAssertTrue(text.contains("\"fadeOutFrames\": 30.5"), text)
        let reopened = try parse(J(text))
        XCTAssertEqual(reopened, doc)
        XCTAssertEqual(findClip(reopened, "clip:audio")?.fadeInFrames, 15)
        XCTAssertEqual(findClip(reopened, "clip:audio")?.fadeOutFrames, 30.5)
        XCTAssertEqual(try serialize(reopened), text, "a second save writes the same bytes")
    }

    func testDocumentWithoutFadesOpensAndSavesByteIdentical() throws {
        let saved = try serialize(J(clipCommandsFixtureJSON))
        XCTAssertFalse(saved.contains("fade"), "no fade key is written for a clip without fades")
        let reopened = try parse(J(saved))
        XCTAssertTrue(reopened.sequence.tracks.flatMap(\.clips).allSatisfy { $0.fadeInFrames == nil && $0.fadeOutFrames == nil })
        XCTAssertEqual(Array(try serialize(reopened).utf8), Array(saved.utf8))
    }

    // MARK: The validator refuses negative or non-finite fades, and fades that together are longer than the clip,
    // each with a typed error.

    func testValidatorRefusesNegativeOrNonFiniteFadesWithATypedError() {
        assertInvalidFade("fadeInFrames", .number(-1))
        assertInvalidFade("fadeOutFrames", .number(-0.5))
        assertInvalidFade("fadeInFrames", .number(.infinity))
        assertInvalidFade("fadeOutFrames", .number(.nan))
        assertInvalidFade("fadeInFrames", .string("10"))
        assertInvalidFade("fadeOutFrames", .bool(true))
    }

    func assertInvalidFade(_ key: String, _ value: NativeJSONValue, file: StaticString = #filePath, line: UInt = #line) {
        let found = issues(withFades([key: value]), file: file, line: line)
        XCTAssertEqual(found.map(\.code), [.invalidFade], "\(key) = \(value)", file: file, line: line)
        XCTAssertEqual(found.first?.path, "sequence.tracks[2].clips[0].\(key)", file: file, line: line)
        XCTAssertEqual(found.first?.message, "Fade length must be a finite non-negative number of frames", file: file, line: line)
    }

    func testValidatorRefusesFadesLongerThanTheClipWithATypedError() throws {
        let found = issues(withFades(["fadeInFrames": .number(80), "fadeOutFrames": .number(41)]))
        XCTAssertEqual(found.map(\.code), [.fadeExceedsClip])
        XCTAssertEqual(found.first?.path, "sequence.tracks[2].clips[0]")
        XCTAssertEqual(found.first?.message, "Fade in and fade out together must not be longer than the clip")
        XCTAssertEqual(issues(withFades(["fadeOutFrames": .number(121)])).map(\.code), [.fadeExceedsClip], "one fade alone")
        XCTAssertNoThrow(try parse(withFades(["fadeInFrames": .number(80), "fadeOutFrames": .number(40)])), "exactly the clip is allowed")
        XCTAssertNoThrow(try parse(withFades(["fadeInFrames": .number(0), "fadeOutFrames": .number(0)])))
    }

    // MARK: the ramp the audio graph renders (and slice 2's opacity will read)

    func testGainIsLinearAndClamped() {
        let g = { (f: Double) in NativeClipFade.gain(atFrame: f, durationFrames: 120, fadeInFrames: 30, fadeOutFrames: 60) }
        XCTAssertEqual(g(0), 0); XCTAssertEqual(g(15), 0.5); XCTAssertEqual(g(30), 1); XCTAssertEqual(g(45), 1)
        XCTAssertEqual(g(60), 1); XCTAssertEqual(g(90), 0.5); XCTAssertEqual(g(120), 0)
        XCTAssertEqual(g(-5), 0, "before the clip"); XCTAssertEqual(g(200), 0, "after the clip")
        XCTAssertEqual(NativeClipFade.gain(atFrame: 0, durationFrames: 120, fadeInFrames: nil, fadeOutFrames: 0), 1, "no fades: unity")
        var clip = NativeProjectClip.fresh(id: "c", assetId: "a", startFrame: 0, durationFrames: 120)
        XCTAssertEqual(clip.fadeGain(atFrame: 0), 1)
        clip.fadeInFrames = 30
        XCTAssertEqual(clip.fadeGain(atFrame: 6), 0.2, accuracy: 1e-12)
    }

    // MARK: Splitting a faded clip keeps the fade-in on the left part and the fade-out on the right part, as one
    // undo step. A trim clamps the fades.

    func testSplitKeepsFadeInOnTheLeftAndFadeOutOnTheRightAsOneUndoStep() throws {
        let original = try faded(30, 45)
        let r = try applyNativeProjectClipCommand(original, .split(address: audio, splitFrame: 50), engine: engine)
        XCTAssertTrue(r.ok, "\(String(describing: r.failure))")
        let left = findClip(r.document, "clip:audio"), right = findClip(r.document, nativeSplitClipId("clip:audio", splitFrame: 50))
        XCTAssertEqual(left?.durationFrames, 50); XCTAssertEqual(right?.durationFrames, 70)
        XCTAssertEqual(left?.fadeInFrames, 30); XCTAssertNil(left?.fadeOutFrames)
        XCTAssertNil(right?.fadeInFrames); XCTAssertEqual(right?.fadeOutFrames, 45)
        let undo = try applyNativeProjectClipCommand(r.document, try XCTUnwrap(r.inverse), engine: engine)
        XCTAssertTrue(undo.ok)
        XCTAssertEqual(try serialize(undo.document), try serialize(original), "one inverse restores both fades")
    }

    func testSplitInsideAFadeClampsItToItsPart() throws {
        let r = try applyNativeProjectClipCommand(try faded(100, 1), .split(address: audio, splitFrame: 20), engine: engine)
        XCTAssertTrue(r.ok, "\(String(describing: r.failure))")
        XCTAssertEqual(findClip(r.document, "clip:audio")?.fadeInFrames, 20, "a fade-in longer than the left part is clamped to it")
        XCTAssertEqual(findClip(r.document, nativeSplitClipId("clip:audio", splitFrame: 20))?.fadeOutFrames, 1)
    }

    func testTrimClampsTheFades() throws {
        // Trim-out to 70 frames: the fade-out (the moved edge) gives way, the fade-in stays.
        let out = try applyNativeProjectClipCommand(try faded(40, 50), .trimOut(address: audio, endFrameExclusive: 70), engine: engine)
        XCTAssertTrue(out.ok, "\(String(describing: out.failure))")
        XCTAssertEqual(findClip(out.document, "clip:audio")?.fadeInFrames, 40)
        XCTAssertEqual(findClip(out.document, "clip:audio")?.fadeOutFrames, 30)
        // Trim-in to 70 frames: the fade-in gives way, the fade-out stays.
        let tin = try applyNativeProjectClipCommand(try faded(40, 50), .trimIn(address: audio, startFrame: 50), engine: engine)
        XCTAssertTrue(tin.ok, "\(String(describing: tin.failure))")
        XCTAssertEqual(findClip(tin.document, "clip:audio")?.fadeInFrames, 20)
        XCTAssertEqual(findClip(tin.document, "clip:audio")?.fadeOutFrames, 50)
        // Trim to 30 frames: the kept fade is clamped to the clip, the other one is gone.
        let short = try applyNativeProjectClipCommand(try faded(40, 50), .trimOut(address: audio, endFrameExclusive: 30), engine: engine)
        XCTAssertEqual(findClip(short.document, "clip:audio")?.fadeInFrames, 30)
        XCTAssertNil(findClip(short.document, "clip:audio")?.fadeOutFrames)
        // A trim that leaves room changes nothing.
        let roomy = try applyNativeProjectClipCommand(try faded(10, 10), .trimOut(address: audio, endFrameExclusive: 100), engine: engine)
        XCTAssertEqual(findClip(roomy.document, "clip:audio")?.fadeInFrames, 10)
        XCTAssertEqual(findClip(roomy.document, "clip:audio")?.fadeOutFrames, 10)
    }
}
