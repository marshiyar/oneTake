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

/// Live playback through the bus/FX graph: after any seek, AudioPlayback's output must be bit-identical to the
/// offline renderAll() at the same position.
final class GraphPlaybackTests: XCTestCase {
    static let project = AudioGraphFixtures.everyFX()
    static let offline = AudioGraphRenderer.renderOffline(project)

    /// Seek, then pump `blocks` 128-frame blocks through AudioPlayback into a NullAudioOutput.
    func playAfterSeek(_ source: GraphAudioSource, to t: Double, blocks: Int) throws -> [Float] {
        let out = NullAudioOutput(format: source.format)
        let p = AudioPlayback(output: out, source: source)
        XCTAssertEqual(p.blockFrames, 128)
        p.source.seek(t)
        for _ in 0..<blocks { try p.pump() }
        return out.written
    }

    func slice(_ a: [Float], frame: Int, frames: Int) -> [Float] {
        let lo = min(a.count, frame * 2), hi = min(a.count, (frame + frames) * 2)
        return Array(a[lo..<hi]) + [Float](repeating: 0, count: frames * 2 - (hi - lo))
    }

    func testOutputAfterSeekEqualsOfflineBitIdentical() throws {
        let p = Self.project
        // Unaligned frames, mid-FX-tail, inside automation ramps, before any clip, at and past the end.
        let targets: [Double] = [0, 0.0001, 0.037, 0.31, 0.555555, 0.9, 1.13, 1.39, 1.4, 2]
        for t in targets {
            let src = GraphAudioSource(project: p)
            let got = try playAfterSeek(src, to: t, blocks: 40)
            let frame = min(Int((t * 48000).rounded()), p.totalFrames)
            XCTAssertEqual(src.lastPreRoll?.targetFrame, frame)
            XCTAssertTrue(got == slice(Self.offline, frame: frame, frames: 40 * 128), "seek to \(t) s differs from renderAll")
        }
    }

    func testSeekBackwardAndForwardOnOneSourceStaysExact() throws {
        let src = GraphAudioSource(project: Self.project)
        let out = NullAudioOutput()
        let pb = AudioPlayback(output: out, source: src)
        for t in [0.8, 0.2, 0.6, 0.61, 0.05, 1.2] {
            out.flush()
            src.seek(t)
            let frame = Int((t * 48000).rounded())
            let pre = src.lastPreRoll!
            XCTAssertEqual(pre.targetFrame, frame)
            for _ in 0..<20 { try pb.pump() }
            XCTAssertTrue(out.written == slice(Self.offline, frame: frame, frames: 20 * 128), "seek to \(t)")
        }
    }

    func testForwardSeekContinuesWithoutRestart() {
        let src = GraphAudioSource(project: Self.project)
        src.seek(0.5); src.seek(0.7)
        XCTAssertEqual(src.lastPreRoll?.fromFrame, 24000, "forward seek pre-rolls from the current position")
        src.seek(0.1)
        XCTAssertEqual(src.lastPreRoll?.fromFrame, 0, "backward seek restarts at frame 0")
    }

    func testTransportGainAndMuteApplyAfterMix() {
        let src = GraphAudioSource(project: Self.project)
        src.seek(0.4); src.masterGain = 0.5
        let half = src.render(frames: 256)
        XCTAssertEqual(half, slice(Self.offline, frame: 19200, frames: 256).map { $0 * Float(0.5) })
        src.muted = true
        XCTAssertTrue(src.render(frames: 128).allSatisfy { $0 == 0 })
        src.muted = false; src.masterGain = 1
        XCTAssertTrue(src.render(frames: 128) == slice(Self.offline, frame: 19200 + 384, frames: 128), "mute keeps the graph running")
    }

    func testReplaceProjectPreRollsToCurrentPositionExactly() {
        var edited = Self.project
        edited.tracks[1].volume = 0.4
        edited.groups[0].muted = true
        let editedOffline = AudioGraphRenderer.renderOffline(edited)
        let src = GraphAudioSource(project: Self.project)
        src.seek(0.25)
        _ = src.render(frames: 128 * 10)
        src.replace(edited)
        XCTAssertEqual(src.lastPreRoll?.targetFrame, 12000 + 1280)
        XCTAssertTrue(src.render(frames: 128 * 30) == slice(editedOffline, frame: 13280, frames: 128 * 30))
    }

    /// Pre-roll cost (debug build, so small; release numbers come from MpvfxAudioBench).
    func testPreRollTiming() {
        let p = AudioGraphFixtures.everyFX(seconds: 4)
        let src = GraphAudioSource(project: p)
        src.seek(2)
        let r = src.lastPreRoll!
        XCTAssertEqual(r.framesRendered, 2 * 48000)
        print(String(format: "PREROLL debug: seek to 2 s of the 4 s every-FX project took %.3f s", r.seconds))
    }

    // MARK: document -> graph

