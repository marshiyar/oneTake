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
// Property edit plans.
// parseNativeProjectDocument is not ported yet; the fixture is built with the fields it materializes.
import XCTest
@testable import MpvfxShared

final class NativePropertyEditPlanTests: XCTestCase {
    let frameRate = RationalFrameRate(numerator: 30_000, denominator: 1_001)
    let bounds = NativeSelectionBounds(width: 640, height: 360)
    let engine = KeyframeEngineStandIn()

    func fixture() -> NativeProjectDocument {
        func clip(_ id: String, _ file: String, _ hf: String, _ start: Double, _ srcIn: Double) -> NativeProjectClip {
            NativeProjectClip(id: id, assetId: "asset:video",
                binding: .init(sourceFile: file, domId: "legacy-first", hfId: hf, selector: ".timeline-clip", selectorIndex: 0),
                startFrame: start, durationFrames: 90, sourceInFrame: srcIn, playbackRate: DEFAULT_NATIVE_PLAYBACK_RATE, muted: false,
                staticParameters: [:], effects: [], parameterTracks: [])
        }
        return NativeProjectDocument(schemaVersion: NATIVE_PROJECT_DOCUMENT_SCHEMA_VERSION, id: "project:planner", revision: 0, frameRate: frameRate,
            canvas: .init(width: 1920, height: 1080, background: "#111111"),
            assets: [.init(id: "asset:video", kind: .video, name: "video.mov", durationFrames: 300)],
            sequence: .init(id: "sequence:main", name: "Main", tracks: [.init(id: "track:v1", kind: .video, lane: .init(authoredTrack: 0, displayTrack: 0),
                clips: [clip("clip:first", "index.html", "hf-first", 30, 0), clip("clip:second", "nested.html", "hf-second", 120, 90)])]))
    }
    func secondsAtFrame(_ f: Double) -> Double { f * frameRate.denominator / frameRate.numerator }
    func nums(_ p: [(String, Double)]) -> [(String, NativePropertyInputValue)] { p.map { ($0.0, .number($0.1)) } }
    func plan(in doc: NativeProjectDocument? = nil, _ sel: NativeSelectedElementReference, frame: Double = 45, _ props: [(String, Double)],
              bounds b: NativeSelectionBounds?? = nil, intent: NativePropertyEditIntent? = nil, auto: Bool? = nil,
              baselines: [String: Double]? = nil) -> NativePropertyEditPlanResult {
        planNativePropertyEdit(doc ?? fixture(), .init(selectedElement: sel, playheadSeconds: secondsAtFrame(frame), properties: nums(props),
            selectionBounds: b == nil ? bounds : b!, propertyBaselines: baselines, intent: intent, autoKeyframeEnabled: auto))
    }
    func ok(_ r: NativePropertyEditPlanResult, file: StaticString = #filePath, line: UInt = #line) -> NativePropertyEditPlan? {
        switch r { case .success(let p): return p; case .failure(let f): XCTFail("\(f)", file: file, line: line); return nil }
    }
    func code(_ r: NativePropertyEditPlanResult) -> NativePropertyEditPlanFailureCode? { if case .failure(let f) = r { return f.code }; return nil }
    struct Up: Equatable { var parameterId: String; var value: Double; var baseline: Double; var frame: Double }
    func upserts(_ p: NativePropertyEditPlan) -> [Up?] {
        p.commands.map { if case .keyframe(.upsert(let a, _, let f, .number(let v), .number(let b), _)) = $0 { return Up(parameterId: a.parameterId, value: v, baseline: b, frame: f) }; return nil }
    }
    func rotationTrack(_ keys: [(String, Double, Double, NativeInterpolation)]) -> NativeParameterTrack {
        try! createNativeParameterTrack(.init(id: "parameter:rotation", parameterId: "transform.rotation", valueType: .number, frameRate: frameRate,
            keyframes: keys.map { NativeKeyframe(id: $0.0, frame: $0.1, value: .number($0.2), outgoing: $0.3) }), engine: engine)
    }

    func testQuantizesSecondsWithFloorRule() throws {
        XCTAssertEqual(try projectFrameFromSeconds(secondsAtFrame(45), frameRate: frameRate), 45)
        XCTAssertEqual(try projectFrameFromSeconds(secondsAtFrame(45) + secondsAtFrame(0.49), frameRate: frameRate), 45)
        XCTAssertEqual(try projectFrameFromSeconds(secondsAtFrame(45) + secondsAtFrame(0.99), frameRate: frameRate), 45)
        XCTAssertEqual(try projectFrameFromSeconds(secondsAtFrame(46), frameRate: frameRate), 46)
    }
    func testRejectsNegativePlayhead() {
        let r = planNativePropertyEdit(fixture(), .init(selectedElement: .init(id: "clip:first"), playheadSeconds: -0.001, properties: nums([("x", 20)]), selectionBounds: bounds))
        XCTAssertEqual(code(r), .invalidPlayhead)
    }
    func testExplicitClipIdBeatsConflictingDomId() throws {
        guard let p = ok(plan(.init(id: "clip:second", attributes: ["data-studio-clip-id": "clip:first"]), [("rotation", -180)])) else { return }
        XCTAssertEqual(p.clipId, "clip:first"); XCTAssertEqual(p.projectFrame, 45); XCTAssertEqual(p.clipLocalFrame, 15)
        let a = p.commands[0].address
        XCTAssertEqual([a.sequenceId, a.trackId, a.clipId], ["sequence:main", "track:v1", "clip:first"])
    }
    func testExactDomIdOnlyNoFuzzy() {
        XCTAssertNotNil(ok(plan(.init(id: "clip:first"), [("x", 20)])))
        XCTAssertEqual(code(plan(.init(id: "clip:first-child"), [("x", 20)])), .clipNotFound)
    }
    func testScopedLegacyBinding() {
        XCTAssertEqual(ok(plan(.init(id: "legacy-first", hfId: "hf-first", sourceFile: "index.html", selector: ".timeline-clip", selectorIndex: 0), [("rotation", -180)]))?.clipId, "clip:first")
    }
    func testSourceFileScopeForRepeatedDomIds() {
        XCTAssertEqual(ok(plan(.init(id: "legacy-first", sourceFile: "nested.html"), frame: 150, [("x", 12)]))?.clipId, "clip:second")
    }
    func testUniqueSourcelessCompatibilityBinding() {
        for sel in [NativeSelectedElementReference(id: "legacy-first"), .init(hfId: "hf-first"), .init(selector: ".unique-first", selectorIndex: 0)] {
            var d = fixture()
            d.sequence.tracks[0].clips[1].binding!.domId = "legacy-second"
            d.sequence.tracks[0].clips[1].binding!.selector = ".unique-second"
            d.sequence.tracks[0].clips[0].binding!.selector = ".unique-first"
            XCTAssertEqual(ok(plan(in: d, sel, [("rotation", -180)]))?.clipId, "clip:first", "\(sel)")
        }
    }
    func testRejectsSourcelessHintRepeatedAcrossFiles() {
        XCTAssertEqual(code(plan(.init(id: "legacy-first"), [("rotation", -180)])), .ambiguousClip)
    }
    func testRejectsConflictingSourcelessHints() {
        var d = fixture(); d.sequence.tracks[0].clips[1].binding!.domId = "legacy-second"
        XCTAssertEqual(code(plan(in: d, .init(id: "legacy-first", hfId: "hf-second"), [("rotation", -180)])), .ambiguousClip)
    }
    func testRejectsConflictingExactBindingFacts() {
        var d = fixture(); d.sequence.tracks[0].clips[1].binding = .init(sourceFile: "index.html", domId: "legacy-second", hfId: "hf-second")
        XCTAssertEqual(code(plan(in: d, .init(id: "legacy-first", hfId: "hf-second", sourceFile: "index.html"), frame: 150, [("x", 12)])), .ambiguousClip)
    }
    func testNoDomIdFallbackWhenExplicitAttributeWrong() {
        XCTAssertEqual(code(plan(.init(id: "clip:first", attributes: ["data-studio-clip-id": "clip:missing"]), [("x", 20)])), .clipNotFound)
    }
    func testRejectsStructurallyAmbiguousExactMatches() {
        var d = fixture(); d.sequence.tracks.append(.init(id: "track:v2", kind: .video, clips: [d.sequence.tracks[0].clips[0]]))
        XCTAssertEqual(code(plan(in: d, .init(attributes: ["data-studio-clip-id": "clip:first"]), [("x", 20)])), .ambiguousClip)
    }
    func testEditsNearestVisibleFrameOutsideClip() {
        for (frame, expected) in [(29.0, 0.0), (120, 89)] {
            XCTAssertEqual(ok(plan(.init(id: "clip:first"), frame: frame, [("x", 20)]))?.clipLocalFrame, expected)
        }
    }
    func testMapsEverySupportedPropertyWithBaselines() {
        guard let p = ok(plan(.init(id: "clip:first"), frame: 60, [("x", 10), ("y", -20), ("rotation", -180), ("scale", 1.5), ("scaleX", 2), ("scaleY", 0.5),
                                                               ("opacity", 0.75), ("width", 1280), ("height", 720)])) else { return }
        XCTAssertEqual(upserts(p), [
            Up(parameterId: "transform.position.x", value: 10, baseline: 0, frame: 30), Up(parameterId: "transform.position.y", value: -20, baseline: 0, frame: 30),
            Up(parameterId: "transform.rotation", value: -180, baseline: 0, frame: 30), Up(parameterId: "transform.scale", value: 1.5, baseline: 1, frame: 30),
            Up(parameterId: "transform.scaleX", value: 2, baseline: 1, frame: 30), Up(parameterId: "transform.scaleY", value: 0.5, baseline: 1, frame: 30),
            Up(parameterId: "visual.opacity", value: 0.75, baseline: 1, frame: 30), Up(parameterId: "layout.width", value: 1280, baseline: 640, frame: 30),
            Up(parameterId: "layout.height", value: 720, baseline: 360, frame: 30)])
    }
    func testAliasesRotationZAndAutoAlpha() {
        guard let p = ok(plan(.init(id: "clip:first"), [("rotationZ", -180), ("autoAlpha", 0.25)])) else { return }
        XCTAssertEqual(upserts(p).map { $0.map { [$0.parameterId, "\($0.value)", "\($0.baseline)"] } },
                       [["transform.rotation", "-180.0", "0.0"], ["visual.opacity", "0.25", "1.0"]])
    }
    func testPlans3DChannels() {
        guard let p = ok(plan(.init(id: "clip:first"), [("z", 120), ("rotationX", 12), ("rotationY", -18), ("transformPerspective", 900), ("scaleZ", 0.8)])) else { return }
        XCTAssertEqual(p.commands.map(\.address.parameterId), ["transform.position.z", "transform.rotationX", "transform.rotationY", "transform.scaleZ", "transform.perspective"])
    }
    func testNeverReturnsPartialPlanForInvalidProperties() {
        let cases: [([(String, NativePropertyInputValue)], NativePropertyEditPlanFailureCode)] = [
            ([("x", .number(10)), ("color", .other(.string("red")))], .unsupportedProperty),
            ([("x", .number(10)), ("rotation", .number(.nan))], .nonfiniteValue),
            ([("x", .number(10)), ("scale", .number(.infinity))], .nonfiniteValue)]
        for (props, c) in cases {
            XCTAssertEqual(code(planNativePropertyEdit(fixture(), .init(selectedElement: .init(id: "clip:first"), playheadSeconds: secondsAtFrame(45), properties: props, selectionBounds: bounds))), c)
        }
    }
    func testRequiresBoundsForWidthHeight() {
        XCTAssertEqual(code(plan(.init(id: "clip:first"), [("width", 1280)], bounds: .some(.none))), .missingSelectionBounds)
    }
    func testRejectsAliasesTargetingSameParameter() {
        XCTAssertEqual(code(plan(.init(id: "clip:first"), [("rotation", 45), ("rotationZ", -180)])), .duplicateParameter)
    }
    func testStaticEditWhenAutoKeyframeOff() {
        guard let p = ok(plan(.init(id: "clip:first"), [("rotation", -180)], intent: .edit, auto: false)) else { return }
        XCTAssertEqual(p.commands, [.setStatic(address: .init(sequenceId: "sequence:main", trackId: "track:v1", clipId: "clip:first", parameterId: "transform.rotation"), value: .number(-180))])
    }
    func testEditBetweenAuthoredKeysAddsPlayheadKey() {
        var d = fixture(); d.sequence.tracks[0].clips[0].parameterTracks = [rotationTrack([("key:0", 0, 0, .linear), ("key:60", 60, -180, .hold)])]
        guard let p = ok(plan(in: d, .init(id: "clip:first"), frame: 60, [("rotation", -120)], intent: .edit, auto: false)) else { return }
        XCTAssertEqual(p.commands.count, 1)
        XCTAssertEqual(upserts(p).first??.parameterId, "transform.rotation"); XCTAssertEqual(upserts(p).first??.frame, 30); XCTAssertEqual(upserts(p).first??.value, -120)
    }
    func testUpdatesExactKeyUnderPlayhead() {
        var d = fixture(); d.sequence.tracks[0].clips[0].parameterTracks = [rotationTrack([("key:0", 0, 0, .linear), ("key:30", 30, -90, .hold)])]
        guard let p = ok(plan(in: d, .init(id: "clip:first"), frame: 60, [("rotation", -180)], intent: .edit, auto: false)) else { return }
        guard case .keyframe(.updateValue(_, 30, .number(-180)))? = p.commands.first, p.commands.count == 1 else { return XCTFail("\(p.commands)") }
    }
    func testUpsertForExplicitAndAutoKeyframe() {
        for (intent, auto) in [(NativePropertyEditIntent.keyframe, false), (.edit, true)] {
            XCTAssertEqual(ok(plan(.init(id: "clip:first"), [("rotation", -180)], intent: intent, auto: auto))?.commands.first?.type, "upsert")
        }
    }
    func testPersistedStaticIsFirstKeyBaseline() {
        var d = fixture(); d.sequence.tracks[0].clips[0].staticParameters = ["transform.rotation": .number(-30)]
        XCTAssertEqual(ok(plan(in: d, .init(id: "clip:first"), frame: 60, [("rotation", -180)], intent: .keyframe, auto: false)).map(upserts)?.first??.baseline, -30)
    }
    func testMeasuredVisualStateIsFirstKeyBaseline() {
        guard let p = ok(plan(.init(id: "clip:first"), frame: 60, [("rotation", -180), ("opacity", 0.25)], intent: .keyframe, baselines: ["rotation": 25, "opacity": 0.8])) else { return }
        XCTAssertEqual(upserts(p).map { $0?.baseline }, [25, 0.8])
        XCTAssertEqual(upserts(p).map { $0?.parameterId }, ["transform.rotation", "visual.opacity"])
    }
    func testPersistedStaticBeatsMeasuredBaseline() {
        var d = fixture(); d.sequence.tracks[0].clips[0].staticParameters = ["transform.rotation": .number(12)]
        XCTAssertEqual(ok(plan(in: d, .init(id: "clip:first"), frame: 60, [("rotation", -180)], intent: .keyframe, baselines: ["rotation": 25])).map(upserts)?.first??.baseline, 12)
    }
}
