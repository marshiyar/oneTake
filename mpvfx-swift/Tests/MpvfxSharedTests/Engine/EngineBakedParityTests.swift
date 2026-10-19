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
// Golden-value tests for Engine/BakedKeyframeEngine.swift (bakeTrackSamples, createBakedEngine, frame budget,
// install slot). Expected values come from the recorded reference values in Fixtures/engineParity.json,
// recorded over the stub engine defined identically below and in
// the recording's generator (not part of this repo).
import XCTest
@testable import MpvfxShared

private let fixture: NativeJSONValue = {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/engineParity.json")
    return try! NativeJSONValue.parse(String(contentsOf: url, encoding: .utf8))
}()

private let invalidArgument = "sampleTrack(track, firstFrame, count) needs a finite frame and count"

/// Mirror of the generator's stub engine.
final class StubEngine: KeyframeEngine {
    let version = "stub-1"
    func validate(_ t: KeyframeTrack) throws {
        if t.keyframes.isEmpty { throw KeyframeEngineError(code: "empty-track", message: "Track has no keyframes") }
        for k in t.keyframes where !jsIsInteger(k.frame) || k.frame < 0 {
            throw KeyframeEngineError(code: "invalid-keyframe-frame", message: "Keyframe frame must be an integer project frame")
        }
    }
    func evaluate(_ t: KeyframeTrack, frame f: Double) throws -> NativeParameterValue {
        try validate(t)
        switch t.valueType {
        case .number: return .number(f * 2)
        case .vec2: return .vec2(Vec2Value(x: f, y: -f))
        case .rgba: return .rgba(RgbaValue(red: f, green: 0, blue: 1, alpha: 0.5))
        }
    }
    func sample(_ t: KeyframeTrack, firstFrame first: Double, count: Int) throws -> [Double] {
        try assertKeyframeFrameBudget(Double(count))
        try validate(t)
        if !first.isFinite || count < 0 { throw KeyframeEngineError(code: "invalid-argument", message: invalidArgument) }
        let n = keyframeComponentCount(t.valueType)
        var out = [Double](repeating: 0, count: count * n)
        for i in 0..<count { for c in 0..<n { out[i * n + c] = (first + Double(i)) * 10 + Double(c) + 0.25 } }
        return out
    }
    func tangentAngle(_ t: KeyframeTrack, frame f: Double) throws -> Double {
        try validate(t)
        return jsRemainder(f, 3) == 0 ? .nan : f / 8
    }
    func slice(_ t: KeyframeTrack, fromFrame a: Double, untilFrameExclusive b: Double) throws -> [KeyframeSlicedKey] {
        try validate(t)
        return [KeyframeSlicedKey(frame: 0, value: .number(a), outgoing: .hold, sourceFrame: a, generated: b > a)]
    }
}

// MARK: - fixture decoding

private func num(_ v: NativeJSONValue?) -> Double {
    switch v {
    case .number(let n)?: return n
    case .string("NaN")?, .string("undefined")?: return .nan
    case .string("Infinity")?: return .infinity
    case .string("-Infinity")?: return -.infinity
    case .string("-0")?: return -0.0
    default: XCTFail("not a number: \(String(describing: v))"); return .nan
    }
}
private func paramValue(_ v: NativeJSONValue) -> NativeParameterValue {
    if v["x"] != nil { return .vec2(Vec2Value(x: num(v["x"]), y: num(v["y"]))) }
    if v["red"] != nil { return .rgba(RgbaValue(red: num(v["red"]), green: num(v["green"]), blue: num(v["blue"]), alpha: num(v["alpha"]))) }
    return .number(num(v))
}
private func track(_ v: NativeJSONValue) -> KeyframeTrack {
    KeyframeTrack(valueType: NativeValueType(rawValue: v["valueType"]!.stringValue!)!, keyframes: v["keyframes"]!.arrayValue!.map {
        .init(frame: num($0["frame"]), value: paramValue($0["value"]!), outgoing: .linear) })
}
private func bakedTrack(_ v: NativeJSONValue) -> BakedKeyframeTrack {
    BakedKeyframeTrack(valueType: NativeValueType(rawValue: v["valueType"]!.stringValue!)!, samples: v["samples"]!.arrayValue!.map { num($0) },
                  angles: v["angles"]?.arrayValue?.map { if case .null = $0 { return nil }; return num($0) })
}
private func same(_ a: Double, _ b: Double) -> Bool { a.bitPattern == b.bitPattern || (a.isNaN && b.isNaN) }
private func sameValue(_ a: NativeParameterValue, _ b: NativeParameterValue) -> Bool {
    switch (a, b) {
    case (.number(let x), .number(let y)): return same(x, y)
    case (.vec2(let x), .vec2(let y)): return same(x.x, y.x) && same(x.y, y.y)
    case (.rgba(let x), .rgba(let y)): return same(x.red, y.red) && same(x.green, y.green) && same(x.blue, y.blue) && same(x.alpha, y.alpha)
    default: return false
    }
}

