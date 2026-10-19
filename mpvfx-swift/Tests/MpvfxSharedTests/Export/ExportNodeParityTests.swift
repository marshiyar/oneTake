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

// Golden-value tests. Every expected value comes from the recorded reference values in Fixtures/exportParity.json.
private func s(_ v: String?) -> NativeJSONValue { v.map(NativeJSONValue.string) ?? .null }
private func n(_ v: Double?) -> NativeJSONValue { v.map(NativeJSONValue.number) ?? .null }
private func obj(_ pairs: [(String, NativeJSONValue)]) -> NativeJSONValue { .object(NativeJSONObject(pairs)) }

/// Swift constants rendered with the recorded object shape and key order, for a JSON.stringify comparison.
/// EXPORT_FORMAT_CAPABILITIES is left out: the recorded table described encoders the app does not use
/// (ExportCapabilityTests asserts the engine's table; testCapabilityFieldsThatStillHoldMatchRecorded the shared fields).
private func swiftConstantsJSON() -> NativeJSONValue {
    obj([
        ("SUPPORTED_EXPORT_FORMATS", .array(SUPPORTED_EXPORT_FORMATS.map { s($0.rawValue) })),
        ("SUPPORTED_EXPORT_QUALITIES", .array(SUPPORTED_EXPORT_QUALITIES.map { s($0.rawValue) })),
        ("SUPPORTED_EXPORT_FRAME_RATES", .array(SUPPORTED_EXPORT_FRAME_RATES.map(NativeJSONValue.number))),
        ("SUPPORTED_EXPORT_SCALES", .array(SUPPORTED_EXPORT_SCALES.map { s($0.rawValue) })),
        ("MAX_EXPORT_LONG_EDGE", n(MAX_EXPORT_LONG_EDGE)), ("MAX_EXPORT_SHORT_EDGE", n(MAX_EXPORT_SHORT_EDGE)),
        ("EXPORT_RESOLUTION_PRESETS", obj(EXPORT_RESOLUTION_PRESETS.map { k, i in
            (k.rawValue, obj([("label", s(i.label)), ("width", n(i.width)), ("height", n(i.height)), ("ratio", s(i.ratio)), ("group", s(i.group))])) })),
        ("UNSUPPORTED_STANDALONE_EXPORT_FORMATS", obj(UNSUPPORTED_STANDALONE_EXPORT_FORMATS.map { ($0.0, s($0.1)) })),
        ("CANVAS_DIMENSIONS", obj(CanvasResolution.allCases.map { ($0.rawValue, fxDimsJSON($0.dimensions)) })),
    ])
}

private func tsConstantsWithoutEncoderTable() -> NativeJSONValue {
    guard case .object(var o)? = ExportFixture.root["constants"] else { return .null }
    o.removeValue(forKey: "EXPORT_FORMAT_CAPABILITIES")
    return .object(o)
}

/// The recorded label in a validation message, as the app names the format now ("MOV (ProRes 4444)" became "MOV":
/// the rule that raised the message is unchanged, only the encoder it named is gone).
private func currentFormatName(_ recorded: String) -> String {
    recorded.replacingOccurrences(of: "MOV (ProRes 4444)", with: exportFormatCapability(.mov).name)
}

final class ExportNodeParityTests: XCTestCase {
    let c = ExportFixture.cases

    func testConstantsMatchRecordedIncludingKeyOrder() {
        XCTAssertEqual(jsJSONStringify(swiftConstantsJSON()), jsJSONStringify(tsConstantsWithoutEncoderTable()))
    }

    /// Extension, MIME type and resolution scaling are the same as the recorded table; the codec fields are not.
    func testCapabilityFieldsThatStillHoldMatchRecorded() {
        let recorded = ExportFixture.root["constants"]?["EXPORT_FORMAT_CAPABILITIES"]
        let formats = ExportFormat.allCases
        XCTAssertEqual(formats.map { exportFormatCapability($0).extension }, formats.map { recorded?[$0.rawValue]?["extension"]?.stringValue })
        XCTAssertEqual(formats.map { exportFormatCapability($0).mimeType }, formats.map { recorded?[$0.rawValue]?["mimeType"]?.stringValue })
        XCTAssertEqual(formats.map { exportFormatCapability($0).supportsResolutionScaling },
                       formats.map { recorded?[$0.rawValue]?["supportsResolutionScaling"]?.boolValue })
    }

