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

/// The slide, iris and zoom-through kinds in the document (issue #267): round trip, defaults omitted, typed issues
/// for every bad value, unknown keys kept, commands, and the span's ease and mix.
final class NativeTransitionKindsTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    typealias Base = NativeCutTransitionTests

    func entry(_ kind: String, _ fields: String = "") -> String {
        #"{"v":1,"id":"t1","fromClipId":"A","toClipId":"B","kind":"\#(kind)","durationFrames":30,"alignment":"centre"\#(fields)}"#
    }
    func parse(_ text: String) throws -> NativeProjectDocument { try parseNativeProjectDocument(try NativeJSONValue.parse(text), engine: engine) }
    func save(_ d: NativeProjectDocument) throws -> String { try serializeNativeProjectDocument(d, engine: engine) }
    func doc(_ kind: String, _ fields: String = "") throws -> NativeProjectDocument {
        try parse(Base.json(transitions: entry(kind, fields)))
    }
    func issues(_ kind: String, _ fields: String) throws -> [NativeProjectDocumentValidationIssue] {
        validateNativeProjectDocument(try NativeJSONValue.parse(Base.json(transitions: entry(kind, fields))), engine: engine)
    }
    let newKinds: [(String, NativeCutTransitionKind)] = [("slide", .slide), ("iris", .iris), ("zoomThrough", .zoomThrough)]

    // MARK: Round trip

    func testEachNewKindRoundTripsAndAnUntouchedDocumentIsByteIdentical() throws {
        for (name, kind) in newKinds {
            let opened = try doc(name)
            XCTAssertEqual(opened.sequence.tracks[0].cutTransitions.first?.kind, kind)
            let saved = try save(opened)
            let reopened = try parse(saved)
            XCTAssertEqual(reopened, opened, name)
            XCTAssertEqual(try save(reopened), saved, "\(name): a second save writes the same bytes")
            for key in ["angle", "shape", "centreX", "centreY", "strength", "ease", "direction"] {
                XCTAssertFalse(saved.contains("\"\(key)\""), "\(name): no \(key) key is added")
            }
            XCTAssertEqual(validateNativeProjectDocument(try NativeJSONValue.parse(saved), engine: engine), [])
        }
    }

    func testOptionsSurviveParseAndSerialize() throws {
        let fields = #","direction":"up","angle":45,"shape":"rectangle","centreX":0.25,"centreY":1.5,"strength":3,"ease":{"type":"linear"},"softness":0.4"#
        let opened = try doc("iris", fields)
        let t = try XCTUnwrap(opened.sequence.tracks[0].cutTransitions.first)
        XCTAssertEqual(t.angle, 45); XCTAssertEqual(t.irisShape, .rectangle); XCTAssertEqual(t.centreX, 0.25)
        XCTAssertEqual(t.centreY, 1.5); XCTAssertEqual(t.strength, 3); XCTAssertEqual(t.direction, .up)
        let reopened = try parse(try save(opened))
        XCTAssertEqual(reopened, opened)
    }

    // MARK: Defaults are omitted

    func testDefaultsSetThroughTheAccessorsAreOmitted() throws {
        var t = NativeCutTransition(id: "t1", cut: ("A", "B"), kind: .iris, durationFrames: 30)
        t.irisShape = .rectangle; t.centreX = 0.1; t.centreY = 0.9; t.strength = 3
        t.ease = .cubicBezier(.init(x1: 0.42, y1: 0, x2: 1, y2: 1))
        for key in ["shape", "centreX", "centreY", "strength", "ease"] { XCTAssertNotNil(t.object[key], key) }
        t.irisShape = .circle; t.centreX = 0.5; t.centreY = 0.5; t.strength = 2; t.ease = .linear
        for key in ["shape", "centreX", "centreY", "strength", "ease"] { XCTAssertNil(t.object[key], "\(key) at its default is absent") }
        XCTAssertEqual(t.irisShape, .circle); XCTAssertEqual(t.centreX, 0.5); XCTAssertEqual(t.strength, 2); XCTAssertEqual(t.ease, .linear)
    }

    // MARK: Typed issues, nothing clamped

    func assertBad(_ kind: String, _ fields: String, key: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let found = try issues(kind, fields)
        XCTAssertTrue(found.contains { $0.code == .invalidTransition && $0.path.hasSuffix("transitions[0].\(key)") },
                      "\(fields): \(found)", file: file, line: line)
        XCTAssertThrowsError(try parse(Base.json(transitions: entry(kind, fields))), file: file, line: line)
    }

    func testBadValuesAreTypedIssuesAtTheRightPath() throws {
        for angle in ["-1", "360", #""45""#] { try assertBad("wipe", #","angle":\#(angle)"#, key: "angle") }
        try assertBad("iris", #","shape":"star""#, key: "shape")
        for x in ["-0.6", "1.6"] { try assertBad("iris", #","centreX":\#(x)"#, key: "centreX") }
        for y in ["-0.6", "1.6"] { try assertBad("iris", #","centreY":\#(y)"#, key: "centreY") }
        for s in ["0.5", "4.5"] { try assertBad("zoomThrough", #","strength":\#(s)"#, key: "strength") }
        try assertBad("slide", #","ease":"wobble""#, key: "ease")
        try assertBad("slide", #","direction":"diagonal""#, key: "direction")
    }

    func testNaNAngleIsAnIssue() throws {
        var raw = try NativeJSONValue.parse(Base.json(transitions: entry("wipe", #","angle":10"#)))
        raw["sequence"]?["tracks"]?[0]?["transitions"]?[0]?["angle"] = .number(.nan)
        let found = validateNativeProjectDocument(raw, engine: engine)
        XCTAssertTrue(found.contains { $0.code == .invalidTransition && $0.path.hasSuffix("transitions[0].angle") }, "\(found)")
    }

    func testGoodBoundsAreAccepted() throws {
        for a in ["0", "359"] { XCTAssertEqual(try issues("wipe", #","angle":\#(a)"#), [], "angle \(a)") }
        for c in ["-0.5", "1.5"] {
            XCTAssertEqual(try issues("iris", #","centreX":\#(c),"centreY":\#(c)"#), [], "centre \(c)")
        }
        for s in ["1", "4"] { XCTAssertEqual(try issues("zoomThrough", #","strength":\#(s)"#), [], "strength \(s)") }
        let t = try XCTUnwrap(try doc("wipe", #","angle":359"#).sequence.tracks[0].cutTransitions.first)
        XCTAssertEqual(t.angle, 359, "kept exactly, not clamped")
    }

    // MARK: Unknown keys and kinds

    func testUnknownKeysIncludingParamsSurvive() throws {
        for (name, _) in newKinds {
            let opened = try doc(name, #","params":{"curve":[1,2,3],"mode":"x"},"futureOption":"kept""#)
            let saved = try save(opened)
            XCTAssertTrue(saved.contains(#""futureOption": "kept""#) && saved.contains(#""curve""#), name)
            let t = try XCTUnwrap(try parse(saved).sequence.tracks[0].cutTransitions.first)
            XCTAssertEqual(t, opened.sequence.tracks[0].cutTransitions[0], name)
            XCTAssertNotNil(t.object["params"])
            XCTAssertEqual(try save(try parse(saved)), saved)
        }
    }

    func testAnUnknownKindStaysUnchangedAndIsAHardCut() throws {
        let future = entry("shatter", #","angle":999,"params":{"n":3}"#)
        let opened = try parse(Base.json(transitions: future))
        let t = try XCTUnwrap(opened.sequence.tracks[0].cutTransitions.first)
        XCTAssertNil(t.kind); XCTAssertFalse(t.isKnown)
        let saved = try save(opened)
        XCTAssertTrue(saved.contains(#""kind": "shatter""#) && saved.contains(#""angle": 999"#), "not validated, not clamped")
        XCTAssertEqual(try parse(saved), opened)
        XCTAssertTrue(nativeCutTransitionSpans(opened).isEmpty, "span nil: a hard cut")
    }

    // MARK: Commands

    func testCommandsChangeTheEntryAndUndoInOneStep() throws {
        let base = try doc("wipe")
        let steps: [(NativeCutTransitionCommand, (NativeCutTransition) -> Bool)] = [
            (.setAngle(id: "t1", angle: 45), { $0.angle == 45 }),
            (.setIris(id: "t1", shape: .rectangle, centreX: 0.25, centreY: 0.75), { $0.irisShape == .rectangle && $0.centreX == 0.25 && $0.centreY == 0.75 }),
            (.setStrength(id: "t1", strength: 3), { $0.strength == 3 }),
            (.setEase(id: "t1", ease: .cubicBezier(.init(x1: 0.42, y1: 0, x2: 1, y2: 1))), { $0.ease != .linear }),
        ]
        for (step, check) in steps {
            guard case .success(let next, let inverse) = try applyNativeCutTransitionCommand(base, step, engine: engine) else {
                return XCTFail("\(step) refused")
            }
            XCTAssertTrue(check(try XCTUnwrap(next.sequence.tracks[0].cutTransitions.first)), "\(step)")
            XCTAssertNotEqual(next, base)
            XCTAssertEqual(try applyNativeProjectClipCommand(next, inverse, engine: engine).document, base, "one undo restores \(step)")
        }
        let cleared = try applyNativeCutTransitionCommand(try doc("wipe", #","angle":45"#), .setAngle(id: "t1", angle: nil), engine: engine)
        XCTAssertNil(cleared.document.sequence.tracks[0].cutTransitions.first?.angle)
    }

    func testInvalidCommandValuesAreRefusedWithTheDocumentUnchanged() throws {
        let base = try doc("iris")
        let bad: [NativeCutTransitionCommand] = [
            .setAngle(id: "t1", angle: -1), .setAngle(id: "t1", angle: 360), .setAngle(id: "t1", angle: .nan),
            .setIris(id: "t1", shape: .circle, centreX: -0.6, centreY: 0.5), .setIris(id: "t1", shape: .circle, centreX: 0.5, centreY: 1.6),
            .setStrength(id: "t1", strength: 0.5), .setStrength(id: "t1", strength: 4.5),
        ]
        for command in bad {
            let r = try applyNativeCutTransitionCommand(base, command, engine: engine)
            XCTAssertFalse(r.ok, "\(command)")
            XCTAssertNotNil(r.failure, "\(command)")
            XCTAssertEqual(r.document, base, "\(command) leaves the document unchanged")
        }
        let edges: [NativeCutTransitionCommand] = [.setAngle(id: "t1", angle: 0), .setAngle(id: "t1", angle: 359),
                                                   .setStrength(id: "t1", strength: 1), .setStrength(id: "t1", strength: 4),
                                                   .setIris(id: "t1", shape: .circle, centreX: -0.5, centreY: 1.5)]
        for command in edges { XCTAssertTrue(try applyNativeCutTransitionCommand(base, command, engine: engine).ok, "\(command)") }
    }

    // MARK: Spans

    func testSpanCarriesTheNewOptions() throws {
        let fields = #","angle":45,"shape":"rectangle","centreX":0.25,"centreY":0.75,"strength":3,"direction":"down","ease":{"type":"hold"}"#
        let s = try XCTUnwrap(nativeCutTransitionSpans(try doc("iris", fields))["B"]?.incoming)
        XCTAssertEqual(s.kind, .iris); XCTAssertEqual(s.angle, 45); XCTAssertEqual(s.irisShape, .rectangle)
        XCTAssertEqual(s.centreX, 0.25); XCTAssertEqual(s.centreY, 0.75); XCTAssertEqual(s.strength, 3)
        XCTAssertEqual(s.direction, .down); XCTAssertEqual(s.ease, .hold)
        let plain = try XCTUnwrap(nativeCutTransitionSpans(try doc("zoomThrough"))["B"]?.incoming)
        XCTAssertNil(plain.angle); XCTAssertEqual(plain.irisShape, .circle); XCTAssertEqual(plain.strength, 2); XCTAssertEqual(plain.ease, .linear)
    }

    func testEasedProgressFollowsTheEase() throws {
        let linear = try XCTUnwrap(nativeCutTransitionSpans(try doc("slide"))["B"]?.incoming)
        let quarter = linear.startFrame + (linear.endFrame - linear.startFrame) * 0.25
        XCTAssertEqual(linear.easedProgress(atFrame: quarter), linear.progress(atFrame: quarter), accuracy: 1e-12)
        XCTAssertEqual(linear.progress(atFrame: quarter), 0.25, accuracy: 1e-12)
        let easeIn = #","ease":{"type":"cubic-bezier","controlPoints":{"x1":0.42,"y1":0,"x2":1,"y2":1}}"#
        let eased = try XCTUnwrap(nativeCutTransitionSpans(try doc("slide", easeIn))["B"]?.incoming)
        XCTAssertLessThan(eased.easedProgress(atFrame: quarter), eased.progress(atFrame: quarter))
        XCTAssertEqual(eased.easedProgress(atFrame: eased.startFrame), 0, accuracy: 1e-9)
        XCTAssertEqual(eased.easedProgress(atFrame: eased.endFrame), 1, accuracy: 1e-9)
    }

    func testMixesOfZoomThroughAndDissolve() throws {
        let easeIn = #","ease":{"type":"cubic-bezier","controlPoints":{"x1":0.42,"y1":0,"x2":1,"y2":1}}"#
        let zoom = try XCTUnwrap(nativeCutTransitionSpans(try doc("zoomThrough", easeIn))["B"]?.incoming)
        let dissolve = try XCTUnwrap(nativeCutTransitionSpans(try doc("dissolve", easeIn))["B"]?.incoming)
        for f in stride(from: zoom.startFrame, through: zoom.endFrame, by: 5) {
            XCTAssertEqual(zoom.incomingMix(atFrame: f), NativeTransitionMix(opacity: zoom.easedProgress(atFrame: f)), "frame \(f)")
            XCTAssertEqual(zoom.outgoingMix(atFrame: f), .none, "frame \(f)")
            XCTAssertEqual(dissolve.incomingMix(atFrame: f).opacity, dissolve.easedProgress(atFrame: f), "dissolve follows the ease at \(f)")
        }
        let quarter = dissolve.startFrame + (dissolve.endFrame - dissolve.startFrame) * 0.25
        XCTAssertLessThan(dissolve.incomingMix(atFrame: quarter).opacity, 0.25)
    }
}
