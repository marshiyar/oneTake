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
/// audio/video clips with a resolvable file (detached-from video clips excluded), clip `audio.volume` (static, or
/// keyframed: the keyframes replace the static volume as a per-sample gain on the stem, before the FX chain), clip
/// fades, clip mute, `audioGroupId`, clip FX chain + automation, and the sequence's audio groups (volume, mute, FX
/// chain, automation). Export builds its mix with the same functions, so preview and export hear the same volume. Stems
/// are decoded by `loadStem` (the media engine in the app, `decodeStem`; synthetic in tests).
public enum DocumentAudioGraph {
    /// What a stem decode depends on; also the cache key, so an edit only re-decodes the clips it changed.
    public struct StemKey: Hashable, Sendable {
        public var path: String, sourceIn: Double, duration: Double, rate: Double
        public var speedRamp: NativeSpeedRamp?
        public var timelineFPS: Double
        /// The clip's `preservesPitch`: true plays `rate` as tempo, false resamples so the pitch follows the speed.
        public var preservesPitch: Bool
        public init(path: String, sourceIn: Double, duration: Double, rate: Double, preservesPitch: Bool = true,
                    speedRamp: NativeSpeedRamp? = nil, timelineFPS: Double = 30) {
            self.path = path; self.sourceIn = sourceIn; self.duration = duration; self.rate = rate; self.preservesPitch = preservesPitch
            self.speedRamp = speedRamp; self.timelineFPS = timelineFPS
        }
        public static func == (lhs: StemKey, rhs: StemKey) -> Bool {
            lhs.path == rhs.path && lhs.sourceIn == rhs.sourceIn && lhs.duration == rhs.duration && lhs.rate == rhs.rate &&
                lhs.preservesPitch == rhs.preservesPitch && lhs.speedRamp == rhs.speedRamp && lhs.timelineFPS == rhs.timelineFPS
        }
        public func hash(into hasher: inout Hasher) {
            hasher.combine(path); hasher.combine(sourceIn); hasher.combine(duration); hasher.combine(rate)
            hasher.combine(preservesPitch); hasher.combine(timelineFPS)
            hasher.combine(speedRamp)
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
            /// Keyframed `audio.volume` (the clip's first track for it with keyframes; clip-local frames).
            public var volumeKeyframes: VolumeKeyframes? = nil
            /// The clip's `fadeInFrames` / `fadeOutFrames` in seconds (0: none).
            public var fadeIn: Double = 0, fadeOut: Double = 0
        }
    }

    /// What a keyframed clip volume is evaluated from.
    public struct VolumeKeyframes: Equatable, Sendable {
        public var track: NativeParameterTrack
        public var durationFrames: Double, fps: Double
    }

