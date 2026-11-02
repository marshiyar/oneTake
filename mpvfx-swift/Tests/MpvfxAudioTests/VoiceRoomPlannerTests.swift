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

/// Make room for voice (issues #309 and #310): where the speech is, and what gets written.
final class VoiceRoomPlannerTests: XCTestCase {
    static let sr = 48_000
    static let json = #"""
    {"schemaVersion":1,"id":"p","revision":1,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":640,"height":360,"background":"#000000"},
     "assets":[
      {"id":"av","kind":"audio","name":"Narration.wav","source":"Narration.wav","durationFrames":240},
      {"id":"am","kind":"audio","name":"Music bed.wav","source":"Music.wav","durationFrames":240},
      {"id":"aa","kind":"audio","name":"Room tone.wav","source":"Room.wav","durationFrames":240},
      {"id":"au","kind":"audio","name":"clip 7.wav","source":"Seven.wav","durationFrames":240},
      {"id":"av2","kind":"audio","name":"Second voice.wav","source":"Voice2.wav","durationFrames":240}],
     "sequence":{"id":"s","name":"S","tracks":[
      {"id":"t1","kind":"audio","clips":[{"id":"voice","assetId":"av","startFrame":0,"durationFrames":240,"sourceInFrame":0,"effects":[],"parameterTracks":[]}]},
      {"id":"t2","kind":"audio","clips":[{"id":"music","assetId":"am","startFrame":30,"durationFrames":240,"sourceInFrame":0,"effects":[],"parameterTracks":[]
         AUTOMATION}]},
      {"id":"t3","kind":"audio","clips":[{"id":"room","assetId":"aa","startFrame":0,"durationFrames":240,"sourceInFrame":0,"effects":[],"parameterTracks":[]}]},
      {"id":"t4","kind":"audio","clips":[{"id":"seven","assetId":"au","startFrame":0,"durationFrames":240,"sourceInFrame":0,"effects":[],"parameterTracks":[]}]},
      {"id":"t5","kind":"audio","locked":true,"clips":[{"id":"voice2","assetId":"av2","startFrame":0,"durationFrames":240,"sourceInFrame":0,"effects":[],"parameterTracks":[]}]}]}}
    """#

    func document(automation: String = "") throws -> NativeProjectDocument {
        try parseNativeProjectDocument(try NativeJSONValue.parse(Self.json.replacingOccurrences(of: "AUTOMATION", with: automation)))
    }

    /// 8 s of a 0.25 tone while someone speaks (1 to 3 s and 5 to 6 s), silence otherwise.
    static func speech(_ spans: [Range<Double>] = [1..<3, 5..<6], seconds: Double = 8) -> [[Float]] {
        let plane = (0..<Int(seconds * Double(sr))).map { i -> Float in
            let t = Double(i) / Double(sr)
            return spans.contains { $0.contains(t) } ? Float(0.25 * sin(2 * Double.pi * 440 * t)) : 0
        }
        return [plane, plane]
    }
    static func loader(_ stems: [String: [[Float]]]) -> (DocumentAudioGraph.StemKey) throws -> [[Float]] {
        { key in stems[URL(fileURLWithPath: key.path).lastPathComponent] ?? [[Float](repeating: 0, count: 48_000)] }
    }

    func db(_ automation: String?, at t: Double) throws -> Double {
        let a = try AudioAutomation.parse(try XCTUnwrap(automation))
        return 20 * log10(AudioAutomation.sampleLane(try XCTUnwrap(a.lanes.first { $0.target == "volume" }), t))
    }

    func testSpeechRegionsAreTheComplementOfTheSilences() {
        let regions = VoiceRoomPlanner.speechRegions(silences: [.init(start: 0, end: 1), .init(start: 3, end: 5), .init(start: 6, end: 8)], duration: 8)
        XCTAssertEqual(regions, [SpeechRegion(start: 1, end: 3), SpeechRegion(start: 5, end: 6)])
        XCTAssertEqual(VoiceRoomPlanner.speechRegions(silences: [], duration: 2), [SpeechRegion(start: 0, end: 2)])
        XCTAssertEqual(VoiceRoomPlanner.speechRegions(silences: [.init(start: 0, end: 2)], duration: 2), [])
        XCTAssertEqual(VoiceRoomPlanner.speechRegions(silences: [.init(start: 0.5, end: 1.95)], duration: 2), [SpeechRegion(start: 0, end: 0.5)], "a blip under 0.1 s is dropped")
        let found = VoiceRoomPlanner.speechRegions(Self.speech(), sampleRate: 48_000)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found[0].start, 1, accuracy: 0.02); XCTAssertEqual(found[0].end, 3, accuracy: 0.02)
        XCTAssertEqual(found[1].start, 5, accuracy: 0.02); XCTAssertEqual(found[1].end, 6, accuracy: 0.02)
    }

    // MARK: Volume mode

    func testVolumeModeWritesTaggedPointsInTheBedsOwnTimeAndKeepsHandDrawnOnes() throws {
        let hand = #","audioAutomation":"{\"version\":1,\"lanes\":[{\"target\":\"volume\",\"points\":[{\"t\":7,\"v\":0.5}]}]}""#
        let outcome = try VoiceRoomPlanner.plan(.init(voiceClipIds: ["voice"], bedClipIds: ["music", "room"]), document: try document(automation: hand),
                                                projectDir: nil, fileExists: { _ in true }, loadStem: Self.loader(["Narration.wav": Self.speech()]))
        XCTAssertEqual(outcome.phrases, 2)
        XCTAssertEqual(outcome.beds, 2)
        XCTAssertEqual(outcome.summary, "Lowered 2 clips at 2 phrases")
        let music = try XCTUnwrap(outcome.automation["music"] ?? nil)
        // The music starts 1 s after the voice: the first phrase (1 to 3 s) is 0 to 2 s of the music, the second 4 to 5 s.
        XCTAssertEqual(try db(music, at: 1), -12, accuracy: 0.05)
        XCTAssertEqual(try db(music, at: 3), 0, accuracy: 0.05)
        XCTAssertEqual(try db(music, at: 4.5), -12, accuracy: 0.05)
        XCTAssertEqual(try db(music, at: 5.4), 0, accuracy: 0.05)
        XCTAssertLessThan(try db(music, at: 7), -5, "and the hand-drawn dip at 7 s is still there")
        let lane = try XCTUnwrap(AudioAutomation.parse(music).lanes.first)
        XCTAssertTrue(lane.points.contains { $0.t == 7 && $0.v == 0.5 && $0.origin == nil }, "the hand-drawn point stays")
        XCTAssertTrue(lane.points.filter { $0.t != 7 }.allSatisfy { $0.origin == "voice-room" })
        let room = try XCTUnwrap(outcome.automation["room"] ?? nil)
        XCTAssertEqual(try db(room, at: 2), -12, accuracy: 0.05, "the room tone starts with the voice")
    }

    func testRunningAgainReplacesItsOwnPointsAndTheRequestedAmountApplies() throws {
        var doc = try document()
        let request = VoiceRoomPlanner.Request(settings: .init(amountDb: -20), voiceClipIds: ["voice"], bedClipIds: ["music"])
        let first = try VoiceRoomPlanner.plan(request, document: doc, projectDir: nil, fileExists: { _ in true }, loadStem: Self.loader(["Narration.wav": Self.speech()]))
        let written = try XCTUnwrap(first.automation["music"] ?? nil)
        XCTAssertEqual(try db(written, at: 1), -20, accuracy: 0.05)
        for ti in doc.sequence.tracks.indices { for ci in doc.sequence.tracks[ti].clips.indices where doc.sequence.tracks[ti].clips[ci].id == "music" {
            doc.sequence.tracks[ti].clips[ci].audioAutomation = written
        } }
        let again = try VoiceRoomPlanner.plan(request, document: doc, projectDir: nil, fileExists: { _ in true }, loadStem: Self.loader(["Narration.wav": Self.speech()]))
        XCTAssertEqual(again.automation["music"] ?? nil, written, "the same settings give the same points, not twice as many")
        let shorter = try VoiceRoomPlanner.plan(request, document: doc, projectDir: nil, fileExists: { _ in true }, loadStem: Self.loader(["Narration.wav": Self.speech([1..<2])]))
        let lane = try XCTUnwrap(AudioAutomation.parse(try XCTUnwrap(shorter.automation["music"] ?? nil)).lanes.first)
        XCTAssertEqual(lane.points.filter { $0.origin == "voice-room" }.count, 3, "the old phrases' points are gone")
    }

    func testFailuresSayWhatToDo() throws {
        let load = Self.loader(["Narration.wav": Self.speech()])
        func fail(_ r: VoiceRoomPlanner.Request, _ f: VoiceRoomPlanner.Failure, _ stems: @escaping (DocumentAudioGraph.StemKey) throws -> [[Float]]) throws {
            XCTAssertThrowsError(try VoiceRoomPlanner.plan(r, document: try document(), projectDir: nil, fileExists: { _ in true }, loadStem: stems)) { XCTAssertEqual($0 as? VoiceRoomPlanner.Failure, f) }
        }
        try fail(.init(voiceClipIds: [], bedClipIds: ["music"]), .noVoice, load)
        try fail(.init(voiceClipIds: ["voice"], bedClipIds: []), .noBeds, load)
        try fail(.init(voiceClipIds: ["voice"], bedClipIds: ["music"]), .noSpeech, Self.loader([:]))
        XCTAssertThrowsError(try VoiceRoomPlanner.plan(.init(voiceClipIds: ["voice"], bedClipIds: ["music"]), document: try document(), projectDir: nil,
                                                       fileExists: { _ in true }, loadStem: { _ in throw NSError(domain: "boom", code: 1) })) {
            guard case .unreadable? = $0 as? VoiceRoomPlanner.Failure else { return XCTFail("\($0)") }
        }
        // Speech that no ticked clip plays under is not "no speech".
        try fail(.init(voiceClipIds: ["voice"], bedClipIds: ["music"]), .noBedUnderSpeech, Self.loader(["Narration.wav": Self.speech([0..<0.5], seconds: 0.5)]))
    }

    // MARK: A3, carve mode

    /// Energy of `x` at `hz` (a single-bin DFT over the whole signal), in dB.
    static func levelDb(_ x: [Float], at hz: Double) -> Double {
        var re = 0.0, im = 0.0
        for (i, v) in x.enumerated() {
            let ph = 2 * Double.pi * hz * Double(i) / Double(sr)
            re += Double(v) * cos(ph); im += Double(v) * sin(ph)
        }
        return 10 * log10(max(1e-30, (re * re + im * im) / Double(x.count * x.count)))
    }

    func testA3CarveModeDipsTheVoiceBandsOfTheBedAndLeavesTheRestAlone() throws {
        let n = 4 * Self.sr
        var state: UInt64 = 3
        let noise = (0..<n).map { _ -> Float in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float((Double(state >> 11) / Double(1 << 53) * 2 - 1) * 0.2)
        }
        let voice = (0..<n).map { i -> Float in
            let t = Double(i) / Double(Self.sr)
            return Float(0.25 * sin(2 * Double.pi * 1000 * t) + 0.25 * sin(2 * Double.pi * 2500 * t))
        }
        let request = VoiceRoomPlanner.Request(mode: .carve, settings: .init(amountDb: -12), voiceClipIds: ["voice"], bedClipIds: ["music"])
        let outcome = try VoiceRoomPlanner.plan(request, document: try document(), projectDir: nil, fileExists: { _ in true },
                                                loadStem: Self.loader(["Narration.wav": [voice, voice], "Music.wav": [noise, noise]]))
        XCTAssertEqual(outcome.beds, 1)
        XCTAssertTrue(outcome.automation.isEmpty, "carve writes the chain, not volume points")
        let chain = try AudioFx.parseChain(try XCTUnwrap(outcome.fxChains["music"] ?? nil))
        XCTAssertTrue(!chain.nodes.isEmpty && chain.nodes.allSatisfy { $0.fromCarve == true })
        func render(_ chain: FxChain?) -> [Float] {
            let p = AudioGraphProject(duration: 4, tracks: [AudioGraphTrack(id: "bed", stem: [noise, noise], start: 0, end: 4, fxChain: chain)])
            let mix = AudioGraphRenderer.renderOffline(p)
            return stride(from: 0, to: mix.count, by: 2).map { mix[$0] }
        }
        let dry = render(nil), carved = render(chain)
        for hz in [1000.0, 2500.0] {
            XCTAssertLessThan(Self.levelDb(carved, at: hz) - Self.levelDb(dry, at: hz), -5, "\(hz) Hz is carved out of the bed")
        }
        for hz in [12000.0, 15000.0] {
            XCTAssertEqual(Self.levelDb(carved, at: hz) - Self.levelDb(dry, at: hz), 0, accuracy: 1, "\(hz) Hz is left alone")
        }
        // Playback and export build the chain the same way (FxChainProcessor); the identical render is the check.
        XCTAssertEqual(render(chain), carved)
    }

    func testCarveModeReplacesItsOwnNodesAndKeepsTheBedsOtherEffects() throws {
        var doc = try document()
        let own = FxNode(type: "gain", id: "n1", params: AudioFx.defaultParams("gain"))
        let seed = AudioFx.serializeChain(FxChain(nodes: [own]))
        for ti in doc.sequence.tracks.indices { for ci in doc.sequence.tracks[ti].clips.indices where doc.sequence.tracks[ti].clips[ci].id == "music" {
            doc.sequence.tracks[ti].clips[ci].audioFxChain = seed
        } }
        let request = VoiceRoomPlanner.Request(mode: .carve, voiceClipIds: ["voice"], bedClipIds: ["music"])
        let load = Self.loader(["Narration.wav": Self.speech(), "Music.wav": Self.speech()])
        let first = try VoiceRoomPlanner.plan(request, document: doc, projectDir: nil, fileExists: { _ in true }, loadStem: load)
        for ti in doc.sequence.tracks.indices { for ci in doc.sequence.tracks[ti].clips.indices where doc.sequence.tracks[ti].clips[ci].id == "music" {
            doc.sequence.tracks[ti].clips[ci].audioFxChain = first.fxChains["music"] ?? nil
        } }
        let second = try VoiceRoomPlanner.plan(request, document: doc, projectDir: nil, fileExists: { _ in true }, loadStem: load)
        let chain = try AudioFx.parseChain(try XCTUnwrap(second.fxChains["music"] ?? nil))
        XCTAssertEqual(chain.nodes.filter { $0.fromCarve == true }.count, try AudioFx.parseChain(try XCTUnwrap(first.fxChains["music"] ?? nil)).nodes.filter { $0.fromCarve == true }.count)
        XCTAssertTrue(chain.nodes.contains { $0.type == "gain" && $0.id == "n1" }, "the bed's own effect stays")
        XCTAssertEqual(Set(chain.nodes.compactMap(\.id)).count, chain.nodes.count, "every node has its own id")
    }
}
