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
// Range edit plans. Cases that shrink a keyframed clip slice tracks and
// run against KeyframeRuntime in MpvfxSharedEngineTests (EngineTimelineRangeEditPlanTests).
import XCTest
@testable import MpvfxShared

func rangeEditDocumentJSON(rate: (Int, Int) = (2, 1), binding: Bool = true) -> String {
    let b = binding ? #""binding":{"sourceFile":"index.html","domId":"clip","hfId":"hf-clip"},"# : ""
    return ##"{"schemaVersion":1,"id":"project:range","revision":4,"frameRate":{"numerator":30000,"denominator":1001},"canvas":{"width":1920,"height":1080,"background":"#101010"},"assets":[{"id":"asset:a","kind":"video","name":"a.mov","durationFrames":900}],"sequence":{"id":"sequence:main","name":"Main","tracks":[{"id":"track:v1","kind":"video","clips":[{"id":"clip:a","assetId":"asset:a","##
        + b + ##""startFrame":30,"durationFrames":120,"sourceInFrame":10,"playbackRate":{"numerator":\##(rate.0),"denominator":\##(rate.1)},"muted":true,"staticParameters":{"opacity":0.75},"effects":[{"id":"fx:1","effectId":"blur","enabled":true}],"parameterTracks":[{"schemaVersion":1,"id":"param:rotation","parameterId":"rotation","valueType":"number","frameRate":{"numerator":30000,"denominator":1001},"keyframes":[{"id":"key:0","frame":0,"value":0,"outgoing":{"type":"linear"}},{"id":"key:1","frame":60,"value":180,"outgoing":{"type":"linear"}},{"id":"key:2","frame":90,"value":270,"outgoing":{"type":"hold"}}]}]}]}]}}"##
}
let rangeEditElement = NativeSelectedElementReference(id: "clip", hfId: "hf-clip", sourceFile: "index.html", selector: "#clip", selectorIndex: 0)
func secondsAtFrame(_ f: Double) -> Double { (f * 1001) / 30000 }

final class NativeTimelineRangeEditPlanTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func doc() throws -> NativeProjectDocument { try parseNativeProjectDocument(J(rangeEditDocumentJSON()), engine: engine) }

    func testDeclinesMissingClipWithoutMutating() throws {
        let original = try doc()
        let e = NativeSelectedElementReference(id: "missing", hfId: "missing", sourceFile: "index.html", selector: "#missing", selectorIndex: 0)
        let r = try planNativeTimelineRangeEdit(original, element: e, requestedStartSeconds: secondsAtFrame(30), requestedDurationSeconds: secondsAtFrame(60), engine: engine)
        XCTAssertEqual(r.error?.code, .clipNotFound)
        let c = original.sequence.tracks[0].clips[0]; XCTAssertEqual([c.startFrame, c.durationFrames, c.sourceInFrame], [30, 120, 10])
    }

    func testDeclinesMovingBothBoundaries() throws {
        let r = try planNativeTimelineRangeEdit(try doc(), element: rangeEditElement, requestedStartSeconds: secondsAtFrame(45), requestedDurationSeconds: secondsAtFrame(90), engine: engine)
        XCTAssertEqual(r.error?.code, .unsupportedRangeChange)
    }

    func testMillisecondRoundedStartIsNotASecondTrim() throws {
        let r = try planNativeTimelineRangeEdit(try doc(), element: rangeEditElement, requestedStartSeconds: 1.001 - 0.0001, requestedDurationSeconds: 121 * 1001 / 30000, engine: engine)
        XCTAssertTrue(r.ok); XCTAssertEqual(r.value?.startFrame, 30)
    }
}