    public static func inputs(_ doc: NativeProjectDocument, duration: Double, projectDir: URL?,
                              fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Inputs {
        let fps = doc.frameRate.numerator / max(doc.frameRate.denominator, 1e-9)
        let assets = Dictionary(doc.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let clips = doc.sequence.tracks.flatMap(\.clips)
        let silenced = soloSilencedClipIds(doc)
        let detached = Set(clips.compactMap { $0.audioDetachedFrom?.isEmpty == false ? $0.audioDetachedFrom : nil })
        var tracks: [Inputs.Track] = []
        for c in clips where !silenced.contains(c.id) {   // solo: the stems of unheard tracks are never decoded
            guard c.speedRamp?.isSupported != false else { continue }
            guard let a = assets[c.assetId], a.kind == .audio || a.kind == .video, let src = a.source else { continue }
            if a.kind == .video && detached.contains(c.id) { continue }
            let path = src.hasPrefix("/") ? src : (projectDir ?? URL(fileURLWithPath: ".")).appendingPathComponent(src).path
            guard fileExists(path) else { continue }
            let start = c.startFrame / fps, end = (c.startFrame + c.durationFrames) / fps
            let rate = c.playbackRate.map { $0.denominator != 0 && $0.numerator > 0 ? $0.numerator / $0.denominator : 1 } ?? 1
            var volume = 1.0
            if case .number(let v)? = c.staticParameters?["audio.volume"] { volume = max(0, v) }
            let stem = StemKey(path: path, sourceIn: c.sourceInFrame / fps, duration: end - start, rate: rate,
                               preservesPitch: c.preservesPitch ?? true, speedRamp: c.speedRamp, timelineFPS: fps)
            let keyed = c.parameterTracks.first { $0.parameterId == volumeParameter && !$0.keyframes.isEmpty }
            tracks.append(.init(id: c.id, stem: stem,
                                start: start, end: end, volume: volume, muted: c.muted,
                                fxChain: c.audioFxChain?.nonEmpty, automation: c.audioAutomation?.nonEmpty, groupId: c.audioGroupId?.nonEmpty,
                                volumeKeyframes: keyed.map { VolumeKeyframes(track: $0, durationFrames: c.durationFrames, fps: fps) },

                                fadeIn: (c.fadeInFrames ?? 0) / fps, fadeOut: (c.fadeOutFrames ?? 0) / fps))
        }
        return Inputs(duration: duration, tracks: tracks, groups: doc.sequence.audioGroups ?? [])
    }

    /// The clips solo leaves out of the mix: while any audio track is soloed, every clip on a track that is not a
    /// soloed audio track. `soloed` on a video or mixed track (which has no solo button) is ignored.
    public static func soloSilencedClipIds(_ doc: NativeProjectDocument) -> Set<String> {
        let soloed = Set(doc.sequence.tracks.filter { $0.kind == .audio && $0.soloed == true }.map(\.id))
        guard !soloed.isEmpty else { return [] }
        return Set(doc.sequence.tracks.filter { !soloed.contains($0.id) }.flatMap(\.clips).map(\.id))
    }

    public static let volumeParameter = "audio.volume"

    /// Unparseable FX chains / automation are dropped (reported through `issues`), never fatal to playback. A stem
    /// `loadStem` cannot decode drops its clip (silent) and reports the decoder's reason. Keyframed clip volume is
    /// evaluated through `engine` (the installed keyframe engine when nil) at `sampleRate`, the rate `loadStem`
    /// decodes at and the returned project runs at; keyframes that cannot be evaluated keep the static volume and are
    /// reported.
    public static func project(_ inputs: Inputs, loadStem: (StemKey) throws -> [[Float]], issues: inout [String],
                               sampleRate: Double = 48_000, engine: KeyframeEngine? = nil) -> AudioGraphProject {
        func chain(_ s: String?, _ who: String) -> FxChain? {
            guard let s else { return nil }
            do { return try AudioFx.parseChain(s) } catch { issues.append("\(who): FX chain ignored (\(error))"); return nil }
        }
        func auto(_ s: String?, _ who: String) -> Automation? {
            guard let s else { return nil }
            do { return try AudioAutomation.parse(s) } catch { issues.append("\(who): automation ignored (\(error))"); return nil }
        }
        var keyframes = KeyframedVolume(engine: engine, sampleRate: sampleRate)
        let tracks = inputs.tracks.compactMap { t -> AudioGraphTrack? in
            var stem: [[Float]]
            do { stem = try loadStem(t.stem) } catch { issues.append("clip \(t.id): audio not decodable (\(error))"); return nil }
            var volume = t.volume
            if let k = t.volumeKeyframes {
                do { try keyframes.apply(k, to: &stem); volume = 1 } catch { issues.append("clip \(t.id): volume keyframes ignored (\(error))") }
            }
            var track = AudioGraphTrack(id: t.id, stem: stem, start: t.start, end: t.end, volume: volume, muted: t.muted,
                                        fxChain: chain(t.fxChain, "clip \(t.id)"), automation: auto(t.automation, "clip \(t.id)"), groupId: t.groupId)
            track.fadeIn = t.fadeIn; track.fadeOut = t.fadeOut
            return track
        }
        let groups = inputs.groups.map { g in
            AudioGraphGroup(id: g.id, volume: g.volume ?? 1, muted: g.muted ?? false,
                            fxChain: chain(g.fxChain?.nonEmpty, "group \(g.id)"), automation: auto(g.automation?.nonEmpty, "group \(g.id)"))
        }
        return AudioGraphProject(duration: inputs.duration, sampleRate: sampleRate, tracks: tracks, groups: groups)
    }

    /// The project with every stem decoded by the media engine at `sampleRate` (stereo): what live playback builds,
    /// and what export renders offline (`AudioGraphRenderer.render(_:from:frames:)`).
    public static func project(_ inputs: Inputs, sampleRate: Int, issues: inout [String]) -> AudioGraphProject {
        var p = project(inputs, loadStem: { try decodeStem($0, sampleRate: sampleRate) }, issues: &issues, sampleRate: Double(sampleRate))
        p.sampleRate = Double(sampleRate)
        return p
    }

    /// Decodes a stem as stereo planes at `sampleRate` through the media engine (`StemDecoder`): seeked to the clip's
    /// source in point, clip rate as tempo (or resampled when the clip lets the pitch follow), read in bounded chunks.
    public static func decodeStem(_ key: StemKey, sampleRate: Int = 48_000) throws -> [[Float]] {
        try StemDecoder.decode(key, sampleRate: sampleRate)
    }
}

/// Keyframed clip volume as a per-sample gain: the track is evaluated at every clip-local project frame (clamped into
/// the clip, fractional frames linear between the two integer frames the engine evaluates), negative values held at
/// 0, and the stem is scaled by the linear interpolation of those per-frame gains. A value that is not a number is a
/// `KeyframedVolumeError`: live playback keeps the static volume and reports it, export fails with it.
struct KeyframedVolume {
    private var engine: KeyframeEngine?
    let sampleRate: Double
    init(engine: KeyframeEngine?, sampleRate: Double) { self.engine = engine; self.sampleRate = sampleRate }

    mutating func apply(_ k: DocumentAudioGraph.VolumeKeyframes, to stem: inout [[Float]]) throws {
        let eng = try engine ?? keyframeEngine()
        engine = eng
        let gains = try Self.frameGains(k, engine: eng)
        let samplesPerFrame = sampleRate / k.fps
        let frames = gains.count
        for c in stem.indices {
            stem[c].withUnsafeMutableBufferPointer { buffer in
                for i in 0..<buffer.count {
                    let pos = Double(i) / samplesPerFrame
                    let lo = Swift.min(frames - 1, Int(pos)), hi = Swift.min(frames - 1, lo + 1)
                    buffer[i] *= Float(gains[lo] + (gains[hi] - gains[lo]) * (pos - Double(lo)))
                }
            }
        }
    }

    /// The gain at clip-local frames 0 ... ceil(duration) (one past the end, for the last frame's interpolation).
    static func frameGains(_ k: DocumentAudioGraph.VolumeKeyframes, engine: KeyframeEngine) throws -> [Double] {
        guard k.durationFrames.isFinite, k.durationFrames >= 0, k.durationFrames <= maxFrames, k.fps.isFinite, k.fps > 0 else {
            throw KeyframedVolumeError(message: "clip length \(k.durationFrames) frames at \(k.fps) fps cannot carry volume keyframes")
        }
        var cache: [Double: NativeParameterValue] = [:]
        func value(_ f: Double) throws -> NativeParameterValue {
            if let v = cache[f] { return v }
            let v = try evaluateNativeParameterTrack(k.track, projectFrame: f, engine: engine)
            cache[f] = v
            return v
        }
        let last = Swift.max(0, k.durationFrames - 1)
        return try (0..<(Int(k.durationFrames.rounded(.up)) + 1)).map { i in
            let f = Swift.min(last, Double(i))
            let lo = f.rounded(.down), hi = f.rounded(.up)
            let a = try value(lo)
            guard let v = Self.number(a, hi == lo ? nil : try value(hi), f - lo) else {
                throw KeyframedVolumeError(message: "audio.volume keyframes evaluate to \(a) at frame \(Int(lo)), not a number")
            }
            return Swift.max(0, v)
        }
    }

    /// Longest clip the gains are evaluated for: 24 hours at 240 fps.
    static let maxFrames = 24 * 3600 * 240.0

    /// The number at `w` between two evaluated values (`b` nil: at `a`); nil when `a` is not a number.
    static func number(_ a: NativeParameterValue, _ b: NativeParameterValue?, _ w: Double) -> Double? {
        guard case .number(let x) = a else { return nil }
        guard case .number(let y)? = b else { return x }
        return x + (y - x) * w
    }
}

/// Keyframed clip volume that cannot be evaluated (a clip length or frame rate outside what the gains cover).
struct KeyframedVolumeError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }
