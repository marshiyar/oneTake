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

final class MixerGraphTests: XCTestCase {
    func project(_ db: Double = 0, pan: Double = 0) throws -> AudioGraphProject {
        var doc = try GraphPlaybackTests.document()
        doc.sequence.tracks[1].clips[0].audioFxChain = nil
        doc.sequence.tracks[1].clips[0].audioAutomation = nil
        doc.sequence.tracks[1].clips[0].audioGroupId = nil
        doc.sequence.tracks[1].clips[0].staticParameters = nil
        doc.sequence.tracks[1].mixerGainDB = db
        doc.sequence.tracks[1].mixerPan = pan
        let input = DocumentAudioGraph.inputs(doc, duration: 1, projectDir: nil, fileExists: { _ in true })
        var issues: [String] = []
        var p = DocumentAudioGraph.project(input, loadStem: { _ in [[Float](repeating: 0.25, count: 48000), [Float](repeating: 0.25, count: 48000)] }, issues: &issues)
        p.quantizeIntermediates = false
        XCTAssertTrue(issues.isEmpty)
        return p
    }
    func testFaderChangesExportSamplesAndPanRoutesChannels() throws {
        let unity = AudioGraphRenderer(try project()).renderAll()
        let quieter = AudioGraphRenderer(try project(-6)).renderAll()
        let i = try XCTUnwrap(unity.indices.first { abs(unity[$0]) > 0.1 })
        XCTAssertEqual(Double(quieter[i]) / Double(unity[i]), pow(10, -6.0 / 20), accuracy: 0.0001)
        let right = AudioGraphRenderer(try project(0, pan: 1)).renderAll()
        XCTAssertEqual(right[i - i % 2], 0, accuracy: 0.00001)
        XCTAssertGreaterThan(right[i - i % 2 + 1], 0)
    }
    func testMetersUseRenderedBlocksAndDoNotPublishPreroll() throws {
        let p = try project(-6)
        let source = GraphAudioSource(project: p)
        source.seek(0.5)
        XCTAssertTrue(source.meters.isEmpty)
        let out = source.render(frames: 128)
        let meter = try XCTUnwrap(source.meters["t2"])
        let peak = out.map { Double(abs($0)) }.max() ?? 0
        let rms = sqrt(out.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(out.count))
        XCTAssertEqual(meter.peak, peak, accuracy: 0.00001)
        XCTAssertEqual(meter.rms, rms, accuracy: 0.00001)
        source.seek(1)
        _ = source.render(frames: 128)
        XCTAssertEqual(source.meters["t2"]?.peak, 0)
    }
    func testMuteAndSoloChangeRenderedExport() throws {
        var doc = try GraphPlaybackTests.document()
        for i in doc.sequence.tracks.indices {
            for j in doc.sequence.tracks[i].clips.indices {
                doc.sequence.tracks[i].clips[j].audioFxChain = nil
                doc.sequence.tracks[i].clips[j].audioAutomation = nil
                doc.sequence.tracks[i].clips[j].audioGroupId = nil
            }
        }
        func render() -> [Float] {
            let input = DocumentAudioGraph.inputs(doc, duration: 1, projectDir: nil, fileExists: { _ in true })
            var issues: [String] = []
            return AudioGraphRenderer(DocumentAudioGraph.project(input, loadStem: { _ in [[Float](repeating: 0.25, count: 48000), [Float](repeating: 0.25, count: 48000)] }, issues: &issues)).renderAll()
        }
        XCTAssertTrue(render().contains { abs($0) > 0.1 })
        doc.sequence.tracks[1].clips[0].muted = true
        XCTAssertTrue(render().allSatisfy { $0 == 0 })
        var solo = doc.sequence.tracks[1]
        solo.id = "solo"
        solo.soloed = true
        solo.clips = []
        doc.sequence.tracks.append(solo)
        doc.sequence.tracks[1].clips[0].muted = false
        XCTAssertTrue(render().allSatisfy { $0 == 0 }, "soloing an empty track suppresses the other tracks")
        doc.sequence.tracks[1].soloed = true
        XCTAssertTrue(render().contains { abs($0) > 0.1 })
    }
    func testLiveMeterSumsOverlappingClipsOnTheSameTrack() {
        var a = AudioGraphTrack(id: "a", stem: [[Float](repeating: 0.25, count: 128), [Float](repeating: 0.25, count: 128)], start: 0, end: 1)
        a.meterId = "audio"
        var b = a; b.id = "b"
        var p = AudioGraphProject(duration: 1, sampleRate: 48000, tracks: [a, b])
        p.quantizeIntermediates = false
        let source = GraphAudioSource(project: p)
        _ = source.render(frames: 128)
        XCTAssertEqual(source.meters["audio"]?.peak, 0.5)
        XCTAssertEqual(source.meters["audio"]?.rms, 0.5)
    }
    func testMixerStateRoundTripsAndRejectsOutOfRange() throws {
        var doc = try GraphPlaybackTests.document()
        doc.sequence.tracks[1].mixerGainDB = -6
        doc.sequence.tracks[1].mixerPan = 0.25
        let raw = String(decoding: try JSONEncoder().encode(doc), as: UTF8.self)
        let back = try parseNativeProjectDocument(try NativeJSONValue.parse(raw))
        XCTAssertEqual(back.sequence.tracks[1].mixerGainDB, -6)
        XCTAssertEqual(back.sequence.tracks[1].mixerPan, 0.25)
        XCTAssertThrowsError(try parseNativeProjectDocument(try NativeJSONValue.parse(raw.replacingOccurrences(of: #""mixerGainDB":-6"#, with: #""mixerGainDB":100"#))))
    }
}
