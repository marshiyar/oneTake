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
// Crop-pivot segments.
// parseNativeProjectDocument is not ported yet, so the document is built directly
// with the fields the parser would materialize.
import XCTest
@testable import MpvfxShared

final class NativeCropPivotSegmentsTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func rotation(_ points: [(String, Double)]) -> NativeParameterTrack {
        try! createNativeParameterTrack(.init(id: "rotation", parameterId: "transform.rotation", valueType: .number,
            frameRate: .init(numerator: 30, denominator: 1),
            keyframes: points.map { NativeKeyframe(id: $0.0, frame: $0.1, value: .number($0.1), outgoing: .linear) }), engine: engine)
    }
    let marker = NativeCropPivotSegment(startRotationKeyId: "a", endRotationKeyId: "b", offsetFraction: .init(x: 0.05, y: -0.1), reference: nil)
    func seg(_ a: String, _ b: String, _ ref: NativeCropPivotSegment.Reference? = nil, _ off: Vec2Value? = nil) -> NativeCropPivotSegment {
        .init(startRotationKeyId: a, endRotationKeyId: b, offsetFraction: off ?? marker.offsetFraction, reference: ref)
    }
    lazy var clip = NativeProjectClip(id: "", assetId: "", startFrame: 0, durationFrames: 91, sourceInFrame: 0, muted: false,
        cropPivotSegments: [marker], effects: [], parameterTracks: [rotation([("a", 0), ("b", 90)])])
    lazy var reference = NativeCropPivotSegment.Reference(frameOffset: 0, durationFrames: 91, startRotationKeyId: "a", endRotationKeyId: "b",
        parameterTracks: clip.parameterTracks, staticParameters: nil)

    func testReplacesOlderIntervalWhenNewKeySplitsIt() {
        let c = NativeProjectClip(id: "clip", assetId: "asset", startFrame: 0, durationFrames: 91, sourceInFrame: 0, muted: false,
            staticParameters: [:], cropPivotSegments: [marker], effects: [], parameterTracks: [rotation([("a", 0), ("middle", 45), ("b", 90)])])
        let document = NativeProjectDocument(schemaVersion: 1, id: "project", revision: 0, frameRate: .init(numerator: 30, denominator: 1),
            canvas: .init(width: 200, height: 100, background: "black"),
            assets: [.init(id: "asset", kind: .element, name: "shape", durationFrames: 91)],
            sequence: .init(id: "sequence", name: "Main", tracks: [.init(id: "track", kind: .video, lane: .init(authoredTrack: 0, displayTrack: 0), clips: [c])]))
        let updated = markNativeCropPivotIntervals(document, clipId: "clip", localFrame: 45, offsetFraction: .init(x: 0.1, y: 0))
        XCTAssertEqual(updated.sequence.tracks[0].clips[0].cropPivotSegments,
                       [seg("a", "middle", nil, .init(x: 0.1, y: 0)), seg("middle", "b", nil, .init(x: 0.1, y: 0))])
        XCTAssertEqual(document.sequence.tracks[0].clips[0].cropPivotSegments, [marker])
    }

    func testMapsIntervalOntoTrimAndSplitBoundaryKeys() {
        XCTAssertEqual(rebaseNativeCropPivotSegments(clip, rebasedTracks: [rotation([("a", 0), ("cut-left", 59)])], fromFrame: 0, untilFrameExclusive: 60),
                       [seg("a", "cut-left", reference)])
        var shifted = reference; shifted.frameOffset = 60
        XCTAssertEqual(rebaseNativeCropPivotSegments(clip, rebasedTracks: [rotation([("cut-right", 0), ("b", 30)])], fromFrame: 60, untilFrameExclusive: 91),
                       [seg("cut-right", "b", shifted)])
        XCTAssertEqual(rebaseNativeCropPivotSegments(clip, rebasedTracks: [rotation([("b", 0)])], fromFrame: 90, untilFrameExclusive: 91), [])
    }

    func testRemapsKeyIdsAndRetiresOnDeletion() {
        let map = ["a": "copy-a", "b": "copy-b"]
        XCTAssertEqual(remapNativeCropPivotKeyIds([marker], keyIdMap: map), [seg("copy-a", "copy-b")])
        XCTAssertEqual(remapNativeCropPivotKeyIds([seg("a", "b", reference)], keyIdMap: map), [seg("copy-a", "copy-b", reference)])
        XCTAssertEqual(validNativeCropPivotSegments([marker], tracks: [rotation([("a", 0)])]), [])
        XCTAssertEqual(validNativeCropPivotSegments([marker], tracks: [rotation([("b", 0), ("a", 90)])]), [])
    }

    func testRetiresSlicedSnapshotWhenGeometryEdited() {
        let sliced = [seg("a", "b", reference)]
        XCTAssertEqual(currentNativeCropPivotReferences(sliced, before: clip.parameterTracks, after: clip.parameterTracks), sliced)
        XCTAssertEqual(currentNativeCropPivotReferences(sliced, before: clip.parameterTracks, after: [rotation([("a", 0), ("b", 80)])]), [marker])
    }
}
