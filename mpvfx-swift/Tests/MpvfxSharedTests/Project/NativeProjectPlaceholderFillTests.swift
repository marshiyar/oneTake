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
@testable import MpvfxShared

/// A template's placeholders filled with new media: the clips keep every edit, only their media changes (#332 A3).
final class NativeProjectPlaceholderFillTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func template() throws -> NativeProjectDocument {
        try parseNativeProjectDocument(J("""
        {"schemaVersion":1,"mediaEngine":"native","id":"project:template","revision":0,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":1920,"height":1080,"background":"#101010"},
         "assets":[{"id":"asset:p1","kind":"video","name":"one.mov","durationFrames":300},
                   {"id":"asset:p2","kind":"video","name":"two.mov","durationFrames":300},
                   {"id":"asset:p3","kind":"image","name":"three.png","durationFrames":1},
                   {"id":"asset:keep","kind":"video","name":"logo.mov","durationFrames":300}],
         "sequence":{"id":"sequence:main","name":"Main","tracks":[{"id":"track:video-1","kind":"video","clips":[
           {"id":"clip:1","assetId":"asset:p1","startFrame":0,"durationFrames":90,"sourceInFrame":10,"fadeInFrames":5,"effects":[{"id":"fx:1","effectId":"color-grade","enabled":true,"parameters":{}}],"parameterTracks":[],"placeholder":{"v":1,"index":1,"label":"Intro"}},
           {"id":"clip:2","assetId":"asset:p2","startFrame":90,"durationFrames":60,"sourceInFrame":0,"effects":[],"parameterTracks":[],"placeholder":{"v":1,"index":2}},
           {"id":"clip:3","assetId":"asset:p3","startFrame":150,"durationFrames":60,"sourceInFrame":0,"effects":[],"parameterTracks":[],"placeholder":{"v":1,"index":3}},
           {"id":"clip:4","assetId":"asset:keep","startFrame":210,"durationFrames":30,"sourceInFrame":0,"effects":[],"parameterTracks":[]}]}]}}
        """), engine: engine)
    }
    func media(_ id: String, kind: NativeProjectAssetKind = .video, frames: Double = 300) -> NativeProjectAsset {
        NativeProjectAsset(id: id, kind: kind, name: id, source: "\(id).mov", durationFrames: frames)
    }

    func testFillingThreePlaceholdersKeepsEveryClipAndSwapsOnlyTheMedia() throws {
        let t = try template()
        let filled = try t.fillingPlaceholders([1: media("n1"), 2: media("n2"), 3: media("n3", kind: .image, frames: 1)])
        var expected = t.sequence.tracks[0].clips
        for (i, id) in ["n1", "n2", "n3"].enumerated() { expected[i].assetId = id; expected[i].placeholder = nil }
        XCTAssertEqual(filled.sequence.tracks[0].clips, expected)
        XCTAssertEqual(filled.unfilledPlaceholderNumbers, [])
        XCTAssertEqual(filled.assets.map(\.id), ["asset:keep", "n1", "n2", "n3"], "the template's placeholder media is gone, the unmarked clip's stays")
        XCTAssertEqual(filled.canvas, t.canvas)
        let saved = try serializeNativeProjectDocument(try NativeJSONValue.from(filled), engine: engine)
        XCTAssertEqual(try parseNativeProjectDocument(try NativeJSONValue.parse(saved), engine: engine), filled)
    }

    func testFillingSomePlaceholdersLeavesTheRestMarked() throws {
        let filled = try template().fillingPlaceholders([2: media("n2")])
        XCTAssertEqual(filled.unfilledPlaceholderNumbers, [1, 3])
        XCTAssertEqual(filled.sequence.tracks[0].clips[1].assetId, "n2")
    }

    func testTooShortMediaRefusesEverythingNamingTheMissingFrames() throws {
        let t = try template()
        XCTAssertThrowsError(try t.fillingPlaceholders([1: media("n1"), 2: media("n2", frames: 50)])) { error in
            XCTAssertEqual((error as? NativeProjectClipFailure)?.message, "Replacement media is too short: missing 10 source frames")
        }
    }

    func testAnUnknownPlaceholderNumberIsRefused() throws {
        XCTAssertThrowsError(try template().fillingPlaceholders([7: media("n7")])) { error in
            XCTAssertEqual((error as? NativeProjectClipFailure)?.message, "There is no placeholder 7")
        }
    }
}
