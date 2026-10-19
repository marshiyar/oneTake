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
// Engine-dependent timeline plan cases (keyframe slicing via KeyframeRuntime).
import XCTest
@testable import MpvfxShared
import OneTakeKeyframes

private let splitJSON = #"""
{"schemaVersion":1,"id":"project:split","revision":3,"frameRate":{"numerator":30000,"denominator":1001},"canvas":{"width":1920,"height":1080,"background":"#000000"},
         "assets":[{"id":"asset:a","kind":"video","name":"a.mov","durationFrames":900},{"id":"asset:b","kind":"video","name":"b.mov","durationFrames":900}],
         "sequence":{"id":"sequence:main","name":"Main","tracks":[{"id":"track:video","kind":"video","lane":{"authoredTrack":2,"displayTrack":0},"clips":[
          {"id":"native:a","assetId":"asset:a","binding":{"sourceFile":"a.html","domId":"clip"},"startFrame":30,"durationFrames":120,"sourceInFrame":12,
           "playbackRate":{"numerator":2,"denominator":1},"muted":true,"staticParameters":{"opacity":0.65,"transform.rotation":15},
           "effects":[{"id":"fx:grade","effectId":"grade","enabled":true,"parameters":{"exposure":0.2}}],
           "parameterTracks":[{"schemaVersion":1,"id":"rotation:a","parameterId":"transform.rotation","valueType":"number","frameRate":{"numerator":30000,"denominator":1001},
            "keyframes":[{"id":"r0","frame":0,"value":0,"outgoing":{"type":"linear"}},{"id":"r1","frame":60,"value":180,"outgoing":{"type":"hold"}}]}]},
          {"id":"native:b","assetId":"asset:b","binding":{"sourceFile":"b.html","domId":"other"},"startFrame":180,"durationFrames":90,"sourceInFrame":4,"muted":false,"staticParameters":{},"effects":[],"parameterTracks":[]}]}]}}
"""#
private let firstSplit = NativeTimelineSplitRequest(element: .init(.init(id: "clip", sourceFile: "a.html")), requestedSplitSeconds: (60.0 * 1001) / 30000,
                                                    rightBinding: .init(sourceFile: "a.html", domId: "clip-split-2"))

final class EngineTimelineSplitPlanTests: XCTestCase {
    func testSplitsAtExactNtscFramePreservingState() throws {
        let e = try KeyframeRuntime(); let original = try parseNativeProjectDocument(EJ(splitJSON), engine: e)
        let r = try planNativeTimelineSplits(original, splits: [firstSplit], engine: e).value!
        XCTAssertEqual(r.splits.count, 1); let s = r.splits[0]
        XCTAssertEqual(s.splitFrame, 60); XCTAssertEqual(s.compatibilitySplitSeconds, (60.0 * 1001) / 30000); XCTAssertEqual(s.compatibilitySplitTime, "2.002")
        XCTAssertEqual(s.sourceFile, "a.html"); XCTAssertEqual(s.leftBinding, .init(sourceFile: "a.html", domId: "clip"))
        XCTAssertEqual(s.rightBinding, .init(sourceFile: "a.html", domId: "clip-split-2"))
        let l = r.document.sequence.tracks[0].clips[0], rt = r.document.sequence.tracks[0].clips[1]
        let effects = [NativeClipEffect(id: "fx:grade", effectId: "grade", enabled: true, parameters: ["exposure": .number(0.2)])]
        let statics: NativeOrderedMap<NativeParameterValue> = ["opacity": .number(0.65), "transform.rotation": .number(15)]
        XCTAssertEqual(l.id, "native:a"); XCTAssertEqual([l.startFrame, l.durationFrames, l.sourceInFrame], [30, 30, 12])
        XCTAssertEqual(l.playbackRate, .init(numerator: 2, denominator: 1)); XCTAssertTrue(l.muted); XCTAssertEqual(l.staticParameters, statics)
        XCTAssertEqual(l.effects, effects); XCTAssertEqual(l.binding, .init(sourceFile: "a.html", domId: "clip"))
        XCTAssertEqual([rt.startFrame, rt.durationFrames, rt.sourceInFrame], [60, 90, 72])
        XCTAssertEqual(rt.playbackRate, .init(numerator: 2, denominator: 1)); XCTAssertTrue(rt.muted); XCTAssertEqual(rt.staticParameters, statics)
        XCTAssertEqual(rt.effects, effects); XCTAssertEqual(rt.binding, .init(sourceFile: "a.html", domId: "clip-split-2"))
        XCTAssertEqual(l.parameterTracks[0].keyframes.map { [$0.frame, num($0.value)] }, [[0, 0], [29, 87]])
        XCTAssertEqual(rt.parameterTracks[0].keyframes[0].frame, 0); XCTAssertEqual(num(rt.parameterTracks[0].keyframes[0].value), 90)
        XCTAssertEqual(original, try parseNativeProjectDocument(EJ(splitJSON), engine: e))
    }

    func testMultipleSourceFilesAsOneEdit() throws {
        let e = try KeyframeRuntime()
        let r = try planNativeTimelineSplits(try parseNativeProjectDocument(EJ(splitJSON), engine: e), splits: [firstSplit,
            .init(element: .init(.init(id: "other", sourceFile: "b.html")), requestedSplitSeconds: 210.0 * 1001 / 30000, rightBinding: .init(sourceFile: "b.html", domId: "other-split"))], engine: e).value!
        XCTAssertEqual(r.sourceFiles, ["a.html", "b.html"]); XCTAssertEqual(r.document.sequence.tracks[0].clips.count, 4)
    }
}

private func rangeEditDocumentJSON(rate: (Int, Int) = (2, 1), binding: Bool = true) -> String {
    let b = binding ? #""binding":{"sourceFile":"index.html","domId":"clip","hfId":"hf-clip"},"# : ""
    return ##"{"schemaVersion":1,"id":"project:range","revision":4,"frameRate":{"numerator":30000,"denominator":1001},"canvas":{"width":1920,"height":1080,"background":"#101010"},"assets":[{"id":"asset:a","kind":"video","name":"a.mov","durationFrames":900}],"sequence":{"id":"sequence:main","name":"Main","tracks":[{"id":"track:v1","kind":"video","clips":[{"id":"clip:a","assetId":"asset:a","##
        + b + ##""startFrame":30,"durationFrames":120,"sourceInFrame":10,"playbackRate":{"numerator":\##(rate.0),"denominator":\##(rate.1)},"muted":true,"staticParameters":{"opacity":0.75},"effects":[{"id":"fx:1","effectId":"blur","enabled":true}],"parameterTracks":[{"schemaVersion":1,"id":"param:rotation","parameterId":"rotation","valueType":"number","frameRate":{"numerator":30000,"denominator":1001},"keyframes":[{"id":"key:0","frame":0,"value":0,"outgoing":{"type":"linear"}},{"id":"key:1","frame":60,"value":180,"outgoing":{"type":"linear"}},{"id":"key:2","frame":90,"value":270,"outgoing":{"type":"hold"}}]}]}]}]}}"##
}
private let rangeElement = NativeSelectedElementReference(id: "clip", hfId: "hf-clip", sourceFile: "index.html", selector: "#clip", selectorIndex: 0)
private func atFrame(_ f: Double) -> Double { (f * 1001) / 30000 }

final class EngineTimelineRangeEditPlanTests: XCTestCase {
    func plan(_ json: String, _ el: NativeSelectedElementReference = rangeElement, _ s: Double, _ d: Double) throws -> NativeTimelineRangeEditPlanResult {
        let e = try KeyframeRuntime()
        return try planNativeTimelineRangeEdit(try parseNativeProjectDocument(EJ(json), engine: e), element: el, requestedStartSeconds: s, requestedDurationSeconds: d, engine: e)
    }
    func testTrimInFramesCanonical() throws {
        let r = try plan(rangeEditDocumentJSON(), rangeElement, atFrame(45) + 1e-12, atFrame(105) + 1e-12).value!
        XCTAssertEqual(r.kind, .trimIn); XCTAssertEqual(r.address, .init(sequenceId: "sequence:main", trackId: "track:v1", clipId: "clip:a"))
        XCTAssertEqual(r.compatibility, .init(start: jsNumberString(atFrame(45)), duration: jsNumberString(atFrame(105)), sourceOffset: jsNumberString(atFrame(40))))
        let t = r.document.sequence.tracks[0].clips[0]
        XCTAssertEqual([t.startFrame, t.durationFrames, t.sourceInFrame], [45, 105, 40]); XCTAssertEqual(t.playbackRate, .init(numerator: 2, denominator: 1))
        XCTAssertTrue(t.muted); XCTAssertEqual(t.staticParameters, ["opacity": .number(0.75)])
        XCTAssertEqual(t.effects, [.init(id: "fx:1", effectId: "blur", enabled: true, parameters: nil)])
        XCTAssertEqual(t.binding, .init(sourceFile: "index.html", domId: "clip", hfId: "hf-clip"))
        let k = t.parameterTracks[0].keyframes
        XCTAssertEqual(k.count, 3)
        XCTAssertEqual(k[0].frame, 0); XCTAssertEqual(num(k[0].value), 45); XCTAssertEqual(k[0].outgoing, .linear)
        XCTAssertEqual(k[1].id, "key:1"); XCTAssertEqual(k[1].frame, 45); XCTAssertEqual(num(k[1].value), 180)
        XCTAssertEqual(k[2].id, "key:2"); XCTAssertEqual(k[2].frame, 75); XCTAssertEqual(num(k[2].value), 270)
    }
    func testTrimOutKeepsSourceOffset() throws {
        let r = try plan(rangeEditDocumentJSON(), rangeElement, atFrame(30), atFrame(60)).value!
        XCTAssertEqual(r.kind, .trimOut)
        XCTAssertEqual(r.compatibility, .init(start: jsNumberString(atFrame(30)), duration: jsNumberString(atFrame(60)), sourceOffset: jsNumberString(atFrame(10))))
        let c = r.document.sequence.tracks[0].clips[0]
        XCTAssertEqual(c.sourceInFrame, 10); XCTAssertTrue(c.muted); XCTAssertEqual(c.staticParameters, ["opacity": .number(0.75)])
        XCTAssertEqual(c.binding, .init(sourceFile: "index.html", domId: "clip", hfId: "hf-clip"))
    }
    func testTrimsNativeOnlyClip() throws {
        var el = rangeElement; el.sourceFile = nil; el.datasetStudioClipId = "clip:a"
        let r = try plan(rangeEditDocumentJSON(binding: false), el, atFrame(30), atFrame(60)).value!
        XCTAssertNil(r.sourceFile); XCTAssertEqual(r.durationFrames, 60)
    }
    func testFractionalSourceBoundary() throws {
        let r = try plan(rangeEditDocumentJSON(rate: (3, 2)), rangeElement, atFrame(31), atFrame(119)).value!
        let c = r.document.sequence.tracks[0].clips[0]
        XCTAssertEqual([c.startFrame, c.durationFrames, c.sourceInFrame], [31, 119, 11]); XCTAssertEqual(c.sourceInFraction, .init(numerator: 1, denominator: 2))
        XCTAssertEqual(jsNumber(r.compatibility.sourceOffset), atFrame(11.5), accuracy: 5e-13)
    }
}

private func multiRangeProjectJSON(unboundSecond: Bool = false) -> String {
    let b = unboundSecond ? "" : ##""binding":{"sourceFile":"a.html","domId":"clip-b","hfId":"hf-b"},"##
    return ##"{"schemaVersion":1,"id":"project:multi-range","revision":12,"frameRate":{"numerator":30000,"denominator":1001},"canvas":{"width":1920,"height":1080,"background":"#101010"},"assets":[{"id":"asset:a","kind":"video","name":"a.mov","durationFrames":900},{"id":"asset:b","kind":"video","name":"b.mov","durationFrames":900}],"sequence":{"id":"sequence:main","name":"Main","tracks":[{"id":"track:v1","kind":"video","lane":{"authoredTrack":2,"displayTrack":0},"clips":[{"id":"clip:a","assetId":"asset:a","binding":{"sourceFile":"z.html","domId":"clip-a","hfId":"hf-a"},"startFrame":30,"durationFrames":120,"sourceInFrame":10,"playbackRate":{"numerator":2,"denominator":1},"muted":true,"staticParameters":{"opacity":0.75},"effects":[{"id":"fx:a","effectId":"blur","enabled":true}],"parameterTracks":[{"schemaVersion":1,"id":"param:a","parameterId":"transform.rotation","valueType":"number","frameRate":{"numerator":30000,"denominator":1001},"keyframes":[{"id":"key:a0","frame":0,"value":0,"outgoing":{"type":"linear"}},{"id":"key:a1","frame":60,"value":180,"outgoing":{"type":"hold"}}]}]},{"id":"clip:b","assetId":"asset:b","##
        + b + ##""startFrame":180,"durationFrames":90,"sourceInFrame":20,"playbackRate":{"numerator":2,"denominator":1},"muted":false,"staticParameters":{"scale":1.25},"effects":[{"id":"fx:b","effectId":"grade","enabled":false}],"parameterTracks":[]}]}]}}"##
}
private let multiChanges: [NativeTimelineMultiRangeEditChange] = [
    .init(element: .init(id: "clip-a", hfId: "hf-a", sourceFile: "z.html"), requestedStartSeconds: atFrame(45) + 1e-12, requestedDurationSeconds: atFrame(105) + 1e-12),
    .init(element: .init(id: "clip-b", hfId: "hf-b", sourceFile: "a.html"), requestedStartSeconds: atFrame(180), requestedDurationSeconds: atFrame(60))]

final class EngineTimelineMultiRangeEditPlanTests: XCTestCase {
    var e: KeyframeRuntime!
    override func setUpWithError() throws { e = try KeyframeRuntime() }
    func project(_ unbound: Bool = false) throws -> NativeProjectDocument { try parseNativeProjectDocument(EJ(multiRangeProjectJSON(unboundSecond: unbound)), engine: e) }
    func bytes(_ d: NativeProjectDocument) throws -> String { try serializeNativeProjectDocument(d, engine: e) }

    func testExactNtscTrimInAndOutWith2xSourceMath() throws {
        let r = try planNativeTimelineMultiRangeEdit(try project(), changes: multiChanges, engine: e).value!
        XCTAssertEqual(r.sourceFiles, ["a.html", "z.html"])
        XCTAssertEqual(r.edits.map(\.address.clipId), ["clip:a", "clip:b"]); XCTAssertEqual(r.edits.map(\.kind), [.trimIn, .trimOut])
        XCTAssertEqual(r.edits.map(\.compatibility), [
            .init(start: jsNumberString(atFrame(45)), duration: jsNumberString(atFrame(105)), sourceOffset: jsNumberString(atFrame(40))),
            .init(start: jsNumberString(atFrame(180)), duration: jsNumberString(atFrame(60)), sourceOffset: jsNumberString(atFrame(20)))])
        let a = r.document.sequence.tracks[0].clips[0], b = r.document.sequence.tracks[0].clips[1]
        XCTAssertEqual([a.startFrame, a.durationFrames, a.sourceInFrame], [45, 105, 40]); XCTAssertEqual(a.playbackRate, .init(numerator: 2, denominator: 1))
        XCTAssertTrue(a.muted); XCTAssertEqual(a.staticParameters, ["opacity": .number(0.75)])
        XCTAssertEqual(a.effects, [.init(id: "fx:a", effectId: "blur", enabled: true, parameters: nil)])
        XCTAssertEqual(a.binding, .init(sourceFile: "z.html", domId: "clip-a", hfId: "hf-a"))
        let k = a.parameterTracks[0].keyframes
        XCTAssertEqual(k.count, 2); XCTAssertEqual(k[0].frame, 0); XCTAssertEqual(num(k[0].value), 45)
        XCTAssertEqual(k[1].id, "key:a1"); XCTAssertEqual(k[1].frame, 45); XCTAssertEqual(num(k[1].value), 180)
        XCTAssertEqual([b.startFrame, b.durationFrames, b.sourceInFrame], [180, 60, 20]); XCTAssertEqual(b.playbackRate, .init(numerator: 2, denominator: 1))
        XCTAssertFalse(b.muted); XCTAssertEqual(b.staticParameters, ["scale": .number(1.25)])
        XCTAssertEqual(b.effects, [.init(id: "fx:b", effectId: "grade", enabled: false, parameters: nil)])
        XCTAssertEqual(b.binding, .init(sourceFile: "a.html", domId: "clip-b", hfId: "hf-b"))
    }

    func testRejectsDuplicateTargetsAcrossAliases() throws {
        let original = try project(); let before = try bytes(original)
        let r = try planNativeTimelineMultiRangeEdit(original, changes: [multiChanges[0], .init(element: .init(sourceFile: "z.html", datasetStudioClipId: "clip:a"),
            requestedStartSeconds: atFrame(30), requestedDurationSeconds: atFrame(60))], engine: e)
        XCTAssertEqual(r.error?.code, .duplicateClip); XCTAssertEqual(r.error?.changeIndex, 1); XCTAssertEqual(try bytes(original), before)
    }

    func testRejectsWholeBatchWhenLaterEditMovesBothBoundaries() throws {
        let original = try project(); let before = try bytes(original)
        var second = multiChanges[1]; second.requestedStartSeconds = atFrame(190); second.requestedDurationSeconds = atFrame(50)
        let r = try planNativeTimelineMultiRangeEdit(original, changes: [multiChanges[0], second], engine: e)
        XCTAssertEqual(r.error?.code, .unsupportedRangeChange); XCTAssertEqual(r.error?.changeIndex, 1); XCTAssertEqual(try bytes(original), before)
    }

    func testTrimsMixedNativeOnlyAndMirroredSelection() throws {
        let original = try project(true); let before = try bytes(original)
        var second = multiChanges[1]; second.element = .init(datasetStudioClipId: "clip:b")
        let r = try planNativeTimelineMultiRangeEdit(original, changes: [multiChanges[0], second], engine: e).value!
        XCTAssertNil(r.edits[1].sourceFile); XCTAssertNil(r.edits[1].binding); XCTAssertEqual(r.edits.count, 2); XCTAssertEqual(try bytes(original), before)
    }
}

// Gesture recording cases that evaluate tracks.
private let gestureJSON = #"{"schemaVersion":1,"id":"project","revision":0,"frameRate":{"numerator":30,"denominator":1},"canvas":{"width":100,"height":100,"background":"\#u{23}000000"},"assets":[{"id":"asset","kind":"image","name":"card","durationFrames":300}],"sequence":{"id":"sequence","name":"Main","tracks":[{"id":"track","kind":"video","clips":[{"id":"clip","assetId":"asset","startFrame":30,"durationFrames":120,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}"#
private let request = NativeGestureRecordingRequest(selectedElement: .init(attributes: ["data-studio-clip-id": "clip"]), playheadSeconds: 2,
                                                    selectionBounds: .init(width: 100, height: 100))
private let recorded: [NativeRecordedKeyframe] = [
    .init(percentage: 0, properties: ["x": .number(0), "y": .number(10), "opacity": .number(1)]),
    .init(percentage: 50, properties: ["x": .number(50), "y": .number(20), "opacity": .number(0.5)]),
    .init(percentage: 100, properties: ["x": .number(100), "y": .number(30), "opacity": .number(0)])]
private func ptracks(_ d: NativeProjectDocument) -> [NativeParameterTrack] { d.sequence.tracks[0].clips[0].parameterTracks }

final class EngineGestureRecordingTests: XCTestCase {
    func testAuthorsAllPropertiesAtClipLocalFrames() throws {
        let e = try KeyframeRuntime(); let before = try parseNativeProjectDocument(EJ(gestureJSON), engine: e)
        let after = try applyNativeGestureRecording(before, request, duration: 1, keys: recorded, engine: e)
        XCTAssertEqual(ptracks(before).count, 0); XCTAssertEqual(ptracks(after).count, 3)
        let x = ptracks(after).first { $0.parameterId == "transform.position.x" }!
        XCTAssertEqual(x.keyframes.map(\.frame), [30, 45, 60])
        XCTAssertEqual(num(try evaluateNativeParameterTrack(x, projectFrame: 39, engine: e)), 30, accuracy: 0.005)
        XCTAssertEqual(try parseNativeProjectDocument(EJ(try serializeNativeProjectDocument(after, engine: e)), engine: e), after)
    }
    func testReplacesCurvedPositionWithoutOldHandles() throws {
        let e = try KeyframeRuntime(); var before = try parseNativeProjectDocument(EJ(gestureJSON), engine: e)
        before.sequence.tracks[0].clips[0].parameterTracks.append(try createNativeParameterTrack(.init(id: "position", parameterId: "transform.position",
            valueType: .vec2, frameRate: .init(numerator: 30, denominator: 1), keyframes: [
                .init(id: "a", frame: 30, value: .vec2(.init(x: 0, y: 0)), outgoing: .linear, outgoingPath: .bezier(cp1: .init(x: 500, y: 500), cp2: .init(x: -500, y: 500))),
                .init(id: "b", frame: 60, value: .vec2(.init(x: 100, y: 100)), outgoing: .linear)]), engine: e))
        let after = try applyNativeGestureRecording(before, request, duration: 1, keys: recorded, engine: e)
        let position = ptracks(after).first { $0.parameterId == "transform.position" }!
        XCTAssertNil(position.keyframes[0].outgoingPath)
        XCTAssertEqual(try evaluateNativeParameterTrack(position, projectFrame: 39, engine: e), .vec2(.init(x: 30, y: 16)))
        XCTAssertNotNil(ptracks(before)[0].keyframes[0].outgoingPath)
    }
}
