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
// Multi-clip range edit plans. Batches whose first member trims the keyframed
// clip:a run against KeyframeRuntime in MpvfxSharedEngineTests (EngineTimelineMultiRangeEditPlanTests).
import XCTest
@testable import MpvfxShared

func multiRangeProjectJSON(unboundSecond: Bool = false) -> String {
    let b = unboundSecond ? "" : ##""binding":{"sourceFile":"a.html","domId":"clip-b","hfId":"hf-b"},"##
    return ##"{"schemaVersion":1,"id":"project:multi-range","revision":12,"frameRate":{"numerator":30000,"denominator":1001},"canvas":{"width":1920,"height":1080,"background":"#101010"},"assets":[{"id":"asset:a","kind":"video","name":"a.mov","durationFrames":900},{"id":"asset:b","kind":"video","name":"b.mov","durationFrames":900}],"sequence":{"id":"sequence:main","name":"Main","tracks":[{"id":"track:v1","kind":"video","lane":{"authoredTrack":2,"displayTrack":0},"clips":[{"id":"clip:a","assetId":"asset:a","binding":{"sourceFile":"z.html","domId":"clip-a","hfId":"hf-a"},"startFrame":30,"durationFrames":120,"sourceInFrame":10,"playbackRate":{"numerator":2,"denominator":1},"muted":true,"staticParameters":{"opacity":0.75},"effects":[{"id":"fx:a","effectId":"blur","enabled":true}],"parameterTracks":[{"schemaVersion":1,"id":"param:a","parameterId":"transform.rotation","valueType":"number","frameRate":{"numerator":30000,"denominator":1001},"keyframes":[{"id":"key:a0","frame":0,"value":0,"outgoing":{"type":"linear"}},{"id":"key:a1","frame":60,"value":180,"outgoing":{"type":"hold"}}]}]},{"id":"clip:b","assetId":"asset:b","##
        + b + ##""startFrame":180,"durationFrames":90,"sourceInFrame":20,"playbackRate":{"numerator":2,"denominator":1},"muted":false,"staticParameters":{"scale":1.25},"effects":[{"id":"fx:b","effectId":"grade","enabled":false}],"parameterTracks":[]}]}]}}"##
}

final class NativeTimelineMultiRangeEditPlanTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func testRejectsAmbiguousAndInvalidMembers() throws {
        var base = try parseNativeProjectDocument(J(multiRangeProjectJSON()), engine: engine)
        base.sequence.tracks[0].clips[1].binding?.sourceFile = "z.html"
        let ambiguousDocument = try parseNativeProjectDocument(base, engine: engine)
        let ambiguous = try planNativeTimelineMultiRangeEdit(ambiguousDocument, changes: [.init(element: .init(id: "clip-a", hfId: "hf-b", sourceFile: "z.html"),
            requestedStartSeconds: secondsAtFrame(45), requestedDurationSeconds: secondsAtFrame(105))], engine: engine)
        XCTAssertEqual(ambiguous.error?.code, .ambiguousClip); XCTAssertEqual(ambiguous.error?.changeIndex, 0)
        let invalid = try planNativeTimelineMultiRangeEdit(try parseNativeProjectDocument(J(multiRangeProjectJSON()), engine: engine), changes: [.init(
            element: .init(id: "clip-a", hfId: "hf-a", sourceFile: "z.html"), requestedStartSeconds: secondsAtFrame(45) + 1e-12, requestedDurationSeconds: .nan)], engine: engine)
        XCTAssertEqual(invalid.error?.code, .invalidRange); XCTAssertEqual(invalid.error?.changeIndex, 0)
    }
}
