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
import Foundation
import MpvfxShared
import MpvfxAudioGraph

/// Make room for voice (issues #309, #310): finds the speech of the voice clips and lowers the beds under it, either as
/// ordinary volume points tagged `voice-room` (`VoiceRoom`) or by carving the bands the voice uses out of each bed's FX
/// chain (`AudioCarve`). Nothing here touches the document: the result says what to write, and the editor writes it as
/// one undo step.
public enum VoiceRoomPlanner {
    public enum Mode: String, Sendable, CaseIterable { case volume, carve }

    public struct Request: Sendable {
        public var mode: Mode
        public var settings: VoiceRoomSettings
        public var voiceClipIds: [String]
        public var bedClipIds: [String]
        public init(mode: Mode = .volume, settings: VoiceRoomSettings = .init(), voiceClipIds: [String], bedClipIds: [String]) {
            self.mode = mode; self.settings = settings; self.voiceClipIds = voiceClipIds; self.bedClipIds = bedClipIds
        }
    }

    /// What to write. A nil value removes the clip's automation or chain.
    public struct Outcome: Equatable, Sendable {
        public var automation: [String: String?] = [:]
        public var fxChains: [String: String?] = [:]
        /// Speech phrases found, after short gaps were merged.
        public var phrases = 0
        /// Beds that were lowered.
        public var beds = 0
        /// The sentence the toast shows.
        public var summary: String {
            "Lowered \(beds) \(beds == 1 ? "clip" : "clips") at \(phrases) \(phrases == 1 ? "phrase" : "phrases")"
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noVoice
        case noBeds
        case noSpeech
        case noVoiceBands
        case unreadable(String)
        public var description: String {
            switch self {
            case .noVoice: return "There is no voice to make room for. Select the voice clips, or name them so they read as voice."
            case .noBeds: return "There are no music or sound clips to lower. Tick the clips to lower in the list."
            case .noSpeech: return "No speech was found in the voice clips, so nothing was lowered."
            case .noVoiceBands: return "The voice has no sound to carve around, so nothing was changed."
            case .unreadable(let why): return "The sound of a clip could not be read: \(why)"
            }
        }
    }

    /// Speech shorter than this is a click or a breath, not a phrase.
    static let minimumSpeech = 0.1
    /// Pauses shorter than this are not gaps between phrases (the sheet's Hold decides how long a dip is kept).
    static let minimumPause = 0.2

    // MARK: Speech

    /// The stretches of `[0, duration]` that are not silence, without the blips shorter than `minimumSpeech`.
    public static func speechRegions(silences: [SilenceRange], duration: Double) -> [SpeechRegion] {
        guard duration.isFinite, duration > 0 else { return [] }
        var out: [SpeechRegion] = []
        var cursor = 0.0
        for s in silences.sorted(by: { $0.start < $1.start }) where s.start.isFinite && s.end.isFinite && s.end > s.start {
            if s.start > cursor { out.append(SpeechRegion(start: cursor, end: min(duration, s.start))) }
            cursor = max(cursor, s.end)
        }
        if cursor < duration { out.append(SpeechRegion(start: cursor, end: duration)) }
        return out.filter { $0.end - $0.start >= minimumSpeech }
    }

    /// Speech regions of decoded stem planes, in seconds from the first sample.
    public static func speechRegions(_ stem: [[Float]], sampleRate: Double) -> [SpeechRegion] {
        let silences = detectSilences(stem, sampleRate: sampleRate, options: .init(minimumSilenceSeconds: minimumPause, paddingSeconds: 0))
        return speechRegions(silences: silences, duration: Double(stem.map(\.count).max() ?? 0) / sampleRate)
    }

    // MARK: The plan

