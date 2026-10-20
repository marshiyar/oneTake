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
import Foundation
import MpvfxShared
import MpvfxAudioGraph

/// Builds the bus/FX graph project from an open document, mirroring what export feeds the mixer:
/// audio/video clips with a resolvable file (detached-from video clips excluded), clip `audio.volume`,
/// clip mute, `audioGroupId`, clip FX chain + automation, and the sequence's audio groups (volume, mute,
/// FX chain, automation). Stems are decoded by `loadStem` (the media engine in the app, `decodeStem`; synthetic in tests).
public enum DocumentAudioGraph {
    /// What a stem decode depends on; also the cache key, so an edit only re-decodes the clips it changed.
    public struct StemKey: Hashable, Sendable {
        public var path: String, sourceIn: Double, duration: Double, rate: Double
        /// The clip's `preservesPitch`: true plays `rate` as tempo, false resamples so the pitch follows the speed.
        public var preservesPitch: Bool
        public init(path: String, sourceIn: Double, duration: Double, rate: Double, preservesPitch: Bool = true) {
            self.path = path; self.sourceIn = sourceIn; self.duration = duration; self.rate = rate; self.preservesPitch = preservesPitch
        }
    }

    /// Everything in the document the graph depends on. Equal inputs build equal projects, so the session
    /// compares this to decide when to rebuild.
    public struct Inputs: Equatable {
        public var duration: Double
        public var tracks: [Track]
        public var groups: [NativeAudioGroup]
        public struct Track: Equatable {
            public var id: String, stem: StemKey, start: Double, end: Double, volume: Double, muted: Bool
            public var fxChain: String?, automation: String?, groupId: String?
        }
    }

    public static func inputs(_ doc: NativeProjectDocument, duration: Double, projectDir: URL?,
                              fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Inputs {
        let fps = doc.frameRate.numerator / max(doc.frameRate.denominator, 1e-9)
        let assets = Dictionary(doc.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let clips = doc.sequence.tracks.flatMap(\.clips)
        let detached = Set(clips.compactMap { $0.audioDetachedFrom?.isEmpty == false ? $0.audioDetachedFrom : nil })
        var tracks: [Inputs.Track] = []
        for c in clips {
            guard let a = assets[c.assetId], a.kind == .audio || a.kind == .video, let src = a.source else { continue }
            if a.kind == .video && detached.contains(c.id) { continue }
            let path = src.hasPrefix("/") ? src : (projectDir ?? URL(fileURLWithPath: ".")).appendingPathComponent(src).path
            guard fileExists(path) else { continue }
            let start = c.startFrame / fps, end = (c.startFrame + c.durationFrames) / fps
            let rate = c.playbackRate.map { $0.denominator != 0 && $0.numerator > 0 ? $0.numerator / $0.denominator : 1 } ?? 1
            var volume = 1.0
            if case .number(let v)? = c.staticParameters?["audio.volume"] { volume = max(0, v) }
            let stem = StemKey(path: path, sourceIn: c.sourceInFrame / fps, duration: end - start, rate: rate,
                               preservesPitch: c.preservesPitch ?? true)
            tracks.append(.init(id: c.id, stem: stem,
                                start: start, end: end, volume: volume, muted: c.muted,
                                fxChain: c.audioFxChain?.nonEmpty, automation: c.audioAutomation?.nonEmpty, groupId: c.audioGroupId?.nonEmpty))
        }
        return Inputs(duration: duration, tracks: tracks, groups: doc.sequence.audioGroups ?? [])
    }

    /// Unparseable FX chains / automation are dropped (reported through `issues`), never fatal to playback. A stem
    /// `loadStem` cannot decode drops its clip (silent) and reports the decoder's reason.
    public static func project(_ inputs: Inputs, loadStem: (StemKey) throws -> [[Float]], issues: inout [String]) -> AudioGraphProject {
        func chain(_ s: String?, _ who: String) -> FxChain? {
            guard let s else { return nil }
            do { return try AudioFx.parseChain(s) } catch { issues.append("\(who): FX chain ignored (\(error))"); return nil }
        }
        func auto(_ s: String?, _ who: String) -> Automation? {
            guard let s else { return nil }
            do { return try AudioAutomation.parse(s) } catch { issues.append("\(who): automation ignored (\(error))"); return nil }
        }
        let tracks = inputs.tracks.compactMap { t -> AudioGraphTrack? in
            let stem: [[Float]]
            do { stem = try loadStem(t.stem) } catch { issues.append("clip \(t.id): audio not decodable (\(error))"); return nil }
            return AudioGraphTrack(id: t.id, stem: stem, start: t.start, end: t.end, volume: t.volume, muted: t.muted,
                                   fxChain: chain(t.fxChain, "clip \(t.id)"), automation: auto(t.automation, "clip \(t.id)"), groupId: t.groupId)
        }
        let groups = inputs.groups.map { g in
            AudioGraphGroup(id: g.id, volume: g.volume ?? 1, muted: g.muted ?? false,
                            fxChain: chain(g.fxChain?.nonEmpty, "group \(g.id)"), automation: auto(g.automation?.nonEmpty, "group \(g.id)"))
        }
        return AudioGraphProject(duration: inputs.duration, tracks: tracks, groups: groups)
    }

    /// The project with every stem decoded by the media engine at `sampleRate` (stereo): what live playback builds,
    /// and what export renders offline (`AudioGraphRenderer.render(_:from:frames:)`).
    public static func project(_ inputs: Inputs, sampleRate: Int, issues: inout [String]) -> AudioGraphProject {
        var p = project(inputs, loadStem: { try decodeStem($0, sampleRate: sampleRate) }, issues: &issues)
        p.sampleRate = Double(sampleRate)
        return p
    }

    /// Decodes a stem as stereo planes at `sampleRate` through the media engine (`StemDecoder`): seeked to the clip's
    /// source in point, clip rate as tempo (or resampled when the clip lets the pitch follow), read in bounded chunks.
    public static func decodeStem(_ key: StemKey, sampleRate: Int = 48_000) throws -> [[Float]] {
        try StemDecoder.decode(key, sampleRate: sampleRate)
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }
