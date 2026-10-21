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
import MpvfxAudioGraph
@testable import MpvfxAudio

/// Keyframed clip volume (`audio.volume` keyframes) is heard in live playback as export renders it: both build the
/// graph through `DocumentAudioGraph.project`, which turns the keyframes into a per-sample gain on the clip's stem.
final class KeyframedVolumeParityTests: XCTestCase {
    override func setUpWithError() throws {
        if let e = installDefaultKeyframeEngineAtStartup() { throw e }
    }

    /// One 2 s audio clip at 10 fps; `keys` are (frame, volume) keyframes, linear between them.
    static func document(keys: [(Int, Double)]) throws -> NativeProjectDocument {
        let k = keys.enumerated().map { #"{"id":"k\#($0.offset)","frame":\#($0.element.0),"value":\#($0.element.1),"outgoing":{"type":"linear"}}"# }
        let tracks = keys.isEmpty ? "[]" : #"[{"schemaVersion":1,"id":"t:v","parameterId":"audio.volume","valueType":"number","frameRate":{"numerator":10,"denominator":1},"keyframes":[\#(k.joined(separator: ","))]}]"#
        let json = #"""
        {"schemaVersion":1,"id":"p","revision":1,"frameRate":{"numerator":10,"denominator":1},
         "canvas":{"width":64,"height":32,"background":"#000000"},
         "assets":[{"id":"a","kind":"audio","name":"a.wav","source":"a.wav","durationFrames":20}],
         "sequence":{"id":"s","name":"S","tracks":[{"id":"t","kind":"audio","clips":[
           {"id":"c","assetId":"a","startFrame":0,"durationFrames":20,"sourceInFrame":0,"muted":false,"effects":[],
            "parameterTracks":\#(tracks),"staticParameters":{"audio.volume":0.8}}]}]}}
        """#
        return try parseNativeProjectDocument(try NativeJSONValue.parse(json))
    }

    static func project(_ doc: NativeProjectDocument) -> (AudioGraphProject, [String]) {
        let inputs = DocumentAudioGraph.inputs(doc, duration: 2, projectDir: URL(fileURLWithPath: "/p"), fileExists: { _ in true })
        var issues: [String] = []
        let p = DocumentAudioGraph.project(inputs, loadStem: { sineStem(seconds: $0.duration) }, issues: &issues)
        return (p, issues)
    }

    /// RMS of the left channel over the 0.1 s starting at `seconds`.
    func rms(_ interleaved: [Float], _ seconds: Double) -> Double {
        let a = Int(seconds * 48000), n = 4800
        var s = 0.0
        for k in a..<(a + n) { s += Double(interleaved[2 * k]) * Double(interleaved[2 * k]) }
        return (s / Double(n)).squareRoot()
    }

    func testKeyframedVolumeShapesTheMixTheGraphPlays() throws {
        let (keyed, issues) = Self.project(try Self.document(keys: [(0, 0), (10, 1)]))
        XCTAssertEqual(issues, [])
        let (flat, _) = Self.project(try Self.document(keys: []))
        let k = AudioGraphRenderer.renderOffline(keyed), f = AudioGraphRenderer.renderOffline(flat)
        // The flat clip plays at its static 0.8; the keyframes replace it: 0 at frame 0, 0.55 around 0.55 s, 1 from 1 s.
        XCTAssertLessThan(rms(k, 0) / rms(f, 0), 0.1)
        XCTAssertEqual(rms(k, 0.5) / rms(f, 0.5), 0.55 / 0.8, accuracy: 0.03)
        XCTAssertEqual(rms(k, 1.5) / rms(f, 1.5), 1 / 0.8, accuracy: 0.01)
    }

    func testLivePlaybackOfKeyframedVolumeEqualsTheOfflineRender() throws {
        let (keyed, _) = Self.project(try Self.document(keys: [(0, 1), (5, 0.2), (15, 1)]))
        let offline = AudioGraphRenderer.renderOffline(keyed)
        let src = GraphAudioSource(project: keyed)
        src.seek(0.37)
        let got = src.render(frames: 128 * 40)
        let at = Int((0.37 * 48000).rounded())
        XCTAssertTrue(got == Array(offline[(2 * at)..<(2 * (at + 128 * 40))]))
    }

    func testAKeyframeEditRebuildsTheLiveGraph() throws {
        let a = DocumentAudioGraph.inputs(try Self.document(keys: [(0, 0), (10, 1)]), duration: 2, projectDir: nil, fileExists: { _ in true })
        let b = DocumentAudioGraph.inputs(try Self.document(keys: [(0, 0), (10, 0.5)]), duration: 2, projectDir: nil, fileExists: { _ in true })
        XCTAssertNotEqual(a, b, "moving a volume keyframe must reach the live graph")
    }
}
