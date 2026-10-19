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
// The native project document: parse, validation, defaults and serialization. Documents are untyped JSON (NativeJSONValue).
import XCTest
@testable import MpvfxShared

func J(_ text: String) -> NativeJSONValue { try! NativeJSONValue.parse(text) }

extension NativeJSONValue {
    mutating func append(_ v: NativeJSONValue) { if case .array(var a) = self { a.append(v); self = .array(a) } }
    mutating func popLast() { if case .array(var a) = self { a.removeLast(); self = .array(a) } }
}

func validNativeDocument() -> NativeJSONValue {
    J("""
    {"schemaVersion":1,"mediaEngine":"native","id":"project:demo","revision":0,"frameRate":{"numerator":30000,"denominator":1001},
     "canvas":{"width":1920,"height":1080,"background":"#101010"},
     "assets":[{"id":"asset:camera-a","kind":"video","name":"camera-a.mov","durationFrames":300}],
     "sequence":{"id":"sequence:main","name":"Main","tracks":[{"id":"track:video-1","kind":"video","clips":[
       {"id":"clip:camera-a-1","assetId":"asset:camera-a","startFrame":0,"durationFrames":90,"sourceInFrame":10,"effects":[],"parameterTracks":[]}]}]}}
    """)
}

final class NativeProjectDocumentTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func parse(_ d: NativeJSONValue) throws -> NativeProjectDocument { try parseNativeProjectDocument(d, engine: engine) }
    func serialize(_ d: NativeJSONValue) throws -> String { try serializeNativeProjectDocument(d, engine: engine) }
    func roundTrip(_ d: NativeJSONValue) throws -> NativeProjectDocument { try parse(J(try serialize(d))) }
    func issues(_ d: NativeJSONValue, file: StaticString = #filePath, line: UInt = #line) -> [NativeProjectDocumentValidationIssue] {
        do { _ = try parse(d); XCTFail("expected NativeProjectDocumentValidationError", file: file, line: line); return [] }
        catch let e as NativeProjectDocumentValidationError { return e.issues }
        catch { XCTFail("wrong error \(error)", file: file, line: line); return [] }
    }
    func assertThrows(_ d: NativeJSONValue, _ text: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let found = issues(d, file: file, line: line)
        if let text { XCTAssertTrue(NativeProjectDocumentValidationError(issues: found).message.contains(text), "\(found)", file: file, line: line) }
    }
    func clip(_ d: inout NativeJSONValue, _ key: String, _ v: NativeJSONValue?, track: Int = 0, clip: Int = 0) {
        d["sequence"]?["tracks"]?[track]?["clips"]?[clip]?[key] = v
    }

    func testRoundTripsCropPivotIntervalsAndRejectsMalformedOffsets() throws {
        var d = validNativeDocument()
        let segs = J(#"[{"startRotationKeyId":"rotation:first","endRotationKeyId":"rotation:last","offsetFraction":{"x":0.05,"y":-0.1}}]"#)
        clip(&d, "cropPivotSegments", segs)
        XCTAssertEqual(try NativeJSONValue.from(try roundTrip(d).sequence.tracks[0].clips[0].cropPivotSegments), segs)
        XCTAssertNil(try parse(validNativeDocument()).sequence.tracks[0].clips[0].cropPivotSegments)
        d["sequence"]?["tracks"]?[0]?["clips"]?[0]?["cropPivotSegments"]?[0]?["offsetFraction"]?["x"] = .number(0.6)
        assertThrows(d, "Crop pivot segment needs two key IDs")
    }

    func testRoundTripsAudioBusesAndMembership() throws {
        var d = validNativeDocument()
        d["assets"]?.append(J(#"{"id":"asset:voice","kind":"audio","name":"voice.wav","durationFrames":300}"#))
        let groups = J(#"[{"id":"dialogue","label":"Dialogue","volume":0.5,"muted":false,"fxChain":"{\"version\":1,\"nodes\":[]}"}]"#)
        d["sequence"]?["audioGroups"] = groups
        clip(&d, "audioGroupId", .string("dialogue"))
        clip(&d, "sourceInFraction", J(#"{"numerator":1,"denominator":3}"#))
        let restored = try roundTrip(d)
        XCTAssertEqual(try NativeJSONValue.from(restored.sequence.audioGroups), groups)
        XCTAssertEqual(restored.sequence.tracks[0].clips[0].id, "clip:camera-a-1")
        XCTAssertEqual(restored.sequence.tracks[0].clips[0].audioGroupId, "dialogue")
        XCTAssertEqual(restored.sequence.tracks[0].clips[0].sourceInFraction, .init(numerator: 1, denominator: 3))
        XCTAssertNil(try parse(validNativeDocument()).sequence.audioGroups)
    }

    func testRejectsDanglingDuplicateOrNonMediaAudioMemberships() {
        var d = validNativeDocument()
        clip(&d, "audioGroupId", .string("missing"))
        assertThrows(d, "Clip audio group must name a defined bus")
        d["sequence"]?["audioGroups"] = J(#"[{"id":"missing"},{"id":"missing"}]"#)
        assertThrows(d, "Duplicate stable ID missing")
        d["sequence"]?["audioGroups"]?.popLast()
        d["assets"]?[0]?["kind"] = .string("image")
        assertThrows(d, "Only audio and video clips can join an audio group")
    }

    func testPreservesEngineOwnershipMediaPathsAndBlankTails() throws {
        var d = validNativeDocument()
        d["mediaEngine"] = .string("native")
        d["assets"]?[0]?["source"] = .string("assets/camera-a.mov")
        d["sequence"]?["durationFrames"] = .number(180)
        let r = try roundTrip(d)
        XCTAssertEqual(r.mediaEngine, .native); XCTAssertEqual(r.assets[0].source, "assets/camera-a.mov"); XCTAssertEqual(r.sequence.durationFrames, 180)
    }

    func testOlderEngineNamesMigrateToNativeOnTheNextSave() throws {
        // "ffmpeg" (the older stored name) and a missing field are both the native timeline; the save writes "native"
        // and changes nothing else.
        var named = validNativeDocument(); named["mediaEngine"] = .string("ffmpeg")
        var missing = validNativeDocument(); missing["mediaEngine"] = nil
        var current = validNativeDocument(); current["mediaEngine"] = .string("native")
        let expected = try serializeNativeProjectDocument(current)
        try assertMigratesToNative(named, expected)
        try assertMigratesToNative(missing, expected)
    }

    private func assertMigratesToNative(_ old: NativeJSONValue, _ expected: String, line: UInt = #line) throws {
        XCTAssertEqual(try parse(old).mediaEngine, .native, line: line)
        let saved = try serializeNativeProjectDocument(old)
        XCTAssertTrue(saved.contains(#""mediaEngine": "native""#), saved, line: line)
        XCTAssertFalse(saved.contains("ffmpeg"), saved, line: line)
        XCTAssertEqual(saved, expected, line: line)
    }

    func testUnknownEngineIsNotNative() {
        var d = validNativeDocument(); d["mediaEngine"] = .string("unknown")
        assertThrows(d, "Unknown media engine")
    }

    func testFixedPersistencePath() { XCTAssertEqual(NATIVE_PROJECT_DOCUMENT_PATH, ".studio/project.json") }

    func testParsesAndDefaultsPlaybackAndMute() throws {
        let p = try parse(validNativeDocument())
        XCTAssertEqual(p.schemaVersion, 1); XCTAssertEqual(p.id, "project:demo"); XCTAssertEqual(p.revision, 0)
        XCTAssertEqual(p.frameRate, .init(numerator: 30_000, denominator: 1_001))
        XCTAssertEqual(p.canvas, .init(width: 1920, height: 1080, background: "#101010"))
        XCTAssertEqual(p.sequence.tracks[0].clips[0].muted, false)
        XCTAssertEqual(p.sequence.tracks[0].clips[0].playbackRate, .init(numerator: 1, denominator: 1))
        XCTAssertEqual(p.sequence.tracks[0].clips[0].staticParameters, [:])
        XCTAssertEqual(p.sequence.tracks[0].lane, .init(authoredTrack: 0, displayTrack: 0))
    }

    func testRoundTripsSparseLanesWithoutDerivingFromIds() throws {
        var d = validNativeDocument()
        d["sequence"]?["tracks"]?[0]?["id"] = .string("opaque-track-identity")
        d["sequence"]?["tracks"]?[0]?["lane"] = J(#"{"authoredTrack":17,"displayTrack":2}"#)
        let p = try roundTrip(d)
        XCTAssertEqual(p.sequence.tracks[0].id, "opaque-track-identity")
        XCTAssertEqual(p.sequence.tracks[0].lane, .init(authoredTrack: 17, displayTrack: 2))
        XCTAssertEqual(findNativeProjectTrackByLane(p, .init(kind: .video, authoredTrack: 17))?.id, "opaque-track-identity")
        XCTAssertEqual(findNativeProjectTrackByLane(p, .init(kind: .video, displayTrack: 2))?.id, "opaque-track-identity")
        XCTAssertNil(findNativeProjectTrackByLane(p, .init(kind: .audio, displayTrack: 2)))
    }

    func testRejectsInvalidExplicitLaneMetadata() {
        for (name, lane) in [("non-object", "null"), ("fractional authored track", #"{"authoredTrack":1.5,"displayTrack":0}"#),
                             ("negative authored track", #"{"authoredTrack":-1,"displayTrack":0}"#),
                             ("fractional display track", #"{"authoredTrack":1,"displayTrack":0.5}"#),
                             ("negative display track", #"{"authoredTrack":1,"displayTrack":-1}"#)] {
            var d = validNativeDocument(); d["sequence"]?["tracks"]?[0]?["lane"] = J(lane)
            XCTAssertFalse(issues(d).isEmpty, name)
        }
    }

    func testRejectsDuplicateDisplayLanesAndAuthoredLanesPerKind() throws {
        var dup = validNativeDocument()
        dup["sequence"]?["tracks"]?[0]?["lane"] = J(#"{"authoredTrack":8,"displayTrack":2}"#)
        dup["sequence"]?["tracks"]?.append(J(#"{"id":"track:audio-1","kind":"audio","lane":{"authoredTrack":8,"displayTrack":2},"clips":[]}"#))
        assertThrows(dup)
        var authored = validNativeDocument()
        authored["sequence"]?["tracks"]?[0]?["lane"] = J(#"{"authoredTrack":8,"displayTrack":1}"#)
        authored["sequence"]?["tracks"]?.append(J(#"{"id":"track:video-2","kind":"video","lane":{"authoredTrack":8,"displayTrack":2},"clips":[]}"#))
        assertThrows(authored)
        var other = validNativeDocument()
        other["sequence"]?["tracks"]?[0]?["lane"] = J(#"{"authoredTrack":8,"displayTrack":1}"#)
        other["sequence"]?["tracks"]?.append(J(#"{"id":"track:audio-1","kind":"audio","lane":{"authoredTrack":8,"displayTrack":2},"clips":[]}"#))
        XCTAssertNoThrow(try parse(other))
    }

    func testRoundTripsExactRationalPlaybackRate() throws {
        var d = validNativeDocument(); clip(&d, "playbackRate", J(#"{"numerator":1001,"denominator":1000}"#))
        XCTAssertEqual(try roundTrip(d).sequence.tracks[0].clips[0].playbackRate, .init(numerator: 1_001, denominator: 1_000))
    }

    func testRejectsInvalidExactPlaybackRate() {
        for (name, rate) in [("non-object", "2"), ("zero numerator", #"{"numerator":0,"denominator":1}"#),
                             ("negative numerator", #"{"numerator":-1,"denominator":1}"#), ("zero denominator", #"{"numerator":1,"denominator":0}"#),
                             ("fractional numerator", #"{"numerator":1.5,"denominator":1}"#),
                             ("unsafe denominator", #"{"numerator":1,"denominator":9007199254740992}"#)] {
            var d = validNativeDocument(); clip(&d, "playbackRate", J(rate))
            XCTAssertTrue(issues(d).contains { $0.code == .invalidPlaybackRate && $0.path == "sequence.tracks[0].clips[0].playbackRate" }, name)
        }
    }

    func testUsesPlaybackRateForSourceRange() {
        var slow = validNativeDocument()
        clip(&slow, "sourceInFrame", .number(250)); clip(&slow, "durationFrames", .number(90))
        clip(&slow, "playbackRate", J(#"{"numerator":1,"denominator":2}"#))
        XCTAssertNoThrow(try parse(slow))
        var fast = validNativeDocument()
        clip(&fast, "sourceInFrame", .number(10)); clip(&fast, "durationFrames", .number(90))
        clip(&fast, "playbackRate", J(#"{"numerator":4,"denominator":1}"#))
        assertThrows(fast)
    }

    /// Overflow mapping (swift-only): an Int64 overflow in the source-range check is reported as source-out-of-bounds.
    func testSourceRangeOverflowIsReportedAsOutOfBounds() {
        var d = validNativeDocument()
        clip(&d, "playbackRate", J(#"{"numerator":1,"denominator":9007199254740991}"#))
        clip(&d, "sourceInFraction", J(#"{"numerator":1,"denominator":9007199254740991}"#))
        XCTAssertTrue(issues(d).contains { $0.code == .sourceOutOfBounds && $0.path == "sequence.tracks[0].clips[0]" })
    }

    func testRoundTripsStaticParameters() throws {
        var d = validNativeDocument()
        let sp = J(#"{"opacity":0.75,"position":{"x":120,"y":-40},"tint":{"red":0.2,"green":0.4,"blue":0.8,"alpha":1}}"#)
        clip(&d, "staticParameters", sp)
        XCTAssertEqual(try NativeJSONValue.from(try roundTrip(d).sequence.tracks[0].clips[0].staticParameters), sp)
    }

    func testClonesStaticParametersInsteadOfRetaining() throws {
        // Swift values are copied; mutating the input after parsing cannot reach the parsed document.
        var d = validNativeDocument()
        clip(&d, "staticParameters", J(#"{"position":{"x":120,"y":-40},"tint":{"red":0.2,"green":0.4,"blue":0.8,"alpha":1}}"#))
        let p = try parse(d)
        d["sequence"]?["tracks"]?[0]?["clips"]?[0]?["staticParameters"]?["position"]?["x"] = .number(999)
        XCTAssertEqual(p.sequence.tracks[0].clips[0].staticParameters,
                       ["position": .vec2(.init(x: 120, y: -40)), "tint": .rgba(.init(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))])
    }

    func testRejectsMalformedStaticParameters() {
        let cases: [(String, NativeJSONValue)] = [
            ("non-object map", .null), ("non-finite number", .object(["opacity": .number(.nan)])),
            ("non-finite vec2 component", .object(["position": .object(["x": .number(.infinity), "y": .number(0)])])),
            ("missing vec2 component", J(#"{"position":{"x":0}}"#)),
            ("out-of-range rgba channel", J(#"{"tint":{"red":1.1,"green":0,"blue":0,"alpha":1}}"#)),
            ("missing rgba channel", J(#"{"tint":{"red":0,"green":0,"blue":0}}"#))]
        for (name, sp) in cases {
            var d = validNativeDocument(); clip(&d, "staticParameters", sp)
            XCTAssertFalse(issues(d).isEmpty, name)
        }
    }

    func testRoundTripsScopedDomBinding() throws {
        var d = validNativeDocument()
        let b = J(##"{"sourceFile":"index.html","domId":"camera-a","hfId":"hf-camera-a","selector":"#composition > .camera-a","selectorIndex":0}"##)
        clip(&d, "binding", b)
        let p = try parse(d)
        XCTAssertEqual(p.sequence.tracks[0].clips[0].id, "clip:camera-a-1")
        XCTAssertEqual(try NativeJSONValue.from(p.sequence.tracks[0].clips[0].binding), b)
        XCTAssertEqual(try parse(J(try serializeNativeProjectDocument(p, engine: engine))), p)
    }

    func testRejectsInvalidClipBindings() {
        for (name, b) in [("missing source file", #"{"domId":"camera-a"}"#), ("blank source file", #"{"sourceFile":"  ","domId":"camera-a"}"#),
                          ("no exact identifier", #"{"sourceFile":"index.html"}"#), ("blank identifier", #"{"sourceFile":"index.html","domId":""}"#),
                          ("selector index without a selector", #"{"sourceFile":"index.html","domId":"camera-a","selectorIndex":0}"#),
                          ("negative selector index", #"{"sourceFile":"index.html","selector":".camera","selectorIndex":-1}"#),
                          ("fractional selector index", #"{"sourceFile":"index.html","selector":".camera","selectorIndex":0.5}"#)] {
            var d = validNativeDocument(); clip(&d, "binding", J(b))
            XCTAssertFalse(issues(d).isEmpty, name)
        }
    }

    func testRejectsDuplicateScopedBindingsButAllowsOtherFile() throws {
        var d = validNativeDocument()
        clip(&d, "binding", J(#"{"sourceFile":"index.html","domId":"camera-a"}"#))
        var second = d["sequence"]!["tracks"]![0]!["clips"]![0]!
        second["id"] = .string("clip:camera-a-2")
        d["sequence"]?["tracks"]?[0]?["clips"]?.append(second)
        assertThrows(d)
        clip(&d, "binding", J(#"{"sourceFile":"nested.html","domId":"camera-a"}"#), clip: 1)
        XCTAssertNoThrow(try parse(d))
    }

    func testSerializesCanonicallyAndRoundTrips() throws {
        var d = validNativeDocument()
        d["sequence"]?["tracks"]?[0]?["clips"]?[0]?["parameterTracks"]?.append(J("""
        {"schemaVersion":1,"id":"parameter:camera-a-rotation","parameterId":"transform.rotation","valueType":"number",
         "frameRate":{"numerator":30000,"denominator":1001},"keyframes":[
          {"id":"key:rotate-start","frame":0,"value":0,"outgoing":{"type":"linear"}},
          {"id":"key:rotate-end","frame":90,"value":-180,"outgoing":{"type":"linear"}}]}
        """))
        let first = try serialize(d)
        XCTAssertEqual(try serialize(J(first)), first)
        XCTAssertEqual(try parse(J(first)), try parse(d))
        // Exact JSON.stringify(canonicalize(...), null, 2) layout, checked against Node for this document's prefix.
        XCTAssertTrue(first.hasPrefix("{\n  \"assets\": [\n    {\n      \"durationFrames\": 300,\n      \"id\": \"asset:camera-a\","), first)
        XCTAssertTrue(first.hasSuffix("\n}\n"))
    }

    func testRejectsInsteadOfRepairing() {
        let muts: [(String, (inout NativeJSONValue) -> Void)] = [
            ("unknown schema version", { $0["schemaVersion"] = .number(2) }),
            ("negative revision", { $0["revision"] = .number(-1) }),
            ("fractional frame rate", { $0["frameRate"] = J(#"{"numerator":29.97,"denominator":1}"#) }),
            ("zero canvas width", { $0["canvas"]?["width"] = .number(0) }),
            ("fractional clip start", { $0["sequence"]?["tracks"]?[0]?["clips"]?[0]?["startFrame"] = .number(0.5) })]
        for (name, m) in muts { var d = validNativeDocument(); m(&d); XCTAssertFalse(issues(d).isEmpty, name) }
    }

    func testReportsDuplicateIdsWithPaths() {
        var d = validNativeDocument()
        d["sequence"]?["tracks"]?.append(J(#"{"id":"track:video-1","kind":"video","clips":[]}"#))
        XCTAssertTrue(issues(d).contains { $0.code == .duplicateId && $0.path == "sequence.tracks[1].id" })
    }

    func testRejectsMissingAssetsMismatchesAndOverruns() {
        var missing = validNativeDocument(); clip(&missing, "assetId", .string("asset:missing")); assertThrows(missing)
        var mismatch = validNativeDocument(); mismatch["sequence"]?["tracks"]?[0]?["kind"] = .string("audio"); assertThrows(mismatch)
        var overrun = validNativeDocument(); clip(&overrun, "sourceInFrame", .number(250)); clip(&overrun, "durationFrames", .number(51)); assertThrows(overrun)
    }

    func testAcceptsElementLayersOnPictureTracks() throws {
        var layered = validNativeDocument()
        layered["assets"]?.append(J(#"{"id":"asset:title","kind":"element","name":"Title","durationFrames":40}"#))
        layered["sequence"]?["tracks"]?[0]?["clips"]?.append(J(
            #"{"id":"clip:title","assetId":"asset:title","startFrame":90,"durationFrames":120,"sourceInFrame":0,"effects":[],"parameterTracks":[]}"#))
        let p = try parse(layered)
        XCTAssertEqual(p.assets[1], NativeProjectAsset(id: "asset:title", kind: .element, name: "Title", source: nil, durationFrames: 40))
        XCTAssertEqual(p.sequence.tracks[0].clips[1].id, "clip:title")

        var onAudio = validNativeDocument()
        onAudio["assets"] = J(#"[{"id":"asset:title","kind":"element","name":"Title","durationFrames":40}]"#)
        onAudio["sequence"]?["tracks"]?[0]?["kind"] = .string("audio"); clip(&onAudio, "assetId", .string("asset:title"))
        assertThrows(onAudio)
        var withSource = validNativeDocument()
        withSource["assets"]?.append(J(#"{"id":"asset:title","kind":"element","name":"Title","source":"title.html","durationFrames":40}"#))
        assertThrows(withSource, "no source file")
        // Whatever the stored engine name, an element clip without `text` (a layer from an earlier version of the
        // editor) is valid and kept; a text layer (`text`) parses as one.
        try assertElementLayerKept(engine: "native")
        try assertElementLayerKept(engine: "ffmpeg")
    }

    private func assertElementLayerKept(engine: String) throws {
        var nativeMedia = validNativeDocument(); nativeMedia["mediaEngine"] = .string(engine)
        nativeMedia["assets"]?.append(J(#"{"id":"asset:title","kind":"element","name":"Title","durationFrames":40}"#))
        XCTAssertNoThrow(try parse(nativeMedia))
        nativeMedia["sequence"]?["tracks"]?[0]?["clips"]?.append(J(
            #"{"id":"clip:title","assetId":"asset:title","startFrame":90,"durationFrames":120,"sourceInFrame":0,"effects":[],"parameterTracks":[]}"#))
        let undrawn = try parse(nativeMedia)
        XCTAssertTrue(undrawn.isUndrawnElementClip(undrawn.sequence.tracks[0].clips[1]))
        var text = nativeMedia
        text["sequence"]?["tracks"]?[0]?["clips"]?[1]?["text"] = J(#"{"content":"Title"}"#)
        let drawn = try parse(text)
        XCTAssertEqual(drawn.sequence.tracks[0].clips[1].text?.content, "Title")
        XCTAssertFalse(drawn.isUndrawnElementClip(drawn.sequence.tracks[0].clips[1]))
    }

    func testAnUndrawnElementLayerSurvivesASaveByteForByteAndIsNoticedOnce() throws {
        // An element layer from an earlier version of the editor, with a DOM binding, keyframes, effects and fields
        // the Swift renderer does not draw: open + save keeps every field of it.
        var legacy = validNativeDocument(); legacy["mediaEngine"] = nil
        legacy["assets"]?.append(J(#"{"id":"asset:card","kind":"element","name":"Lower third","durationFrames":40}"#))
        let layer = J(#"""
            {"id":"clip:card","assetId":"asset:card","startFrame":10,"durationFrames":30,"sourceInFrame":0,
             "binding":{"sourceFile":"index.html","domId":"card","hfId":"hf-card","selector":".card","selectorIndex":0},
             "staticParameters":{"opacity":0.5},"effects":[],"parameterTracks":[]}
            """#)
        legacy["sequence"]?["tracks"]?[0]?["clips"]?.append(layer)
        legacy["sequence"]?["tracks"]?[0]?["clips"]?.append(J(#"""
            {"id":"clip:card-2","assetId":"asset:card","startFrame":60,"durationFrames":20,"sourceInFrame":0,"effects":[],"parameterTracks":[]}
            """#))
        let first = try serializeNativeProjectDocument(legacy)
        let reopened = try parse(try NativeJSONValue.parse(first))
        XCTAssertEqual(try serializeNativeProjectDocument(reopened), first)
        XCTAssertEqual(reopened.assets.last, NativeProjectAsset(id: "asset:card", kind: .element, name: "Lower third", source: nil, durationFrames: 40))
        let card = try XCTUnwrap(reopened.sequence.tracks[0].clips.first { $0.id == "clip:card" })
        XCTAssertEqual(card.binding?.domId, "card"); XCTAssertEqual(card.binding?.selector, ".card")
        XCTAssertEqual(card.staticParameters?["opacity"], .number(0.5))
        XCTAssertEqual(reopened.undrawnElementLayerCount, 2)
        XCTAssertEqual(reopened.undrawnElementLayersNotice,
                       "2 layers from an earlier version of the editor are kept in the project but not drawn in preview or export.")
        XCTAssertNil(try parse(validNativeDocument()).undrawnElementLayersNotice)
    }

    func rotationTrack(_ id: String, _ keyId: String, _ frame: Double, _ value: Double = -180) -> NativeJSONValue {
        J(#"{"schemaVersion":1,"id":"\#(id)","parameterId":"transform.rotation","valueType":"number","frameRate":{"numerator":30000,"denominator":1001},"keyframes":[{"id":"\#(keyId)","frame":\#(jsNumberString(frame)),"value":\#(jsNumberString(value)),"outgoing":{"type":"linear"}}]}"#)
    }

    func testDelegatesParameterTrackIntegrity() {
        var d = validNativeDocument()
        d["sequence"]?["tracks"]?[0]?["clips"]?[0]?["parameterTracks"] = .array([rotationTrack("parameter:rotation-a", "key:shared", 0, 0),
                                                                                 rotationTrack("parameter:rotation-b", "key:shared", 1)])
        assertThrows(d)
    }

    func testCoreDuplicateKeyframeBecomesScopedIssue() {
        var d = validNativeDocument()
        d["sequence"]?["tracks"]?[0]?["clips"]?[0]?["parameterTracks"]?.append(J("""
        {"schemaVersion":1,"id":"parameter:rotation","parameterId":"transform.rotation","valueType":"number","frameRate":{"numerator":30000,"denominator":1001},
         "keyframes":[{"id":"key:duplicate","frame":0,"value":0,"outgoing":{"type":"linear"}},{"id":"key:duplicate","frame":90,"value":-180,"outgoing":{"type":"linear"}}]}
        """))
        XCTAssertTrue(issues(d).contains { $0.code == .invalidParameterTrack && $0.path == "sequence.tracks[0].clips[0].parameterTracks[0]" })
    }

    func testRejectsEveryKeyframeBeyondClipDuration() {
        var d = validNativeDocument()
        clip(&d, "parameterTracks", J("""
        [{"schemaVersion":1,"id":"parameter:opacity","parameterId":"opacity","valueType":"number","frameRate":{"numerator":30000,"denominator":1001},
          "keyframes":[{"id":"key:opacity-outside","frame":91,"value":0.5,"outgoing":{"type":"linear"}}]},
         {"schemaVersion":1,"id":"parameter:position","parameterId":"transform.position","valueType":"vec2","frameRate":{"numerator":30000,"denominator":1001},
          "keyframes":[{"id":"key:position-outside","frame":120,"value":{"x":10,"y":20},"outgoing":{"type":"linear"}}]},
         {"schemaVersion":1,"id":"parameter:tint","parameterId":"color.tint","valueType":"rgba","frameRate":{"numerator":30000,"denominator":1001},
          "keyframes":[{"id":"key:tint-outside","frame":92,"value":{"red":1,"green":0.5,"blue":0,"alpha":1},"outgoing":{"type":"linear"}}]}]
        """))
        let found = issues(d)
        for (i, f) in [(0, 91), (1, 120), (2, 92)] {
            XCTAssertTrue(found.contains(.init(code: .invalidParameterTrack, path: "sequence.tracks[0].clips[0].parameterTracks[\(i)].keyframes[0].frame",
                                               message: "Keyframe frame \(f) exceeds clip duration 90")), "\(found)")
        }
    }

    func testAcceptsKeyframesAtBoundaryFrames() {
        for frame in [89.0, 90.0] {
            var d = validNativeDocument()
            d["sequence"]?["tracks"]?[0]?["clips"]?[0]?["parameterTracks"]?.append(rotationTrack("parameter:rotation:\(Int(frame))", "key:rotation:\(Int(frame))", frame))
            XCTAssertNoThrow(try parse(d), "\(frame)")
        }
    }
}