    func testDimensionGuardsAndAspect() {
        let cases = ExportFixture.list(c["isValidDims"]); XCTAssertEqual(cases.count, 615)
        for k in cases {
            let v = fxDimsValue(k["d"])
            XCTAssertEqual(isValidExportDimensions(v), k["valid"]?.boolValue, "\(String(describing: v))")
            XCTAssertEqual(isValidExportOutputDimensions(v), k["output"]?.boolValue, "\(String(describing: v))")
            XCTAssertEqual(compositionAspect(fxDims(k["d"])).rawValue, k["aspect"]?.stringValue)
        }
    }

    func testUntypedInputsForDimensionGuards() {
        // Same values as the fixture's `oddVals` (nil = undefined).
        let values: [String: NativeJSONValue?] = [
            "null": .null, "undefined": nil, "string": .string("1920x1080"), "number": .number(1920),
            "array": .array([.number(1920), .number(1080)]), "empty": obj([]), "onlyWidth": obj([("width", .number(1920))]),
            "strings": obj([("width", .string("1920")), ("height", .string("1080"))]), "bool": .bool(true),
            "extraKeys": obj([("width", .number(1920)), ("height", .number(1080)), ("depth", .number(3))])]
        for k in ExportFixture.list(c["odd"]) {
            let v = values[k["name"]!.stringValue!]!
            XCTAssertEqual(isValidExportDimensions(v), k["valid"]?.boolValue, k["name"]!.stringValue!)
            XCTAssertEqual(isValidExportOutputDimensions(v), k["output"]?.boolValue, k["name"]!.stringValue!)
        }
    }

    func testAspectRatioLabels() {
        for k in ExportFixture.list(c["aspectLabel"]) {
            XCTAssertEqual(exportAspectRatioLabel(fxDims(k["d"])!), k["label"]?.stringValue)
        }
    }

    func testPerFormatResolution() {
        let cases = ExportFixture.list(c["perFormat"]); XCTAssertEqual(cases.count, 189)
        for k in cases {
            let f = ExportFormat(rawValue: k["f"]!.stringValue!)!, sc = ExportScale(rawValue: k["s"]!.stringValue!)!
            let d = fxDims(k["d"]), msg = "\(f) \(sc) \(String(describing: d))"
            XCTAssertEqual(normalizeExportScaleForFormat(f, sc).rawValue, k["normalized"]?.stringValue, msg)
            XCTAssertEqual(resolveExportResolution(f, sc, d).rawValue, k["resolution"]?.stringValue, msg)
            XCTAssertEqual(exportScaleApplies(f, sc, d), k["applies"]?.boolValue, msg)
            XCTAssertEqual(fxDimsJSON(resolveExportDimensions(f, sc, d)), k["dims"] ?? .null, msg)
            XCTAssertEqual(fxDimsJSON(resolveEncodedDimensions(f, d)), k["encoded"] ?? .null, msg)
        }
    }

    func testTargetDimensions() {
        var prototypeKeyCases = 0
        for k in ExportFixture.list(c["target"]) {
            let raw = k["c"]!.stringValue!
            XCTAssertEqual(isExportResolutionChoice(.string(raw)), k["isChoice"]?.boolValue, raw)
            guard let choice = ExportResolutionChoice(rawValue: raw) else { XCTAssertEqual(k["result"], .null, raw); continue }
            if case .objectPrototypeKey = choice { prototypeKeyCases += 1 }
            let got = resolveExportTargetDimensions(choice, fxDims(k["a"]), fxDims(k["cu"]))
            XCTAssertEqual(jsJSONStringify(fxDimsJSON(got)), jsJSONStringify(k["result"] ?? .null),
                           "\(raw) \(String(describing: k["a"])) \(String(describing: k["cu"]))")
        }
        XCTAssertEqual(prototypeKeyCases, 100)   // gap 1: constructor/toString/__proto__/hasOwnProperty match the recorded values
    }

    func testObjectPrototypeKeyListMatchesV8() {
        XCTAssertEqual(JS_OBJECT_PROTOTYPE_KEYS, ExportFixture.list(c["objectPrototypeKeys"]).map { $0.stringValue! })
    }

    func testTypeGuards() {
        for k in ExportFixture.list(c["guards"]) {
            var v: NativeJSONValue? = k["v"]
            if v == .string("__undefined__") { v = nil }
            if case .string(let str)? = v, ["NaN", "-0"].contains(str) { v = .number(fxNum(v)) }
            let msg = String(describing: v)
            XCTAssertEqual(isExportFormat(v), k["format"]?.boolValue, msg)
            XCTAssertEqual(isExportQuality(v), k["quality"]?.boolValue, msg)
            XCTAssertEqual(isExportFrameRate(v), k["fps"]?.boolValue, msg)
            XCTAssertEqual(isExportScale(v), k["scale"]?.boolValue, msg)
            XCTAssertEqual(isExportResolutionChoice(v), k["choice"]?.boolValue, msg)
        }
    }

