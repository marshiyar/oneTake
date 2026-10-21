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
import MpvfxShared
@testable import MpvfxAudio

/// Track solo (docs/DESIGN.md step 4): while any track is soloed, the clips of every other track leave the mix that
/// live playback and export both build from `DocumentAudioGraph.inputs`.
final class TrackSoloTests: XCTestCase {
    func inputs(_ doc: NativeProjectDocument) -> DocumentAudioGraph.Inputs {
        DocumentAudioGraph.inputs(doc, duration: 1, projectDir: URL(fileURLWithPath: "/proj"), fileExists: { _ in true })
    }

    func testNoSoloLeavesTheMixAlone() throws {
        let doc = try GraphPlaybackTests.document()
        XCTAssertEqual(DocumentAudioGraph.soloSilencedClipIds(doc), [])
        XCTAssertEqual(inputs(doc).tracks.map(\.muted), [false, true], "the fixture's detached clip is muted on its own")
    }

    func testSoloingATrackSilencesEveryOtherTrack() throws {
        var doc = try GraphPlaybackTests.document()
        doc.sequence.tracks[0].soloed = true   // t1: the video track, whose sound was detached onto t2
        XCTAssertEqual(DocumentAudioGraph.soloSilencedClipIds(doc), ["ca", "cd"])
        XCTAssertEqual(inputs(doc).tracks.map(\.muted), [true, true])
        doc.sequence.tracks[1].soloed = true   // both soloed: t2 is heard again
        XCTAssertEqual(DocumentAudioGraph.soloSilencedClipIds(doc), [])
        XCTAssertEqual(inputs(doc).tracks.first { $0.id == "ca" }?.muted, false)
    }

    func testSoloRoundTripsThroughTheDocumentAndIsValidated() throws {
        var doc = try GraphPlaybackTests.document()
        doc.sequence.tracks[1].soloed = true
        let json = String(decoding: try JSONEncoder().encode(doc), as: UTF8.self)
        let back = try parseNativeProjectDocument(try NativeJSONValue.parse(json))
        XCTAssertEqual(back.sequence.tracks[1].soloed, true)
        XCTAssertNil(back.sequence.tracks[0].soloed, "an unsoloed track writes nothing")
        let bad = json.replacingOccurrences(of: #""soloed":true"#, with: #""soloed":"yes""#)
        XCTAssertThrowsError(try parseNativeProjectDocument(try NativeJSONValue.parse(bad)))
    }
}
