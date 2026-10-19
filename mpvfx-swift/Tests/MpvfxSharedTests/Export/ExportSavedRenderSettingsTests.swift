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

// Gap 1 downstream check. The saved render settings reader is
// transcribed here TEST-ONLY so the shared export API can be driven along the path a
// saved render setting that names an Object.prototype key takes. Expected values: the recorded reference values
// (exportParity.json `savedSettings`). End results:
//  - the reader keeps the name (isExportResolutionChoice is true);
//  - quick render → persistedRenderDimensions returns `{}`,
//    forwarded because it is truthy → the render queue blocks with
//    "Export dimensions must be even whole pixels within the 8K limit." (failed "Export blocked" job);
//  - render panel → target `{}` is truthy so no issue is shown, and the Export click
//    returns without rendering.

private struct PersistedRenderSettings { var format: String; var quality: String; var fps: Double; var resolution: String; var customDimensions: ExportDimensions? }

/// Saved settings parsing (parsed JSON in, settings out).
private func getPersistedRenderSettings(_ raw: String) -> PersistedRenderSettings {
    guard let parsed = try? NativeJSONValue.parse(raw) else { return .init(format: "mp4", quality: "standard", fps: 30, resolution: "auto", customDimensions: nil) }
    let migrated = parsed["resolution"]
    var s = PersistedRenderSettings(
        format: isExportFormat(parsed["format"]) ? parsed["format"]!.stringValue! : "mp4",
        quality: isExportQuality(parsed["quality"]) ? parsed["quality"]!.stringValue! : "standard",
        fps: isExportFrameRate(parsed["fps"]) ? parsed["fps"]!.numberValue! : 30,
        resolution: isExportResolutionChoice(migrated) ? migrated!.stringValue! : "auto", customDimensions: nil)
    if migrated == .string("custom"), isValidExportOutputDimensions(parsed["customDimensions"]),
       case .object(let o)? = parsed["customDimensions"] { s.customDimensions = ExportDimensions(json: o) }
    return s
}
/// Saved settings defaults.
private func resolvePersistedRenderResolution(_ r: ExportResolutionChoice, _ authored: ExportDimensions?) -> ExportResolutionChoice {
    guard r == .scale(.p1080) || r == .scale(.k4), isValidExportDimensions(authored) else { return r }
    let a = compositionAspect(authored)
    if r == .scale(.p1080) { return .preset(a == .portrait ? .verticalFullHd : a == .square ? .squareFullHd : .fullHd) }
    return .preset(a == .portrait ? .vertical4k : a == .square ? .square4k : .uhd4k)
}
/// Saved settings dimensions.
private func persistedRenderDimensions(_ s: PersistedRenderSettings, _ authored: ExportDimensions?) -> ExportDimensions? {
    let r = resolvePersistedRenderResolution(ExportResolutionChoice(rawValue: s.resolution)!, authored)
    if r == .scale(.p1080) || r == .scale(.k4) { return nil }
    return resolveExportTargetDimensions(r, authored, s.customDimensions)
}

final class ExportSavedRenderSettingsTests: XCTestCase {
    func testSavedPrototypeKeyResolutionReachesTheSameEndResultAsTs() {
        let rows = ExportFixture.list(ExportFixture.cases["savedSettings"]); XCTAssertEqual(rows.count, 57)
        var prototypeRows = 0
        for row in rows {
            let raw = row["raw"]!.stringValue!, authored = fxDims(row["authored"])
            let s = getPersistedRenderSettings(raw)
            let want = row["settings"]!
            XCTAssertEqual(s.resolution, want["resolution"]?.stringValue, raw)
            XCTAssertEqual(s.format, want["format"]?.stringValue); XCTAssertEqual(s.fps, want["fps"]?.numberValue)
            XCTAssertEqual(jsJSONStringify(fxDimsJSON(s.customDimensions)), jsJSONStringify(want["customDimensions"] ?? .null), raw)

            let dims = persistedRenderDimensions(s, authored)
            let wantDims = row["dims"] == .string("__undefined__") ? NativeJSONValue.null : row["dims"]!
            XCTAssertEqual(jsJSONStringify(fxDimsJSON(dims)), jsJSONStringify(wantDims), raw)
            XCTAssertEqual(dims != nil, row["dimsForwarded"]?.boolValue, raw)
            XCTAssertEqual(isValidExportOutputDimensions(dims), row["dimsValidOutput"]?.boolValue, raw)

            let selected = resolvePersistedRenderResolution(ExportResolutionChoice(rawValue: s.resolution)!, authored)
            XCTAssertEqual(selected.rawValue, row["selected"]?.stringValue, raw)
            let target = resolveExportTargetDimensions(selected, authored, .init(width: 2048, height: 1080))
            XCTAssertEqual(jsJSONStringify(fxDimsJSON(target)), jsJSONStringify(row["target"] ?? .null), raw)
            XCTAssertEqual(target == nil, row["panelShowsIssue"]?.boolValue, raw)
            XCTAssertEqual(target != nil && isValidExportOutputDimensions(target), row["exportClickProceeds"]?.boolValue, raw)

            // Telemetry/job label template via exportDimensionsLabel.
            XCTAssertEqual(target.map(exportDimensionsLabel), row["targetLabel"]?.stringValue, raw)
            XCTAssertEqual(dims.map(exportDimensionsLabel), row["dimsLabel"]?.stringValue, raw)
            if JS_OBJECT_PROTOTYPE_KEYS.contains(s.resolution) {
                XCTAssertEqual(exportDimensionsLabel(target!), "undefinedxundefined")
                prototypeRows += 1
                // Forwarded-but-invalid dims (quick render is blocked),
                // no panel issue, Export click is a no-op. No crash.
                XCTAssertNotNil(dims); XCTAssertFalse(isValidExportOutputDimensions(dims))
                XCTAssertNotNil(target); XCTAssertFalse(isValidExportOutputDimensions(target))
            }
        }
        XCTAssertEqual(prototypeRows, 36)
    }
}
