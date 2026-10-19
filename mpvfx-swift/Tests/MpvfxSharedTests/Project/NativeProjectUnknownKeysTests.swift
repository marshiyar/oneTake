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
// Unknown keys survive parse -> serialize exactly where the document keeps them
// (records copied whole / passed through) and are dropped where records are rebuilt field by field. Key order is checked
// per object against JS order (array-index keys first, ascending, then insertion order).
import XCTest
@testable import MpvfxShared

final class NativeProjectUnknownKeysTests: XCTestCase {
    let engine = KeyframeEngineStandIn()

    /// The repo fixture (validNativeDocument) extended so every
    /// nesting level exists: audio group, binding, sourceInFraction, crop-pivot segment with reference, effect with
    /// parameters, and rotation parameter tracks with keyframes.
    func richFixture() -> NativeJSONValue {
        var d = validNativeDocument()
        d["sequence"]?["audioGroups"] = J(#"[{"id":"dialogue","label":"Dialogue","volume":0.5,"muted":false}]"#)
        let track = J("""
        {"schemaVersion":1,"id":"parameter:rot","parameterId":"transform.rotation","valueType":"number",
         "frameRate":{"numerator":30000,"denominator":1001},"keyframes":[
          {"id":"key:a","frame":0,"value":0,"outgoing":{"type":"linear"}},
          {"id":"key:b","frame":60,"value":90,"outgoing":{"type":"linear"}}]}
        """)
        var clip = d["sequence"]!["tracks"]![0]!["clips"]![0]!
        clip["audioGroupId"] = .string("dialogue")
        clip["binding"] = J(#"{"sourceFile":"a.html","domId":"clip"}"#)
        clip["sourceInFraction"] = J(#"{"numerator":1,"denominator":3}"#)
        clip["playbackRate"] = J(#"{"numerator":1,"denominator":1}"#)
        clip["muted"] = .bool(false)
        clip["staticParameters"] = J(#"{"opacity":0.5}"#)
        clip["cropPivotSegments"] = .array([J("""
        {"startRotationKeyId":"key:a","endRotationKeyId":"key:b","offsetFraction":{"x":0.05,"y":-0.1},
         "reference":{"frameOffset":0,"durationFrames":60,"startRotationKeyId":"key:a","endRotationKeyId":"key:b",
          "parameterTracks":[\(jsJSONStringify(track))],"staticParameters":{"opacity":1}}}
        """)])
        clip["effects"] = J(#"[{"id":"effect:blur","effectId":"blur","enabled":true,"parameters":{"radius":4}}]"#)
        clip["parameterTracks"] = .array([track])
        d["sequence"]?["tracks"]?[0]?["clips"]?[0] = clip
        d["sequence"]?["tracks"]?[0]?["lane"] = J(#"{"authoredTrack":0,"displayTrack":0}"#)
        return d
    }

    // Where an object is rebuilt, its parse output has exactly these keys in this order.
    static let rebuilt: [String: [String]] = [
        "root": ["schemaVersion", "mediaEngine", "id", "revision", "frameRate", "canvas", "assets", "sequence"],
        "sequence": ["id", "name", "durationFrames", "audioGroups", "tracks"],
        "group": ["id", "label", "volume", "muted", "fxChain", "automation"],
        "track": ["id", "kind", "lane", "clips"],
        "clip": ["id", "assetId", "audioGroupId", "audioFxChain", "audioAutomation", "audioDetachedFrom", "binding", "startFrame",
                 "durationFrames", "sourceInFrame", "sourceInFraction", "playbackRate", "muted", "staticParameters",
                 "cropPivotSegments", "effects", "parameterTracks"],
        "binding": ["sourceFile", "domId", "hfId", "selector", "selectorIndex"],
        "segment": ["startRotationKeyId", "endRotationKeyId", "offsetFraction", "reference"],
        "rate": ["numerator", "denominator"],
    ]

    /// Kind of the object at a child key, following NativeProjectDocument.swift.
    func childKind(_ kind: String, _ key: String) -> String {
        switch (kind, key) {
        case ("root", "sequence"): return "sequence"
        case ("root", "assets"), ("root", "frameRate"), ("root", "canvas"): return "spread"
        case ("sequence", "audioGroups"): return "group"
        case ("sequence", "tracks"): return "track"
        case ("track", "lane"): return "spread"
        case ("track", "clips"): return "clip"
        case ("clip", "binding"): return "binding"
        case ("clip", "playbackRate"): return "rate"
        case ("clip", "sourceInFraction"), ("clip", "effects"), ("clip", "parameterTracks"): return "spread"
        case ("clip", "staticParameters"), ("spread", "staticParameters"): return "static"
        case ("clip", "cropPivotSegments"): return "segment"
        case ("segment", "offsetFraction"), ("segment", "reference"): return "spread"
        case ("static", _): return "static"
        default: return kind == "spread" ? "spread" : "leaf"
        }
    }

    /// Input with unknown keys: one leading, one integer-like trailing key (JS moves it to the front), one nested object.
    /// Rebuilt objects get their keys reversed so the fixed literal order is actually exercised. Static-parameter maps
    /// and values are left alone (their shape is validated exactly).
    func inject(_ v: NativeJSONValue, _ kind: String, _ level: Int) -> NativeJSONValue {
        switch v {
        case .array(let a): return .array(a.map { inject($0, kind, level) })
        case .object(let o) where kind != "static" && kind != "leaf":
            var r = NativeJSONObject()
            r["_pre\(level)"] = .number(Double(level))
            let keys = Self.rebuilt[kind] != nil ? Array(o.keys.reversed()) : Array(o.keys)
            for k in keys { r[k] = inject(o[k]!, childKind(kind, k), level + 1) }
            r["\(level)"] = .string("index-\(level)")
            r["zz\(level)"] = .object(["deep": .bool(true), "7": .null])
            return .object(r)
        case .object(let o) where kind == "leaf":
            // Inside copied/pass-through records (e.g. keyframes, outgoing interpolation): kept verbatim.
            var r = NativeJSONObject(); r["_pre\(level)"] = .number(Double(level))
            for (k, x) in o { r[k] = inject(x, "leaf", level + 1) }
            r["zz\(level)"] = .string("x"); return .object(r)
        default: return v
        }
    }

    /// What parse returns for the injected input: rebuilt objects keep only known keys in literal order.
    func expected(_ v: NativeJSONValue, _ kind: String) -> NativeJSONValue {
        switch v {
        case .array(let a): return .array(a.map { expected($0, kind) })
        case .object(let o):
            var r = NativeJSONObject()
            if let order = Self.rebuilt[kind] {
                for k in order { if let x = o[k] { r[k] = expected(x, childKind(kind, k)) } }
            } else {
                for (k, x) in o { r[k] = expected(x, childKind(kind, k)) }
            }
            return .object(r)
        default: return v
        }
    }

    /// Structural equality and identical key order for every object.
    func assertSameOrdered(_ a: NativeJSONValue, _ b: NativeJSONValue, _ path: String = "$", file: StaticString = #filePath, line: UInt = #line) {
        switch (a, b) {
        case (.object(let x), .object(let y)):
            XCTAssertEqual(Array(x.keys), Array(y.keys), "key order at \(path)", file: file, line: line)
            for k in x.keys { if let yv = y[k] { assertSameOrdered(x[k]!, yv, "\(path).\(k)", file: file, line: line) } }
        case (.array(let x), .array(let y)):
            XCTAssertEqual(x.count, y.count, "length at \(path)", file: file, line: line)
            for (i, (p, q)) in zip(x, y).enumerated() { assertSameOrdered(p, q, "\(path)[\(i)]", file: file, line: line) }
        default: XCTAssertEqual(a, b, path, file: file, line: line)
        }
    }

    func testFixtureWithUnknownKeysAtEveryLevelRoundTripsExactly() throws {
        let input = inject(richFixture(), "root", 0)
        let want = expected(input, "root")
        // Sanity: the injection reached the deepest pass-through levels.
        XCTAssertNotNil(want["sequence"]?["tracks"]?[0]?["clips"]?[0]?["parameterTracks"]?[0]?["keyframes"]?[0]?["outgoing"]?["zz6"])
        XCTAssertNotNil(want["sequence"]?["tracks"]?[0]?["clips"]?[0]?["cropPivotSegments"]?[0]?["reference"]?["zz5"])
        XCTAssertNil(want["sequence"]?["tracks"]?[0]?["clips"]?[0]?["playbackRate"]?["zz5"])

        let parsed = try parseNativeProjectDocument(input, engine: engine)
        assertSameOrdered(try NativeJSONValue.from(parsed), want)

        let text = try serializeNativeProjectDocument(input, engine: engine)
        XCTAssertEqual(text, jsJSONStringify(canonicalizeNativeJSON(want), indent: 2) + "\n")
        // Serialized output is a fixed point and parses back to an equal document, extras included.
        XCTAssertEqual(try serializeNativeProjectDocument(J(text), engine: engine), text)
        XCTAssertEqual(try parseNativeProjectDocument(J(text), engine: engine), parsed)
        XCTAssertEqual(try NativeJSONValue.from(parseNativeProjectDocument(J(text), engine: engine)), want)
    }

    func testAssetUnknownKeysRoundTrip() throws {
        var d = validNativeDocument()
        d["assets"]?[0] = J(#"{"meta":{"b":1,"a":[2]},"id":"asset:camera-a","kind":"video","name":"camera-a.mov","durationFrames":300,"3":"x"}"#)
        let a = try parseNativeProjectDocument(d, engine: engine).assets[0]
        let out = try NativeJSONValue.from(a)
        assertSameOrdered(out, J(#"{"3":"x","meta":{"b":1,"a":[2]},"id":"asset:camera-a","kind":"video","name":"camera-a.mov","durationFrames":300}"#))
        XCTAssertEqual(try parseNativeProjectDocument(J(try serializeNativeProjectDocument(d, engine: engine)), engine: engine).assets[0], a)
    }

    func testEffectUnknownKeysRoundTrip() throws {
        var d = validNativeDocument()
        let e = J(#"{"label":"Soft","id":"effect:blur","effectId":"blur","enabled":true,"parameters":{"z":1,"a":{"q":true}},"mix":null}"#)
        d["sequence"]?["tracks"]?[0]?["clips"]?[0]?["effects"] = .array([e])
        let effect = try parseNativeProjectDocument(d, engine: engine).sequence.tracks[0].clips[0].effects[0]
        assertSameOrdered(try NativeJSONValue.from(effect), e)
        XCTAssertEqual(effect.spread.extra["mix"], .null) // null stays distinct from absent
        XCTAssertEqual(try parseNativeProjectDocument(J(try serializeNativeProjectDocument(d, engine: engine)), engine: engine)
            .sequence.tracks[0].clips[0].effects[0], effect)
    }

    func testCropPivotReferenceUnknownKeysRoundTrip() throws {
        let d = inject(richFixture(), "root", 0)
        let ref = try parseNativeProjectDocument(d, engine: engine).sequence.tracks[0].clips[0].cropPivotSegments![0].reference!
        XCTAssertEqual(ref.spread.extra["_pre5"], .number(5))
        XCTAssertEqual(Array(try NativeJSONValue.from(ref).objectValue!.keys).prefix(2), ["5", "_pre5"])
        XCTAssertEqual(try parseNativeProjectDocument(J(try serializeNativeProjectDocument(d, engine: engine)), engine: engine)
            .sequence.tracks[0].clips[0].cropPivotSegments![0].reference, ref)
    }

    func injectedTrack() throws -> NativeParameterTrack {
        try parseNativeProjectDocument(inject(richFixture(), "root", 0), engine: engine).sequence.tracks[0].clips[0].parameterTracks[0]
    }

    /// `{ ...track, keyframes: track.keyframes.map((k) => ({ ...k, value })) }` (property command
    /// offset edits): every unknown key survives. Swift's in-place mutation is the same operation.
    func testSpreadStyleTrackEditKeepsUnknownKeysAtEveryLevel() throws {
        var track = try injectedTrack()
        track.keyframes = track.keyframes.map { k in var n = k; if case .number(let v) = k.value { n.value = .number(v + 1) }; return n }
        let out = try NativeJSONValue.from(track)
        XCTAssertEqual(out["zz4"]?["deep"], .bool(true))
        XCTAssertEqual(out["frameRate"]?["zz5"]?["deep"], .bool(true))
        XCTAssertEqual(out["keyframes"]?[0]?["zz5"]?["deep"], .bool(true))
        XCTAssertEqual(out["keyframes"]?[0]?["outgoing"]?["zz6"]?["deep"], .bool(true))
        XCTAssertEqual(out["keyframes"]?[1]?["value"], .number(91))
        XCTAssertEqual(Array(out.objectValue!.keys).prefix(2), ["4", "_pre4"])
    }

    /// Keyframe commands rebuild through createNativeParameterTrack:
    /// track- and keyframe-level unknown keys go; frameRate, value and outgoing objects are kept as they are.
    func testKeyframeCommandKeepsWhatCreateNativeParameterTrackKeeps() throws {
        let track = try injectedTrack()
        let moved = try applyNativeKeyframeCommand(track, .move(keyframeId: "key:b", toFrame: 50), engine: engine)
        let out = try NativeJSONValue.from(moved.track)
        XCTAssertTrue(moved.ok)
        XCTAssertNil(out["zz4"]); XCTAssertNil(out["keyframes"]?[0]?["zz5"]); XCTAssertNil(out["keyframes"]?[1]?["zz5"])
        XCTAssertEqual(Array(out.objectValue!.keys), ["schemaVersion", "id", "parameterId", "valueType", "frameRate", "keyframes"])
        XCTAssertEqual(Array(out["keyframes"]![0]!.objectValue!.keys), ["id", "frame", "value", "outgoing"])
        XCTAssertEqual(out["frameRate"]?["zz5"]?["deep"], .bool(true))
        XCTAssertEqual(out["keyframes"]?[1]?["outgoing"]?["zz6"]?["deep"], .bool(true))
        XCTAssertEqual(out["keyframes"]?[1]?["frame"], .number(50))

        // setOutgoing assigns cloneInterpolation(command.outgoing): that keyframe's outgoing extras go, others stay.
        let set = try applyNativeKeyframeCommand(track, .setOutgoing(keyframeId: "key:a", outgoing: .hold), engine: engine)
        let o2 = try NativeJSONValue.from(set.track)
        XCTAssertEqual(o2["keyframes"]?[0]?["outgoing"], .object(["type": .string("hold")]))
        XCTAssertEqual(o2["keyframes"]?[1]?["outgoing"]?["zz6"]?["deep"], .bool(true))
        // The inverse is cloneTrack(original): outgoing objects are cloned too.
        if case .success(_, .restoreTrack(let inverse)) = moved {
            XCTAssertNil(try NativeJSONValue.from(inverse)["keyframes"]?[0]?["outgoing"]?["zz6"])
            XCTAssertEqual(try NativeJSONValue.from(inverse)["frameRate"]?["zz5"]?["deep"], .bool(true))
        } else { XCTFail("expected restoreTrack inverse") }
    }
}