/// (name, code, message) the way the generator records a thrown error.
private func describe(_ error: Error) -> [String?] {
    switch error {
    case let e as KeyframeEngineError:
        if e.isLimitError { return ["VkfLimitError", e.code, e.message] }
        if e.trackErrorCode != nil { return ["VkfTrackError", e.code, e.message] }
        return ["Error", e.code, e.message]
    case let e as BakedKeyframeEngineError: return [e.kind.rawValue, nil, e.message]
    case let e as KeyframeEngineNotLoadedError: return ["Error", nil, e.description]
    default: return ["unexpected", nil, "\(error)"]
    }
}
private func expectedError(_ row: NativeJSONValue) -> [String?]? {
    guard let e = row["error"] else { return nil }
    return [e["name"]?.stringValue, e["code"]?.stringValue, e["message"]?.stringValue]
}

final class EngineBakedParityTests: XCTestCase {
    let stub = StubEngine()

    func testProvenanceAndConstants() {
        XCTAssertEqual(fixture["node"]?.stringValue, "v20.19.2")
        XCTAssertEqual(fixture["typescript"]?.stringValue, "5.9.3")
        XCTAssertEqual(fixture["constants"]?["apiVersion"]?.numberValue, Double(VKF_ENGINE_API_VERSION))
        XCTAssertEqual(fixture["constants"]?["maxFrames"]?.numberValue, VKF_MAX_MATERIALIZED_FRAMES)
    }

    func testBakeTrackSamplesMatchesTs() throws {
        let rows = fixture["bake"]!.arrayValue!
        XCTAssertEqual(rows.count, 100)
        for row in rows {
            let name = row["track"]!.stringValue!, fc = num(row["frameCount"])
            let t = track(fixture["tracks"]![name]!)
            let label = "\(name) frameCount \(fc)"
            do {
                let got = try bakeTrackSamples(stub, t, frameCount: fc)
                if let len = row["resultLength"]?.numberValue { XCTAssertEqual(Double(got.samples.count), len, label); continue }
                guard let r = row["result"] else { XCTFail("\(label): Swift returned, the recording threw \(String(describing: expectedError(row)))"); continue }
                XCTAssertEqual(got, bakedTrack(r), label)
                XCTAssertEqual(jsJSONStringify(got.jsonValue), jsJSONStringify(r), label)   // key order, null angles, omission
            } catch {
                XCTAssertEqual(describe(error), expectedError(row), label)
            }
        }
    }