    /// Frame counts and the file-size label follow the recorded values bit for bit. (The recorded CRF and audio
    /// size cases are not checked here; ExportCapabilityTests covers the engine's audio estimate.)
    func testFramesAndFileSize() {
        let frames = ExportFixture.list(c["frames"]), sizes = ExportFixture.list(c["fileSize"])
        XCTAssertGreaterThan(frames.count, 0); XCTAssertGreaterThan(sizes.count, 0)
        let gotFrames = frames.map { exportFrameCount(fxNum($0["d"]), ExportFrameRate(rawValue: fxNum($0["fps"]))!) }
        XCTAssertEqual(zip(gotFrames, frames).filter { !bitsEqual($0.0, fxNum($0.1["r"])) }.map(\.1), [])
        XCTAssertEqual(sizes.map { formatExportFileSize(fxNum($0["b"])) }, sizes.map { $0["r"]?.stringValue })
    }

    func testValidateExportSettings() {
        let cases = ExportFixture.list(c["validate"]); XCTAssertEqual(cases.count, 384)
        for k in cases {
            let i = k["input"]!
            let r = validateExportSettings(.init(format: i["format"], quality: i["quality"], fps: i["fps"],
                                                 scale: i["scale"], dimensions: fxDimsValue(i["dimensions"])))
            XCTAssertEqual(r.ok, k["result"]?["ok"]?.boolValue, "\(i)")
            XCTAssertEqual(r.issues, ExportFixture.list(k["result"]?["issues"]).map { currentFormatName($0.stringValue!) }, "\(i)")
        }
    }

    /// Gap 2 fix: copied records keep unknown keys in own-key order; rebuilds drop them. Order asserted via keys and
    /// via JSON.stringify text (NativeJSONValue equality alone ignores order).
    func testUnknownKeysFollowTsSpreadsInOrder() {
        let rows = ExportFixture.list(c["extraKeys"]); XCTAssertEqual(rows.count, 8)
        func check(_ got: ExportDimensions?, _ want: NativeJSONValue?, _ msg: String) {
            let r = want?["r"] ?? .null
            XCTAssertEqual(jsJSONStringify(fxDimsJSON(got)), jsJSONStringify(r), msg)
            XCTAssertEqual(got?.json.keys, ExportFixture.list(want?["keys"]).map { $0.stringValue! }.nilIfEmpty(r), msg)
        }
        var kept = 0
        for row in rows {
            let d = fxDims(row["d"])!
            let msg = jsJSONStringify(row["d"]!)
            XCTAssertEqual(d.json.keys, ExportFixture.list(row["inputKeys"]).map { $0.stringValue! }, "input order " + msg)
            XCTAssertEqual(isValidExportDimensions(row["d"]), row["valid"]?.boolValue, msg)
            XCTAssertEqual(isValidExportOutputDimensions(row["d"]), row["output"]?.boolValue, msg)
            for p in ExportFixture.list(row["perFormat"]) {
                let f = ExportFormat(rawValue: p["f"]!.stringValue!)!, sc = ExportScale(rawValue: p["s"]!.stringValue!)!
                let got = resolveExportDimensions(f, sc, d)
                check(got, p, "resolveExportDimensions \(f) \(sc) " + msg)
                if (got?.json.count ?? 0) > 2 { kept += 1 }
            }
            for f in ExportFormat.allCases { check(resolveEncodedDimensions(f, d), row["encoded"]?[f.rawValue], "encoded \(f) " + msg) }
            for raw in ["auto", "1080p", "4k", "uhd-8k"] {
                check(resolveExportTargetDimensions(ExportResolutionChoice(rawValue: raw)!, d, nil), row["target"]?[raw], "target \(raw) " + msg)
            }
            check(resolveExportTargetDimensions(.custom, .init(width: 1920, height: 1080), d), row["target"]?["custom"], "custom " + msg)
        }
        XCTAssertGreaterThan(kept, 10)   // the fixture really exercises spreads that keep extra keys
    }
}

private extension Array where Element == String {
    /// Fixture `keys` is null when the result is null.
    func nilIfEmpty(_ r: NativeJSONValue) -> [String]? { r == .null ? nil : self }
}