    /// The edits for `request`. `loadStem` decodes a clip's sound (the app's media engine; synthetic in tests).
    public static func plan(_ request: Request, document: NativeProjectDocument, projectDir: URL?, sampleRate: Int = 48_000,
                            loadStem: (DocumentAudioGraph.StemKey) throws -> [[Float]] = { try DocumentAudioGraph.decodeStem($0) }) throws -> Outcome {
        guard !request.voiceClipIds.isEmpty else { throw Failure.noVoice }
        guard !request.bedClipIds.isEmpty else { throw Failure.noBeds }
        let inputs = DocumentAudioGraph.inputs(document, duration: 0, projectDir: projectDir)
        let tracks = Dictionary(inputs.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let clips = Dictionary(document.sequence.tracks.flatMap(\.clips).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let rate = Double(sampleRate)

        // Every voice clip: its speech on the timeline, and (for carve) its sound.
        var regions: [SpeechRegion] = []
        var voiceParts: [AudioCarve.SourcePart] = []
        for id in request.voiceClipIds {
            guard let track = tracks[id], !track.muted else { continue }
            let stem: [[Float]]
            do { stem = try loadStem(track.stem) } catch { throw Failure.unreadable("\(error)") }
            regions += speechRegions(stem, sampleRate: rate).map { SpeechRegion(start: $0.start + track.start, end: $0.end + track.start) }
            if request.mode == .carve { voiceParts.append(.init(samples: mono(stem), offsetSeconds: track.start)) }
        }
        let phrases = VoiceRoom.phraseCount(regions, settings: request.settings)
        guard phrases > 0 else { throw Failure.noSpeech }

        var result = Outcome()
        result.phrases = phrases
        switch request.mode {
        case .volume:
            for id in request.bedClipIds {
                guard let track = tracks[id], let clip = clips[id] else { continue }
                let local = regions.compactMap { r -> SpeechRegion? in
                    let s = max(0, r.start - track.start), e = min(track.end - track.start, r.end - track.start)
                    return e > s ? SpeechRegion(start: s, end: e) : nil
                }
                let existing = clip.audioAutomation.flatMap { try? AudioAutomation.parse($0) }
                let next = VoiceRoom.apply(to: existing, regions: local, settings: request.settings)
                result.automation[id] = next.lanes.isEmpty ? nil : AudioAutomation.serialize(next)
                if !local.isEmpty { result.beds += 1 }
            }
        case .carve:
            let mixed = AudioCarve.mixSources(voiceParts, sampleRate: rate)
            let strength = min(1, max(0, (abs(request.settings.clamped.amountDb) - 2) / 16))
            let bands = AudioCarve.analyseBands(mixed, sampleRate: rate, profile: AudioCarve.profile(strength))
            guard !bands.isEmpty else { throw Failure.noVoiceBands }
            let carve = AudioCarve.bandsToChain(bands).nodes.map { node -> FxNode in
                var n = node; n.fromCarve = true; n.label = "Voice carve"; return n
            }
            for id in request.bedClipIds {
                guard let track = tracks[id], let clip = clips[id] else { continue }
                guard regions.contains(where: { $0.end > track.start && $0.start < track.end }) else { continue }
                var chain = clip.audioFxChain.flatMap { try? AudioFx.parseChain($0) } ?? FxChain()
                chain.nodes.removeAll { $0.fromCarve == true }
                chain.nodes = carve + chain.nodes
                for i in chain.nodes.indices where chain.nodes[i].id == nil { chain.nodes[i].id = chain.mintNodeId() }
                result.fxChains[id] = AudioFx.serializeChain(chain)
                result.beds += 1
            }
        }
        guard result.beds > 0 else { throw Failure.noSpeech }
        return result
    }

    private static func mono(_ stem: [[Float]]) -> [Float] {
        guard let first = stem.first else { return [] }
        guard stem.count > 1 else { return first }
        let n = stem.map(\.count).min() ?? 0
        return (0..<n).map { i in stem.reduce(Float(0)) { $0 + $1[i] } / Float(stem.count) }
    }
}
