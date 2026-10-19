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
// Position path commands. Every case except the timeline-lane one evaluates
// the curve and runs against KeyframeRuntime in MpvfxSharedEngineTests (EnginePositionPathCommandsTests,
// EnginePositionPropertyCommandsTests, EnginePositionDisplayTests).
import XCTest
@testable import MpvfxShared

final class NativePositionPathCommandsTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func testSeparateXYTimelineLanesShareKeyframeIdentities() throws {
        func scalar(_ p: String, _ v: [Int]) -> String {
            #"{"schemaVersion":1,"id":"parameter:\#(p)","parameterId":"\#(p)","valueType":"number","frameRate":{"numerator":30,"denominator":1},"keyframes":[{"id":"\#(p):0","frame":0,"value":\#(v[0]),"outgoing":{"type":"cubic-bezier","controlPoints":{"x1":0.42,"y1":0,"x2":0.58,"y2":1}}},{"id":"\#(p):40","frame":40,"value":\#(v[1]),"outgoing":{"type":"linear"}},{"id":"\#(p):90","frame":90,"value":\#(v[2]),"outgoing":{"type":"linear"}}]}"#
        }
        let base = try parseNativeProjectDocument(J("""
        {"schemaVersion":1,"id":"project:demo","revision":1,"frameRate":{"numerator":30,"denominator":1},"canvas":{"width":1920,"height":1080,"background":"#101010"},
         "assets":[{"id":"asset:video","kind":"video","name":"video.mov","durationFrames":360}],
         "sequence":{"id":"sequence:main","name":"Main","tracks":[{"id":"track:video","kind":"video","clips":[{"id":"clip:first","assetId":"asset:video",
          "startFrame":0,"durationFrames":120,"sourceInFrame":0,"muted":false,"effects":[],
          "parameterTracks":[\(scalar("transform.position.x", [0, 400, 700])),\(scalar("transform.position.y", [0, 0, 250]))]}]}]}}
        """), engine: engine)
        var a = keyframeAddress; a.parameterId = "transform.position"
        let curved = try applyNativeProjectKeyframeCommand(base, .atomic(.setMotionPath(address: a, frame: 0, path: .curve(curviness: 1))), engine: engine)
        XCTAssertTrue(curved.ok)
        let selected = NativeSelectedElementReference(attributes: ["data-studio-clip-id": "clip:first"], datasetStudioClipId: "clip:first")
        guard case .success(let result) = projectNativeTimelineKeyframes(curved.document, selected) else { return XCTFail("projection failed") }
        let lanes = result.groups.flatMap(\.lanes)
        XCTAssertTrue(lanes.contains { $0.parameterId == "transform.position.x" })
        XCTAssertTrue(lanes.contains { $0.parameterId == "transform.position.y" })
        XCTAssertEqual(Set(lanes.map(\.laneId)).count, lanes.count)
    }
}