    static func document() throws -> NativeProjectDocument {
        let json = #"""
        {"schemaVersion":1,"id":"p","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":640,"height":360,"background":"#000000"},
         "assets":[{"id":"v","kind":"video","name":"v.mp4","source":"v.mp4","durationFrames":300},
                   {"id":"a","kind":"audio","name":"a.wav","source":"a.wav","durationFrames":300},
                   {"id":"i","kind":"image","name":"i.png","source":"i.png","durationFrames":300}],
         "sequence":{"id":"s","name":"S","audioGroups":[{"id":"bus","volume":0.8,"fxChain":"{\"version\":1,\"nodes\":[{\"type\":\"gain\",\"id\":\"g\",\"params\":{\"gain\":-3}}]}"}],
          "tracks":[
          {"id":"t1","kind":"video","clips":[
           {"id":"cv","assetId":"v","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]},
           {"id":"ci","assetId":"i","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]},
          {"id":"t2","kind":"audio","clips":[
           {"id":"ca","assetId":"a","audioGroupId":"bus","audioFxChain":"{\"version\":1,\"nodes\":[{\"type\":\"lowpass\",\"id\":\"l\",\"params\":{\"frequency\":2000,\"poles\":\"1\"}}]}",
            "audioAutomation":"{\"version\":1,\"lanes\":[{\"target\":\"volume\",\"points\":[{\"t\":0,\"v\":0.2},{\"t\":0.5,\"v\":1}]}]}",
            "startFrame":6,"durationFrames":24,"sourceInFrame":3,"muted":false,"effects":[],"parameterTracks":[],
            "staticParameters":{"audio.volume":0.7}},
           {"id":"cd","assetId":"a","audioDetachedFrom":"cv","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":true,"effects":[],"parameterTracks":[]}]}]}}
        """#
        return try parseNativeProjectDocument(try NativeJSONValue.parse(json))
    }

    func testDocumentBuildsGraphAndPlaysExactly() throws {
        let doc = try Self.document()
        let inputs = DocumentAudioGraph.inputs(doc, duration: 1, projectDir: URL(fileURLWithPath: "/proj"), fileExists: { _ in true })
        XCTAssertEqual(inputs.tracks.map(\.id), ["ca", "cd"], "image skipped; video whose audio was detached skipped")
        let ca = inputs.tracks[0]
        XCTAssertEqual(ca.stem, .init(path: "/proj/a.wav", sourceIn: 0.1, duration: 0.8, rate: 1))
        XCTAssertEqual(ca.start, 0.2); XCTAssertEqual(ca.volume, 0.7); XCTAssertEqual(ca.groupId, "bus")
        XCTAssertTrue(inputs.tracks[1].muted)
        var loaded: [DocumentAudioGraph.StemKey] = []
        var issues: [String] = []
        let project = DocumentAudioGraph.project(inputs, loadStem: { k in loaded.append(k); return sineStem(seconds: k.duration) }, issues: &issues)
        XCTAssertEqual(issues, [])
        XCTAssertEqual(loaded.count, 2)
        XCTAssertNotNil(project.tracks[0].fxChain); XCTAssertNotNil(project.tracks[0].automation)
        XCTAssertEqual(project.groups.first?.volume, 0.8); XCTAssertNotNil(project.groups.first?.fxChain)
        let offline = AudioGraphRenderer.renderOffline(project)
        XCTAssertGreaterThan(offline.map { abs($0) }.max()!, 0.01)
        let got = try playAfterSeek(GraphAudioSource(project: project), to: 0.43, blocks: 30)
        XCTAssertTrue(got == slice(offline, frame: 20640, frames: 30 * 128))
    }

    /// Detach / reattach on a clip with no preview binding: the graph hears the sound once either way.
    func testDetachAndReattachKeepOneAudioStream() throws {
        var doc = try Self.document()
        doc.sequence.tracks[1].clips.removeLast()   // the fixture's own detached clip
        let ids = NativeDetachAudioIds(assetId: "va", clipId: "vac", trackId: "vat")
        let detached = try detachNativeVideoAudio(doc, videoClipId: "cv", hasAudioStream: true, ids: ids)
        let inputs = DocumentAudioGraph.inputs(detached, duration: 1, projectDir: URL(fileURLWithPath: "/proj"), fileExists: { _ in true })
        XCTAssertEqual(inputs.tracks.map(\.id), ["ca", "vac"])
        XCTAssertEqual(inputs.tracks[1].stem, .init(path: "/proj/v.mp4", sourceIn: 0, duration: 1, rate: 1))
        XCTAssertFalse(inputs.tracks[1].muted)
        let back = try reattachNativeVideoAudio(detached, audioClipId: "vac")
        XCTAssertEqual(DocumentAudioGraph.inputs(back, duration: 1, projectDir: URL(fileURLWithPath: "/proj"), fileExists: { _ in true }).tracks.map(\.id),
                       ["cv", "ca"])
    }

    func testDocumentEditsChangeInputsAndBadFxIsReported() throws {
        var doc = try Self.document()
        let before = DocumentAudioGraph.inputs(doc, duration: 1, projectDir: nil, fileExists: { _ in true })
        XCTAssertEqual(before, DocumentAudioGraph.inputs(doc, duration: 1, projectDir: nil, fileExists: { _ in true }))
        doc.sequence.audioGroups![0].muted = true
        let after = DocumentAudioGraph.inputs(doc, duration: 1, projectDir: nil, fileExists: { _ in true })
        XCTAssertNotEqual(before, after, "group mute triggers a rebuild")
        doc.sequence.tracks[1].clips[0].audioFxChain = "not json"
        var issues: [String] = []
        let p = DocumentAudioGraph.project(DocumentAudioGraph.inputs(doc, duration: 1, projectDir: nil, fileExists: { _ in true }),
                                           loadStem: { sineStem(seconds: $0.duration) }, issues: &issues)
        XCTAssertNil(p.tracks[0].fxChain)
        XCTAssertEqual(issues.count, 1)
    }
}

func sineStem(seconds: Double) -> [[Float]] {
    let n = Int((seconds * 48000).rounded())
    let p = (0..<n).map { (i: Int) -> Float in Float(0.3 * sin(2 * Double.pi * 330 * Double(i) / 48000)) }
    return [p, p]
}
