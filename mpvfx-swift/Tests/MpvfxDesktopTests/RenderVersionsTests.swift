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
import MpvfxShared
import MpvfxRuntime
import MpvfxPanels
@testable import MpvfxDesktop

/// Export versions (#334): one render per checked preset, one after another, each named "<project> – <preset>".
final class RenderVersionsTests: XCTestCase {
    /// A 1920×1080 project with a video that fills the frame and a placed image.
    static let json = #"""
    {"schemaVersion":1,"id":"project:versions","revision":1,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":1920,"height":1080,"background":"#000000"},
     "assets":[{"id":"v","kind":"video","name":"clip.mp4","source":"clip.mp4","durationFrames":300,"width":1920,"height":1080},
               {"id":"img","kind":"image","name":"logo.png","source":"logo.png","durationFrames":300,"width":400,"height":200}],
     "sequence":{"id":"seq","name":"Sequence","tracks":[{"id":"v1","kind":"video","clips":[
      {"id":"main","assetId":"v","startFrame":0,"durationFrames":90,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]},
      {"id":"logo","assetId":"img","startFrame":0,"durationFrames":90,"sourceInFrame":0,"muted":false,
       "staticParameters":{"layout.left":100,"layout.top":50,"layout.width":400,"layout.height":200},"effects":[],"parameterTracks":[]}]}]}}
    """#

    func document() throws -> NativeProjectDocument { try parseNativeProjectDocument(try NativeJSONValue.parse(Self.json)) }
    let natural: (NativeProjectAsset) -> NativeMediaNaturalSize? = { $0.naturalSize }

    func preset(_ name: String, format: String = "mp4", composition: RenderPresetComposition? = nil) -> RenderPreset {
        var settings = RenderSettingsModel()
        settings.format = format
        return RenderPreset(name: name, settings: settings, composition: composition)
    }

    func version(_ preset: RenderPreset, project: String = "Film") throws -> RenderVersion {
        try RenderVersion.make(preset, project: project, document: try document(), natural: natural, engine: nil)
    }

    func batch(_ names: [String]) throws -> RenderBatch {
        var n = 0
        return RenderBatch(projectId: "p", versions: try names.map { try version(preset($0)) }, newJobId: { n += 1; return "job-\(n)" })
    }

    /// A1: three presets make three versions, in list order, each named after the project and its preset.
    func testA1ThreePresetsMakeThreeNamedVersionsInOrder() throws {
        let b = try batch(["Master", "Review", "Square"])
        XCTAssertEqual(b.items.map(\.version.fileStem), ["Film – Master", "Film – Review", "Film – Square"])
        XCTAssertEqual(b.items.map(\.jobId), ["job-1", "job-2", "job-3"])
        XCTAssertEqual(b.items.map(\.state), [.queued, .queued, .queued])
    }

    /// Only one version renders at a time, and the next starts when the one before it has ended.
    func testVersionsRunOneAfterAnother() throws {
        var b = try batch(["A", "B", "C"])
        XCTAssertEqual(b.nextToStart?.jobId, "job-1")
        b.set("job-1", .rendering)
        XCTAssertNil(b.nextToStart, "nothing starts while one renders")
        b.set("job-1", .complete)
        XCTAssertEqual(b.nextToStart?.jobId, "job-2")
        b.set("job-2", .rendering); b.set("job-2", .complete)
        b.set("job-3", .rendering)
        XCTAssertFalse(b.isFinished)
        b.set("job-3", .failed)
        XCTAssertNil(b.nextToStart)
        XCTAssertTrue(b.isFinished)
    }

    /// A2: cancelling the second leaves the first finished and the third queued (it still runs afterwards).
    func testA2CancellingTheSecondLeavesTheFirstFinishedAndTheThirdQueued() throws {
        var b = try batch(["A", "B", "C"])
        b.set("job-1", .rendering); b.set("job-1", .complete)
        b.set("job-2", .rendering)
        XCTAssertFalse(b.cancelQueued("job-2"), "a version that renders is stopped by its run, not here")
        b.set("job-2", .cancelled)
        XCTAssertEqual(b.items.map(\.state), [.complete, .cancelled, .queued])
        XCTAssertEqual(b.nextToStart?.jobId, "job-3", "the third version still runs")
    }

    func testAWaitingVersionCanBeCancelledAndNeverStarts() throws {
        var b = try batch(["A", "B", "C"])
        b.set("job-1", .rendering)
        XCTAssertTrue(b.cancelQueued("job-2"))
        XCTAssertFalse(b.cancelQueued("job-2"), "already cancelled")
        b.set("job-1", .complete)
        XCTAssertEqual(b.nextToStart?.jobId, "job-3", "the cancelled version is skipped")
        b.set("job-2", .rendering)   // a late callback
        XCTAssertEqual(b.state("job-2"), .cancelled, "a version that ended stays as it ended")
    }

    /// A3: a preset with its own composition size renders at that size, and the open project is not changed.
    func testA3ACompositionSizeRendersAtThatSizeWithoutChangingTheDocument() throws {
        let document = try document()
        let before = try serializeNativeProjectDocument(document)
        let portrait = preset("Tall", composition: RenderPresetComposition(width: 1080, height: 1920))
        let v = try RenderVersion.make(portrait, project: "Film", document: document, natural: natural, engine: nil)
        XCTAssertEqual(v.document.canvas.width, 1080); XCTAssertEqual(v.document.canvas.height, 1920)
        let plan = planExport(v.document, settings: v.settings)
        XCTAssertEqual(plan.outputDimensions?.width, 1080); XCTAssertEqual(plan.outputDimensions?.height, 1920)
        XCTAssertEqual(try serializeNativeProjectDocument(document), before, "the project keeps its size and its clips")
        XCTAssertEqual(document.canvas.width, 1920); XCTAssertEqual(document.canvas.height, 1080)
        // The placed logo keeps its size and its distance from the frame's centre, like a composition size change.
        let logo = try XCTUnwrap(v.document.sequence.tracks[0].clips.first { $0.id == "logo" })
        XCTAssertEqual(logo.staticParameters?["layout.width"], .number(400))
        XCTAssertEqual(logo.staticParameters?["layout.left"], .number(100 - 420))
        // The same project at its own size, for the version without a size of its own.
        let plain = try RenderVersion.make(preset("Master"), project: "Film", document: document, natural: natural, engine: nil)
        XCTAssertEqual(plain.document, document)
        XCTAssertEqual(planExport(plain.document, settings: plain.settings).outputDimensions?.width, 1920)
    }

    /// A scaled resolution follows the version's own composition, not the project's.
    func testAScaledResolutionFollowsTheVersionsComposition() throws {
        var p = preset("Tall HD", composition: RenderPresetComposition(width: 1080, height: 1920))
        p.settings.resolution = "720p"
        let v = try version(p)
        let dims = planExport(v.document, settings: v.settings).outputDimensions
        XCTAssertEqual(dims?.width, 720); XCTAssertEqual(dims?.height, 1280)
    }

    func testAnUnusablePresetIsRefusedWithItsReason() throws {
        XCTAssertThrowsError(try version(preset("Old", format: "webm"))) {
            XCTAssertTrue(($0 as? RenderVersionError)?.message.contains("webm is not supported") == true, "\($0)")
        }
        XCTAssertThrowsError(try version(preset("Huge", composition: RenderPresetComposition(width: 99999, height: 10)))) {
            XCTAssertTrue(($0 as? RenderVersionError)?.message.contains("Huge") == true, "\($0)")
        }
    }

    func testFileStemJoinsProjectAndPreset() {
        XCTAssertEqual(RenderVersion.fileStem(project: "My film", preset: "Wide"), "My film – Wide")
        XCTAssertEqual(RenderVersion.fileStem(project: "My film", preset: "9:16 / tall"), "My film – 9-16 - tall", "as the file is named")
    }

    /// The preset file keeps a composition size, and a file written before sizes existed still reads.
    func testPresetCompositionRoundTripsAndOldFilesStillDecode() throws {
        let p = preset("Tall", composition: RenderPresetComposition(width: 1080, height: 1920))
        let back = try JSONDecoder().decode([RenderPreset].self, from: JSONEncoder().encode([p]))
        XCTAssertEqual(back, [p])
        let old = try JSONEncoder().encode([preset("Plain")])
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("composition"), "no key when there is no size")
        XCTAssertNil(try JSONDecoder().decode([RenderPreset].self, from: old).first?.composition)
        XCTAssertFalse(preset("Bad", composition: RenderPresetComposition(width: 0, height: 100)).hasValidSettings)
        XCTAssertFalse(preset("Bad", composition: RenderPresetComposition(width: 100.5, height: 100)).hasValidSettings)
    }
}
