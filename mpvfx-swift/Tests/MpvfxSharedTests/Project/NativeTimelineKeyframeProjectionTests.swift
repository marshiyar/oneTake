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
// Timeline keyframe projection (no engine values needed).
import XCTest
@testable import MpvfxShared

final class NativeTimelineKeyframeProjectionTests: XCTestCase {
    let frameRate = RationalFrameRate(numerator: 30, denominator: 1)
    let engine = KeyframeEngineStandIn()
    let ease = NativeInterpolation.cubicBezier(.init(x1: 0.42, y1: 0, x2: 1, y2: 1))

    func numericTrack(_ id: String, _ pid: String, _ values: [(String, Double, Double)]) -> NativeParameterTrack {
        try! createNativeParameterTrack(.init(id: id, parameterId: pid, valueType: .number, frameRate: frameRate,
            keyframes: values.enumerated().map { i, v in NativeKeyframe(id: v.0, frame: v.1, value: .number(v.2), outgoing: i == 0 ? ease : .hold) }), engine: engine)
    }
    func tracks() -> [NativeParameterTrack] { [
        numericTrack("animation:rotation", "transform.rotation", [("rotation:0", 0, 0), ("rotation:90", 90, -180)]),
        numericTrack("animation:y", "transform.position.y", [("y:0", 0, 0), ("y:60", 60, 80)]),
        numericTrack("animation:scaleY", "transform.scaleY", [("scale-y:0", 0, 1)]),
        numericTrack("animation:x", "transform.position.x", [("x:0", 0, 0), ("x:30", 30, 100)]),
        numericTrack("animation:opacity", "visual.opacity", [("opacity:0", 0, 1)]),
        numericTrack("animation:width", "layout.width", [("width:0", 0, 640)]),
        numericTrack("animation:unsupported", "grade.temperature", [("temperature:0", 0, 6500)]),
    ] }
    func fixture(_ parameterTracks: [NativeParameterTrack]? = nil) -> NativeProjectDocument {
        func clip(_ id: String, _ dom: String, _ hf: String, _ start: Double, _ srcIn: Double, _ t: [NativeParameterTrack]) -> NativeProjectClip {
            NativeProjectClip(id: id, assetId: "asset:video", binding: .init(sourceFile: "scenes/main.html", domId: dom, hfId: hf, selector: "#\(dom)", selectorIndex: 0),
                startFrame: start, durationFrames: 120, sourceInFrame: srcIn, playbackRate: DEFAULT_NATIVE_PLAYBACK_RATE, muted: false,
                staticParameters: [:], effects: [], parameterTracks: t)
        }
        return NativeProjectDocument(schemaVersion: NATIVE_PROJECT_DOCUMENT_SCHEMA_VERSION, id: "project:timeline-projection", revision: 0, frameRate: frameRate,
            canvas: .init(width: 1920, height: 1080, background: "#111111"),
            assets: [.init(id: "asset:video", kind: .video, name: "video.mov", durationFrames: 400)],
            sequence: .init(id: "sequence:main", name: "Main", tracks: [.init(id: "track:video", kind: .video, lane: .init(authoredTrack: 0, displayTrack: 0), clips: [
                clip("clip:first", "preview-first", "hf-first", 30, 0, parameterTracks ?? tracks()), clip("clip:second", "preview-second", "hf-second", 150, 120, [])])]))
    }
    func success(_ r: NativeTimelineKeyframeProjectionResult) throws -> NativeTimelineKeyframeProjection {
        switch r { case .success(let p): return p; case .failure(let f): XCTFail("\(f)"); throw f }
    }

    func testGroupsLanesAndOmitsUnsupported() throws {
        let r = try success(projectNativeTimelineKeyframes(fixture(), .init(attributes: ["data-studio-clip-id": "clip:first"])))
        XCTAssertEqual(r.sequenceId, "sequence:main"); XCTAssertEqual(r.trackId, "track:video"); XCTAssertEqual(r.clipId, "clip:first")
        XCTAssertEqual(r.clipStartFrame, 30); XCTAssertEqual(r.clipDurationFrames, 120)
        XCTAssertEqual(r.groups.map { "\($0.id.rawValue)/\($0.label)" }, ["position/Position", "rotation/Rotation", "scale/Scale", "opacity/Opacity", "size/Size"])
        XCTAssertEqual(r.groups.map { $0.lanes.map(\.property) }, [[.x, .y], [.rotation], [.scaleY], [.opacity], [.width]])
        XCTAssertFalse(r.groups.flatMap(\.lanes).contains { $0.parameterId == "grade.temperature" })
    }
    func testDiamonds() throws {
        let r = try success(projectNativeTimelineKeyframes(fixture(), .init(id: "clip:first")))
        let lane = r.groups.first { $0.id == .rotation }!.lanes[0]
        XCTAssertEqual([lane.laneId, lane.animationId, lane.parameterId, lane.property.rawValue, lane.label],
                       ["animation:rotation", "animation:rotation", "transform.rotation", "rotation", "Rotation"])
        XCTAssertEqual(lane.diamonds, [
            .init(id: "rotation:0", keyframeId: "rotation:0", animationId: "animation:rotation", parameterId: "transform.rotation", frame: 0, percentage: 0, value: 0, interpolation: ease),
            .init(id: "rotation:90", keyframeId: "rotation:90", animationId: "animation:rotation", parameterId: "transform.rotation", frame: 90, percentage: 75, value: -180, interpolation: .hold)])
    }
    func test3DLanes() throws {
        let r = try success(projectNativeTimelineKeyframes(fixture([
            numericTrack("animation:z", "transform.position.z", [("z:0", 0, 120)]), numericTrack("animation:rx", "transform.rotationX", [("rx:0", 0, 12)]),
            numericTrack("animation:ry", "transform.rotationY", [("ry:0", 0, -18)]), numericTrack("animation:perspective", "transform.perspective", [("p:0", 0, 900)]),
            numericTrack("animation:scaleZ", "transform.scaleZ", [("sz:0", 0, 0.8)])]), .init(id: "clip:first")))
        XCTAssertEqual(r.groups.map { "\($0.id.rawValue):" + $0.lanes.map { "\($0.property.rawValue)=\($0.label)" }.joined(separator: ",") },
                       ["position:z=Z", "rotation:rotationX=Rotate X,rotationY=Rotate Y,transformPerspective=Perspective", "scale:scaleZ=Scale Z"])
    }
    func testDeterministicAcrossTrackOrder() throws {
        XCTAssertEqual(try success(projectNativeTimelineKeyframes(fixture(Array(tracks().reversed())), .init(id: "clip:first"))),
                       try success(projectNativeTimelineKeyframes(fixture(tracks()), .init(id: "clip:first"))))
    }
    func testScopedBinding() throws {
        XCTAssertEqual(try success(projectNativeTimelineKeyframes(fixture(), .init(id: "preview-first", sourceFile: "scenes/main.html"))).clipId, "clip:first")
    }
    func testAmbiguousScopedIdentity() {
        guard case .failure(let f) = projectNativeTimelineKeyframes(fixture(), .init(id: "preview-first", hfId: "hf-second", sourceFile: "scenes/main.html")) else { return XCTFail() }
        XCTAssertEqual(f.code, "ambiguous-clip")
    }
    func testEmptyGroupsForClipWithoutTracks() throws {
        XCTAssertEqual(try success(projectNativeTimelineKeyframes(fixture(), .init(attributes: ["data-studio-clip-id": "clip:second"]))).groups, [])
    }
    func testKeyframeOutsideClipFails() {
        let r = projectNativeTimelineKeyframes(fixture([numericTrack("animation:late", "transform.rotation", [("late:key", 120, -180)])]), .init(id: "clip:first"))
        guard case .failure(.keyframeOutsideClip(_, let pid, let kid)) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(pid, "transform.rotation"); XCTAssertEqual(kid, "late:key")
    }
}
