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
// Split plans. The two successful splits slice keyframes and
// run against KeyframeRuntime in MpvfxSharedEngineTests (EngineTimelineSplitPlanTests).
import XCTest
@testable import MpvfxShared

let splitPlanFixtureJSON = #"""
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
let splitPlanFirst = NativeTimelineSplitRequest(element: .init(.init(id: "clip", sourceFile: "a.html")), requestedSplitSeconds: (60.0 * 1001) / 30000,
                                                rightBinding: .init(sourceFile: "a.html", domId: "clip-split-2"))

final class NativeTimelineSplitPlanTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func project() throws -> NativeProjectDocument { try parseNativeProjectDocument(J(splitPlanFixtureJSON), engine: engine) }

    func testRejectsWithoutMutating() throws {
        var expanded = splitPlanFirst; expanded.element.expandedParentStart = 2
        var nested = splitPlanFirst; nested.element.parentCompositionId = "scene"
        var edge = splitPlanFirst; edge.requestedSplitSeconds = (30.0 * 1001) / 30000
        var wrong = splitPlanFirst; wrong.rightBinding = .init(sourceFile: "b.html", domId: "new")
        let cases: [([NativeTimelineSplitRequest], NativeTimelineSplitPlanFailureCode)] = [
            ([], .emptySplitSet), ([expanded], .ambiguousLocalTime), ([nested], .ambiguousLocalTime), ([edge], .nativeCommandRejected), ([wrong], .rightBindingSourceMismatch)]
        for (splits, code) in cases {
            let original = try project()
            XCTAssertEqual(try planNativeTimelineSplits(original, splits: splits, engine: engine).error?.code, code)
            XCTAssertEqual(original, try project())
        }
    }

    func testRejectsDuplicateResolvedClips() throws {
        let original = try project()
        let dup = NativeTimelineSplitRequest(element: .init(.init(sourceFile: "a.html", attributes: ["data-studio-clip-id": "native:a"])),
                                             requestedSplitSeconds: splitPlanFirst.requestedSplitSeconds, rightBinding: .init(sourceFile: "a.html", domId: "another-right"))
        XCTAssertEqual(try planNativeTimelineSplits(original, splits: [splitPlanFirst, dup], engine: engine).error?.code, .duplicateClip)
        XCTAssertEqual(original.sequence.tracks[0].clips.count, 2)
    }
}