    func testBakedEngineMatchesTsForEveryOperation() throws {
        let cases = fixture["bakedCases"]!.arrayValue!
        XCTAssertEqual(cases.count, 18)
        var ops = 0
        for c in cases {
            let name = c["track"]!.stringValue!
            let bakedJSON = fixture["baked"]![name]
            let t: KeyframeTrack
            switch name {
            case "unbaked": t = track(fixture["tracks"]!["num"]!)
            case "unbakedInvalid": t = track(fixture["tracks"]!["empty"]!)
            default: t = KeyframeTrack(valueType: NativeValueType(rawValue: bakedJSON!["valueType"]!.stringValue!)!, keyframes: [.init(frame: 0, value: .number(0), outgoing: .linear)])
            }
            let baked = bakedJSON.map(bakedTrack)
            let engine = BakedKeyframeEngine(version: "capture-1", lookup: { $0 == t ? baked : nil },
                                        fallback: c["fallback"] == .bool(true) ? stub : nil)
            for row in c["ops"]!.arrayValue! {
                ops += 1
                let op = row["op"]!.stringValue!
                let label = "\(name) fallback=\(c["fallback"]!) \(op) \(jsJSONStringify(row))"
                do {
                    switch op {
                    case "version": XCTAssertEqual(engine.version, row["result"]?.stringValue, label)
                    case "validate": try engine.validate(t); XCTAssertEqual(row["result"], .string("undefined"), label)
                    case "evaluate":
                        let got = try engine.evaluate(t, frame: num(row["frame"]))
                        guard let r = row["result"] else { XCTFail("\(label): Swift returned \(got)"); continue }
                        XCTAssertTrue(sameValue(got, paramValue(r)), "\(label): got \(got)")
                    case "tangentAngle":
                        let got = try engine.tangentAngle(t, frame: num(row["frame"]))
                        guard let r = row["result"] else { XCTFail("\(label): Swift returned \(got)"); continue }
                        XCTAssertTrue(same(got, num(r)), "\(label): got \(got)")
                    case "sample":
                        let got = try engine.sample(t, firstFrame: num(row["firstFrame"]), count: Int(num(row["count"])))
                        guard let r = row["result"]?.arrayValue else { XCTFail("\(label): Swift returned \(got)"); continue }
                        XCTAssertEqual(got.count, r.count, label)
                        XCTAssertTrue(zip(got, r).allSatisfy { same($0, num($1)) }, "\(label): got \(got)")
                    case "slice":
                        let got = try engine.slice(t, fromFrame: num(row["from"]), untilFrameExclusive: num(row["until"]))
                        guard let r = row["result"]?.arrayValue else { XCTFail("\(label): Swift returned \(got)"); continue }
                        XCTAssertEqual(got.map { [$0.frame, $0.sourceFrame] }, r.map { [num($0["frame"]), num($0["sourceFrame"])] }, label)
                        XCTAssertEqual(got.map(\.generated), r.map { $0["generated"] == .bool(true) }, label)
                    default: XCTFail("unknown op \(op)")
                    }
                } catch {
                    XCTAssertEqual(describe(error), expectedError(row), label)
                }
            }
        }
        XCTAssertEqual(ops, 612)
    }

    func testBakedTrackJSONRoundTrip() throws {
        for (name, v) in fixture["baked"]!.objectValue! {
            let parsed = try XCTUnwrap(BakedKeyframeTrack(json: v), name)
            XCTAssertEqual(jsJSONStringify(parsed.jsonValue), jsJSONStringify(v), name)
        }
        XCTAssertNil(BakedKeyframeTrack(json: try NativeJSONValue.parse(#"{"valueType":"vec3","samples":[]}"#)))
        XCTAssertNil(BakedKeyframeTrack(json: try NativeJSONValue.parse(#"{"valueType":"number","samples":["1"]}"#)))
    }

    func testEngineSlotWhenNothingIsInstalled() throws {
        let row = fixture["notInstalled"]!["result"]!.arrayValue!
        let previous = try? keyframeEngine()
        installKeyframeEngine(nil)
        defer { installKeyframeEngine(previous) }
        XCTAssertEqual(.bool(keyframeEngineInstalled()), row[0])
        XCTAssertThrowsError(try keyframeEngine()) { XCTAssertEqual(describe($0), expectedError(row[1])) }
        installKeyframeEngine(stub)
        XCTAssertTrue(keyframeEngineInstalled())
        XCTAssertTrue(try keyframeEngine() === stub)
    }
}
