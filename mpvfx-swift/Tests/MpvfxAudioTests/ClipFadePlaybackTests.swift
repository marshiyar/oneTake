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

/// Clip fades from the document to the speakers and the export (issue #85): a clip's `fadeInFrames` reaches the graph
/// through `DocumentAudioGraph`, which both live playback (`GraphAudioSource` fed block by block by `AudioPlayback`) and
/// export (`ExportAudioMix`: one renderer, `advance(to:)`, then one chunk per video frame) render.
final class ClipFadePlaybackTests: XCTestCase {
    /// 30 fps; one 2 s audio clip at frame 0 with a 1 s (30-frame) fade-in.
    static let json = #"""
    {"schemaVersion":1,"id":"p","revision":1,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":640,"height":360,"background":"#000000"},
     "assets":[{"id":"a","kind":"audio","name":"a.wav","source":"a.wav","durationFrames":300}],
     "sequence":{"id":"s","name":"S","tracks":[{"id":"t","kind":"audio","clips":[
      {"id":"c","assetId":"a","startFrame":0,"durationFrames":60,"sourceInFrame":0,"fadeInFrames":30,"effects":[],"parameterTracks":[]}]}]}}
    """#

    /// Constant 0.5, exact in 16 bits, so every output sample is 0.5 times the fade gain.
    static func loadStem(_ key: DocumentAudioGraph.StemKey) -> [[Float]] {
        let plane = [Float](repeating: 0.5, count: Int((key.duration * 48_000).rounded()))
        return [plane, plane]
    }

    func testClipWithAOneSecondFadeInSoundsTheSameInLivePlaybackAndTheExportMix() throws {
        let doc = try parseNativeProjectDocument(try NativeJSONValue.parse(Self.json))
        let inputs = DocumentAudioGraph.inputs(doc, duration: 2, projectDir: URL(fileURLWithPath: "/proj"), fileExists: { _ in true })
        XCTAssertEqual(inputs.tracks.map(\.fadeIn), [1], "30 frames at 30 fps")
        XCTAssertEqual(inputs.tracks.map(\.fadeOut), [0])
        var issues: [String] = []
        let project = DocumentAudioGraph.project(inputs, loadStem: Self.loadStem, issues: &issues)
        XCTAssertEqual(issues, [])
        let live = try Self.live(project), export = Self.export(project)
        XCTAssertEqual(live.count, project.totalFrames * 2)
        XCTAssertTrue(live == export, "live playback and the export mix are the same samples")
        assertOneSecondFadeIn(live, "live")
        assertOneSecondFadeIn(export, "export")
    }

    /// What the speakers get: `AudioPlayback` pumping 128-frame blocks of a `GraphAudioSource` from 0 s.
    static func live(_ project: AudioGraphProject) throws -> [Float] {
        let source = GraphAudioSource(project: project)
        let output = NullAudioOutput(format: source.format)
        let playback = AudioPlayback(output: output, source: source)
        source.seek(0)
        while output.written.count < project.totalFrames * 2 { try playback.pump() }
        return Array(output.written.prefix(project.totalFrames * 2))
    }

    /// What `ExportAudioMix` muxes: one renderer, `skip(to:)` = `advance(to:)`, then one chunk per video frame.
    static func export(_ project: AudioGraphProject) -> [Float] {
        let renderer = AudioGraphRenderer(project)
        renderer.advance(to: 0)
        var out: [Float] = []
        while renderer.position < project.totalFrames { out += renderer.render(1600) }
        return out
    }

    func assertOneSecondFadeIn(_ mix: [Float], _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(mix[0], 0, "\(name): the first sample is at 0 gain", file: file, line: line)
        XCTAssertEqual(Double(mix[2 * 24_000]) / 0.5, 0.5, accuracy: 1e-4, "\(name): the 0.5 s sample is at 0.5", file: file, line: line)
        XCTAssertEqual((2 * 48_000..<mix.count).filter { mix[$0] != 0.5 }, [], "\(name): full gain from 1 s", file: file, line: line)
    }

    func testAFadeEditChangesTheGraphInputs() throws {
        var doc = try parseNativeProjectDocument(try NativeJSONValue.parse(Self.json))
        let before = DocumentAudioGraph.inputs(doc, duration: 2, projectDir: nil, fileExists: { _ in true })
        doc.sequence.tracks[0].clips[0].fadeOutFrames = 15
        let after = DocumentAudioGraph.inputs(doc, duration: 2, projectDir: nil, fileExists: { _ in true })
        XCTAssertNotEqual(before, after, "a fade edit rebuilds the live graph")
        XCTAssertEqual(after.tracks.first?.fadeOut, 0.5)
    }
}
