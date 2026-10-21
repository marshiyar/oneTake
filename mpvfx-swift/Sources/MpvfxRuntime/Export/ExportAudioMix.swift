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
// Audio for export: the same bus/FX graph live playback renders (MpvfxAudioGraph, built from the document by
// DocumentAudioGraph), its stems decoded by the media engine (AudioSampleReader), pulled block by block in step with
// the frames as 48 kHz stereo interleaved Float32 for MediaWriter (stems decoded by DocumentAudioGraph.decodeStem).
// Covers audio groups (volume, mute, FX chain, automation), clip FX chains and automation, static clip volume,
// keyframed clip volume (`audio.volume` tracks, applied by DocumentAudioGraph as a per-sample gain on the clip's stem
// before its FX chain, the same function live playback builds with), clip fades (a linear ramp on the stem before its
// FX chain, carried by DocumentAudioGraph), mute, playback rate (pitch-preserving tempo, or resampled when the clip's
// preservesPitch is false) and source trims.
import Foundation
import MpvfxShared
import MpvfxAudio
import MpvfxAudioGraph

let EXPORT_AUDIO_SAMPLE_RATE = 48_000

/// The export's mix as a stream of interleaved stereo samples from the sequence start. `init` returns nil when no
/// clip contributes sound (every clip muted, or no media with an audio track): the export then has no audio track.
final class ExportAudioMix {
    private let renderer: AudioGraphRenderer

    init?(_ plan: NativeTimelineRenderPlan, engine: KeyframeEngine?, cancellation: MediaCancellation?,
          onProgress: ((Double) -> Void)?) throws {
        let project = plan.project
        let all = DocumentAudioGraph.inputs(project, duration: plan.duration, projectDir: URL(fileURLWithPath: plan.root))
        guard let inputs = exportAudioInputs(all, project, media: plan.media) else { return nil }
        let graph = try Self.decode(inputs, engine: engine, cancellation: cancellation, onProgress: onProgress)
        renderer = AudioGraphRenderer(graph)
        onProgress?(1)
    }

    /// The graph project with every stem decoded. Export never drops what playback would play: an unreadable FX
    /// chain, automation or stem fails the render with the reason.
    private static func decode(_ inputs: DocumentAudioGraph.Inputs, engine: KeyframeEngine?, cancellation: MediaCancellation?,
                               onProgress: ((Double) -> Void)?) throws -> AudioGraphProject {
        var issues: [String] = []
        var decoded = 0
        let total = Double(Swift.max(1, inputs.tracks.count))
        var graph = DocumentAudioGraph.project(inputs, loadStem: { key in
            try cancellation?.throwIfCancelled()
            let stem = try DocumentAudioGraph.decodeStem(key, sampleRate: EXPORT_AUDIO_SAMPLE_RATE)
            decoded += 1
            onProgress?(0.9 * Double(decoded) / total)
            return stem
        }, issues: &issues, sampleRate: Double(EXPORT_AUDIO_SAMPLE_RATE), engine: engine)
        graph.sampleRate = Double(EXPORT_AUDIO_SAMPLE_RATE)
        try cancellation?.throwIfCancelled()
        if !issues.isEmpty { throw MediaToolError("Audio cannot be exported: " + issues.joined(separator: "; ")) }
        return graph
    }

    /// Renders and drops the mix up to sample frame `frame` (the start of a range export).
    func skip(to frame: Int) { renderer.advance(to: frame) }

    /// The next `frames` sample frames, interleaved stereo; silence past the end of the sequence.
    func next(_ frames: Int) throws -> [Float] {
        guard frames > 0 else { return [] }
        var out = renderer.render(frames)
        if out.count < frames * 2 { out += [Float](repeating: 0, count: frames * 2 - out.count) }
        return out
    }
}

/// What the export mixes: the graph inputs of every clip whose media has a sound track (others add nothing and are
/// left out instead of being reported undecodable); nil when no unmuted clip remains, so the export has no audio track.
func exportAudioInputs(_ all: DocumentAudioGraph.Inputs, _ project: NativeProjectDocument,
                       media: [String: NativeMediaInfo]) -> DocumentAudioGraph.Inputs? {
    var inputs = all
    let assetOf = Dictionary(project.sequence.tracks.flatMap(\.clips).map { ($0.id, $0.assetId) }, uniquingKeysWith: { a, _ in a })
    inputs.tracks = inputs.tracks.filter { t in assetOf[t.id].map { media[$0]?.audio == true } ?? false }
    return inputs.tracks.contains(where: { !$0.muted }) ? inputs : nil
}
