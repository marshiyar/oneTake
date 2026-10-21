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

// The bus/FX graph: one model rendered the same way for live playback (block
// API) and offline export (pull the whole range). It runs the export mix
// pipeline (the audio mixer and the FX render) stage by
// stage, sample for sample:
//
//   stem (stereo f32 @ 48k)
//     -> pcm_s16le prepare            q = clip16(lrintf(x * 32768))
//     -> track FX chain (native DSP)   input q/32768, blocks aligned to stem frame 0,
//                                     length N + ceil(tail * sr)
//     -> envelope bake (float) + s16  round(clamp(y*g, -1, 1) * 32767)
//        (or, with no chain, round(q * g) on the s16 file)
//     -> track input filter           atrim, volume (float), adelay (ms), apad, atrim
//     -> group sub-mix                amix normalize=0 (plain float sum) -> f32
//     -> group FX chain + envelope    float in, float out, blocks aligned to comp 0
//     -> final amix                   Σ x_i * fl(1/N), then * N (float)
//
// Pan does not exist in the original; it is offered here as an opt-in
// (equal-power, applied after volume) and is a no-op at its default 0.

public struct AudioGraphTrack: Sendable {
    public var id: String
    /// Stereo planes at the graph's sample rate.
    public var stem: [[Float]]
    public var start: Double
    public var end: Double
    public var volume: Double
    public var pan: Double
    public var muted: Bool
    public var fxChain: FxChain?
    public var automation: Automation?
    public var groupId: String?
    /// Fade-in and fade-out lengths in seconds (0: none): a linear gain ramp on the stem before the FX chain,
    /// multiplied with the volume and its automation (`ClipFadeRamp`). Set after `init`.
    public var fadeIn: Double = 0
    public var fadeOut: Double = 0
    public init(id: String, stem: [[Float]], start: Double, end: Double, volume: Double = 1, pan: Double = 0, muted: Bool = false,
                fxChain: FxChain? = nil, automation: Automation? = nil, groupId: String? = nil) {
        self.id = id; self.stem = stem; self.start = start; self.end = end; self.volume = volume; self.pan = pan; self.muted = muted
        self.fxChain = fxChain; self.automation = automation; self.groupId = groupId
    }
}

public struct AudioGraphGroup: Sendable {
    public var id: String
    public var volume: Double
    public var pan: Double
    public var muted: Bool
    public var fxChain: FxChain?
    public var automation: Automation?
    public init(id: String, volume: Double = 1, pan: Double = 0, muted: Bool = false, fxChain: FxChain? = nil, automation: Automation? = nil) {
        self.id = id; self.volume = volume; self.pan = pan; self.muted = muted; self.fxChain = fxChain; self.automation = automation
    }
}

public struct AudioGraphProject: Sendable {
    public var duration: Double
    public var sampleRate: Double
    public var tracks: [AudioGraphTrack]
    public var groups: [AudioGraphGroup]
    /// Emulate the original's pcm_s16le intermediates (default; required for parity).
    public var quantizeIntermediates: Bool
    public init(duration: Double, sampleRate: Double = 48000, tracks: [AudioGraphTrack], groups: [AudioGraphGroup] = [], quantizeIntermediates: Bool = true) {
        self.duration = duration; self.sampleRate = sampleRate; self.tracks = tracks; self.groups = groups; self.quantizeIntermediates = quantizeIntermediates
    }
    public var totalFrames: Int { Int((duration * sampleRate).rounded()) }
}

// MARK: numeric helpers matching the original's export filters / Node

@inline(__always) func f32ToS16(_ x: Float) -> Int16 {
    let v = (x * 32768).rounded(.toNearestOrEven)
    return Int16(max(-32768, min(32767, v.isNaN ? 0 : v)))
}
@inline(__always) func s16ToF32(_ s: Int16) -> Float { Float(s) * (1 / 32768) }
/// writeWav's s16 branch: Math.round(clamp(v) * 32767).
@inline(__always) func writeWavS16(_ v: Float) -> Int16 {
    let c = Double(max(-1, min(1, v)))
    return Int16(jsMathRound(c * 32767))
}
@inline(__always) func scaleS16(_ s: Int16, _ gain: Double) -> Int16 {
    let r = jsMathRound(Double(s) * gain)
    return Int16(r < -32768 ? -32768 : r > 32767 ? 32767 : r)
}
/// Seconds -> frame count the way the export filters parse a duration (microseconds, then rescaled to
/// 1/sr), so recorded reference mixes line up sample for sample.
func filterFrames(_ seconds: Double, _ sr: Double) -> Int {
    let us = (seconds * 1e6).rounded()
    return Int((us * sr / 1e6).rounded())
}
/// A volume as the original wrote it into its filter string and read it back (shortest number text).
func filterVolume(_ v: Double) -> Float {
    Float(jsStringToNumber(formatFilterNumber(max(0, min(AudioAutomation.maxAudioGain, v)))))
}

// MARK: pull stages

/// Anything that yields stereo frames strictly in order.
protocol FrameSource: AnyObject {
    /// Produce `count` frames starting at the next unread frame into `l`/`r`.
    func pull(_ count: Int, _ l: inout [Float], _ r: inout [Float], _ offset: Int)
}

/// Runs an FX chain in 128-frame quanta over an upstream sequence, FIFO-buffered,
/// so any block size yields the identical stream.
final class ChainStage {
    let chain: FxChainProcessor
    let upstream: (Int, inout [Float], inout [Float]) -> Void // fills exactly n frames
    var fifoL: [Float] = [], fifoR: [Float] = [], head = 0
    var frame = 0 // context frame of the next quantum
    var skip: Int // latency frames still to drop from the start, so the output stays aligned with the input
    init(_ chain: FxChainProcessor, upstream: @escaping (Int, inout [Float], inout [Float]) -> Void) {
        self.chain = chain; self.upstream = upstream; skip = chain.latencyFrames
    }
    func next(_ count: Int, _ l: inout [Float], _ r: inout [Float], _ offset: Int) {
        var written = 0
        while written < count {
            if head >= fifoL.count {
                var a = [Float](repeating: 0, count: dspBlockSize), b = a
                upstream(dspBlockSize, &a, &b)
                let y = chain.process([a, b], frame: frame)
                frame += dspBlockSize
                fifoL = y[0]; fifoR = y[1]; head = 0
                if skip > 0 { let drop = min(skip, fifoL.count); head = drop; skip -= drop; continue }
            }
            let take = min(count - written, fifoL.count - head)
            for k in 0..<take { l[offset + written + k] = fifoL[head + k]; r[offset + written + k] = fifoR[head + k] }
            head += take; written += take
        }
    }
}

/// One clip as it enters the mixer: everything up to and including the original's
/// track-input filter, emitting composition-time frames.
final class TrackStage: FrameSource {
    let startFrame: Int
    let length: Int           // frames of the processed file that survive atrim
    /// In-place editable (AudioGraphRenderer.applyParameterEdits) unless baked; glides once the stage has played.
    var volume: LiveGain
    /// The volume lives in the envelope walker (automation), so `volume` is fixed at 1.
    let bakedVolume: Bool
    /// The clip's FX chain as built (nil: no enabled nodes), for in-place parameter edits.
    let proc: FxChainProcessor?
    let panGains: (Float, Float)?
    var produced = 0          // composition frames emitted
    var local = 0             // processed-file frames consumed
    let fileFrame: (inout Float, inout Float) -> Void

    init(_ t0: AudioGraphTrack, sampleRate sr: Double, quantize: Bool) {
        var t = t0
        t.automation = t0.automation.map { AudioAutomation.resolve($0, t0.fxChain) }
        let dur = t.end - t.start
        let stemFrames = t.stem.first?.count ?? 0
        let n = min(stemFrames, filterFrames(dur, sr))
        let stemL = t.stem[0], stemR = t.stem.count > 1 ? t.stem[1] : t.stem[0]
        let prepared = ClipFadeRamp(t, sampleRate: sr).applied(to: quantize
            ? { i in i < n ? (s16ToF32(f32ToS16(stemL[i])), s16ToF32(f32ToS16(stemR[i]))) : (0, 0) }
            : { i in i < n ? (stemL[i], stemR[i]) : (0, 0) })
        let chain = t.fxChain.flatMap { $0.enabledNodes.isEmpty ? nil : $0 }
        let tail = t.fxChain.map { FxTail.chainSeconds($0, t.automation) } ?? 0
        let laneKf = t.automation.flatMap { VolumeEnvelope.laneKeyframes($0, trackStart: t.start, duration: dur) }
        var walker = laneKf.flatMap { $0.isEmpty ? nil : VolumeEnvelope.walker($0, trackStart: t.start, baseVolume: t.volume) }
        let baked = walker != nil
        var fileLength = n
        let inv = 1 / sr
        if let chain, n > 0 {
            fileLength = n + Int((tail * sr).rounded(.up))
            let proc = FxChainProcessor(chain, automation: t.automation, sampleRate: sr)
            self.proc = proc
            var idx = 0
            let stage = ChainStage(proc) { count, a, b in
                for k in 0..<count { (a[k], b[k]) = prepared(idx); idx += 1 }
            }
            var f = 0
            var l1 = [Float](repeating: 0, count: 1), r1 = l1
            fileFrame = { l, r in
                stage.next(1, &l1, &r1, 0)
                var y = (l1[0], r1[0])
                if walker != nil { let g = walker!.gain(at: Double(f) * inv); y = (Float(Double(y.0) * g), Float(Double(y.1) * g)) }
                f += 1
                if quantize { l = s16ToF32(writeWavS16(y.0)); r = s16ToF32(writeWavS16(y.1)) } else { l = y.0; r = y.1 }
            }
        } else {
            proc = nil
            var f = 0
            fileFrame = { l, r in
                var (a, b) = prepared(f)
                if walker != nil {
                    let g = walker!.gain(at: Double(f) * inv)
                    if quantize { a = s16ToF32(scaleS16(f32ToS16(a), g)); b = s16ToF32(scaleS16(f32ToS16(b), g)) }
                    else { a = Float(Double(a) * g); b = Float(Double(b) * g) }
                }
                f += 1
                l = a; r = b
            }
        }
        length = min(fileLength, filterFrames(dur + tail, sr))
        volume = LiveGain(filterVolume(baked ? 1 : t.volume))
        bakedVolume = baked
        startFrame = Int(jsMathRound(t.start * 1000)) * Int(sr) / 1000
        panGains = equalPower(t.pan)
    }

    func pull(_ count: Int, _ l: inout [Float], _ r: inout [Float], _ offset: Int) {
        for k in 0..<count {
            let c = produced + k
            let g = volume.next()
            var a: Float = 0, b: Float = 0
            if c >= startFrame && local < length {
                fileFrame(&a, &b); local += 1
                a *= g; b *= g
                if let (gl, gr) = panGains { a *= gl; b *= gr }
            }
            l[offset + k] = a; r[offset + k] = b
        }
        produced += count
    }
}

@inline(__always) func finiteOrZero(_ x: Float) -> Float { x.isFinite ? x : 0 }

/// A fader the live edit moves: before the stage has played, `set` assigns (the stage then renders exactly as one
/// built with the value); afterwards it glides there linearly over `frames` frames.
struct LiveGain {
    private(set) var value: Float
    private var glide: LiveGlide?
    private var played = false
    init(_ value: Float) { self.value = value }
    mutating func set(_ v: Float, frames: Int) {
        guard played, frames > 0, v != value || glide != nil else { value = v; glide = nil; return }
        glide = LiveGlide(from: value, to: v, frames: frames)
    }
    /// The gain for the next frame.
    @inline(__always) mutating func next() -> Float {
        played = true
        guard var g = glide else { return value }
        value = g.next()
        glide = g.finished ? nil : g
        return value
    }
}

/// A clip's fades as a gain per stem frame: linear from 0 at the clip start to 1 after `fadeIn` seconds, and from 1
/// to 0 at the clip end over `fadeOut`, multiplied and clamped (the same ramp as `NativeClipFade.gain`).
struct ClipFadeRamp {
    let inFrames: Double, outFrames: Double, endFrame: Double
    init(_ track: AudioGraphTrack, sampleRate sr: Double) {
        inFrames = track.fadeIn.isFinite ? max(0, track.fadeIn) * sr : 0
        outFrames = track.fadeOut.isFinite ? max(0, track.fadeOut) * sr : 0
        endFrame = (track.end - track.start) * sr
    }
    var isUnity: Bool { inFrames <= 0 && outFrames <= 0 }
    /// `frame` with the ramp applied; `frame` itself when there is no fade, so an unfaded clip renders as before.
    func applied(to frame: @escaping (Int) -> (Float, Float)) -> (Int) -> (Float, Float) {
        if isUnity { return frame }
        return { i in
            let (a, b) = frame(i)
            let g = gain(atFrame: i)
            return (a * g, b * g)
        }
    }
    func gain(atFrame i: Int) -> Float {
        let x = Double(i)
        let up = inFrames > 0 ? min(1, max(0, x / inFrames)) : 1
        let down = outFrames > 0 ? min(1, max(0, (endFrame - x) / outFrames)) : 1
        return Float(up * down)
    }
}

func equalPower(_ pan: Double) -> (Float, Float)? {
    if pan == 0 || !pan.isFinite { return nil }
    let p = max(-1, min(1, pan))
    let angle = (p + 1) * Double.pi / 4
    return (Float(cos(angle) * 2.0.squareRoot()), Float(sin(angle) * 2.0.squareRoot()))
}

/// A bus: amix normalize=0 of its members, its FX chain and envelope, then the
/// track-input filter of the final mix (start 0, volume = fader unless baked).
final class GroupStage: FrameSource {
    let members: [TrackStage]
    var volume: LiveGain      // in-place editable unless baked
    let bakedVolume: Bool
    var proc: FxChainProcessor?
    let panGains: (Float, Float)?
    var source: (Int, inout [Float], inout [Float], Int) -> Void = { _, _, _, _ in }

    init(_ g0: AudioGraphGroup, members: [TrackStage], duration: Double, sampleRate sr: Double) {
        var g = g0
        g.automation = g0.automation.map { AudioAutomation.resolve($0, g0.fxChain) }
        self.members = members
        let chain = g.fxChain.flatMap { $0.enabledNodes.isEmpty ? nil : $0 }
        let kf = g.automation.flatMap { VolumeEnvelope.laneKeyframes($0, trackStart: 0, duration: duration) }
        var walker = kf.flatMap { $0.isEmpty ? nil : VolumeEnvelope.walker($0, trackStart: 0, baseVolume: g.volume) }
        volume = LiveGain(filterVolume(walker != nil ? 1 : g.volume))
        bakedVolume = walker != nil
        panGains = equalPower(g.pan)
        let members = self.members
        let submix: (Int, inout [Float], inout [Float], Int) -> Void = { count, l, r, off in
            var tl = [Float](repeating: 0, count: count), tr = tl
            for k in 0..<count { l[off + k] = 0; r[off + k] = 0 }
            for m in members {
                m.pull(count, &tl, &tr, 0)
                for k in 0..<count { l[off + k] += tl[k]; r[off + k] += tr[k] }
            }
        }
        let inv = 1 / sr
        var f = 0
        if let chain {
            let proc = FxChainProcessor(chain, automation: g.automation, sampleRate: sr)
            self.proc = proc
            let stage = ChainStage(proc) { count, a, b in submix(count, &a, &b, 0) }
            source = { count, l, r, off in
                stage.next(count, &l, &r, off)
                if walker != nil { for k in 0..<count { let gn = walker!.gain(at: Double(f + k) * inv); l[off + k] = Float(Double(l[off + k]) * gn); r[off + k] = Float(Double(r[off + k]) * gn) } }
                f += count
            }
        } else {
            source = { count, l, r, off in
                submix(count, &l, &r, off)
                if walker != nil { for k in 0..<count { let gn = walker!.gain(at: Double(f + k) * inv); l[off + k] = Float(Double(l[off + k]) * gn); r[off + k] = Float(Double(r[off + k]) * gn) } }
                f += count
            }
        }
    }

    func pull(_ count: Int, _ l: inout [Float], _ r: inout [Float], _ offset: Int) {
        source(count, &l, &r, offset)
        for k in 0..<count {
            let v = volume.next()
            l[offset + k] *= v; r[offset + k] *= v
            if let (gl, gr) = panGains { l[offset + k] *= gl; r[offset + k] *= gr }
        }
    }
}

/// Same samples; arrays sharing storage (the session's stem cache) compare without a scan.
func sameStem(_ a: [[Float]], _ b: [[Float]]) -> Bool {
    guard a.count == b.count else { return false }
    for (x, y) in zip(a, b) {
        guard x.count == y.count else { return false }
        let shared = x.withUnsafeBufferPointer { px in y.withUnsafeBufferPointer { py in px.baseAddress == py.baseAddress } }
        if !shared && x != y { return false }
    }
    return true
}

/// Renders a project. Playback calls `render(_:)` block by block; export calls
/// `renderAll()` (one pull of the whole range). Both are the same code path, so
/// the samples are identical for any block partition.
public final class AudioGraphRenderer {
    public private(set) var project: AudioGraphProject
    let inputs: [FrameSource]
    var trackStages: [String: TrackStage] = [:]
    var groupStages: [String: GroupStage] = [:]
    let scale: Float
    let makeup: Float
    public private(set) var position = 0
    public var totalFrames: Int { project.totalFrames }

    public init(_ project: AudioGraphProject) {
        self.project = project
        let sr = project.sampleRate
        let mutedGroups = Set(project.groups.filter(\.muted).map(\.id))
        var ungrouped: [FrameSource] = []
        var members: [String: [TrackStage]] = [:]
        var order: [String] = []
        for t in project.tracks where !t.muted {
            if let gid = t.groupId, mutedGroups.contains(gid) { continue }
            let stage = TrackStage(t, sampleRate: sr, quantize: project.quantizeIntermediates)
            trackStages[t.id] = stage
            if let gid = t.groupId {
                if members[gid] == nil { order.append(gid) }
                members[gid, default: []].append(stage)
            } else {
                ungrouped.append(stage)
            }
        }
        var all = ungrouped
        for gid in order {
            let g = project.groups.first(where: { $0.id == gid }) ?? AudioGraphGroup(id: gid)
            let stage = GroupStage(g, members: members[gid]!, duration: project.duration, sampleRate: sr)
            groupStages[gid] = stage
            all.append(stage)
        }
        inputs = all
        let n = max(1, all.count)
        scale = 1 / Float(n)
        makeup = Float(jsStringToNumber(formatFilterNumber(Double(n))))
    }

    /// Next `frames` frames (clamped to the end), interleaved stereo.
    public func render(_ frames: Int) -> [Float] {
        let count = max(0, min(frames, totalFrames - position))
        var outL = [Float](repeating: 0, count: count), outR = outL
        var l = outL, r = outR
        for input in inputs {
            input.pull(count, &l, &r, 0)
            for k in 0..<count { outL[k] += l[k] * scale; outR[k] += r[k] * scale }
        }
        position += count
        var out = [Float](repeating: 0, count: count * 2)
        // A non-finite sample never reaches the device or the encoder.
        for k in 0..<count { out[2 * k] = finiteOrZero(outL[k] * makeup); out[2 * k + 1] = finiteOrZero(outR[k] * makeup) }
        return out
    }

    public func renderAll() -> [Float] { render(totalFrames - position) }

    /// Frames per pull while advancing (any partition gives the same samples; big chunks are just faster).
    public static let advanceChunk = 1 << 16

    /// Renders and discards up to `frame` (clamped to the end; a frame behind `position` changes nothing). The graph
    /// is an in-order pull from frame 0 (FX state, quanta alignment and envelopes count from there), so this pre-roll
    /// is what makes the frames after `frame` the same samples a render from frame 0 produces there.
    public func advance(to frame: Int) {
        var left = min(frame, totalFrames) - position
        while left > 0 { let n = min(left, Self.advanceChunk); _ = render(n); left -= n }
    }

    /// Offline mix for export: `frames` frames starting at `startFrame`, interleaved stereo Float32 at
    /// `project.sampleRate`, sample-identical to that span of `renderOffline(project)` and to live playback (same
    /// stages). Fewer frames come back when the span passes the end. Each call pre-rolls from frame 0; to render a
    /// project in consecutive chunks, keep one renderer: `advance(to:)` once, then `render(_:)` per chunk.
    public static func render(_ project: AudioGraphProject, from startFrame: Int, frames: Int) -> [Float] {
        let r = AudioGraphRenderer(project)
        r.advance(to: max(0, startFrame))
        return r.render(frames)
    }

    /// Live playback: takes `next` without rebuilding when it differs from `project` only in values the
    /// running stages can change in place: clip and group volume (not automation-baked) and un-automated
    /// biquad frequency/Q/gain or gain-node gain (FxChainProcessor.parameterEdits). Returns false, changing
    /// nothing, for any other difference; the caller then builds a new renderer and pre-rolls it.
    /// Stems must be the same samples (shared buffers are recognised without a scan).
    /// Applied before the first render, the output is bit-identical to `AudioGraphRenderer(next)`; mid-stream,
    /// the filters keep their state, so the edit is heard at once instead of after a pre-roll from frame 0.
    public func applyParameterEdits(_ next: AudioGraphProject) -> Bool {
        let old = project
        guard old.duration == next.duration, old.sampleRate == next.sampleRate, old.quantizeIntermediates == next.quantizeIntermediates,
              old.tracks.count == next.tracks.count, old.groups.count == next.groups.count else { return false }
        var edits: [() -> Void] = []
        let glide = LiveEdit.glideFrames(next.sampleRate)
        func chainEdits(_ a: FxChain?, _ b: FxChain?, _ automation: Automation?, _ proc: FxChainProcessor?) -> Bool {
            if a == b { return true }
            guard let a, let b, let proc, !a.enabledNodes.isEmpty,
                  FxTail.chainSeconds(a, automation) == FxTail.chainSeconds(b, automation),
                  let e = proc.parameterEdits(to: b) else { return false }
            edits += e
            return true
        }
        for (a, b) in zip(old.tracks, next.tracks) {
            guard a.id == b.id, a.start == b.start, a.end == b.end, a.pan == b.pan, a.muted == b.muted, a.groupId == b.groupId,
                  a.fadeIn == b.fadeIn, a.fadeOut == b.fadeOut, a.automation == b.automation, sameStem(a.stem, b.stem) else { return false }
            let stage = trackStages[a.id]
            if a.volume != b.volume {
                if let stage {
                    guard !stage.bakedVolume else { return false }
                    let v = filterVolume(b.volume)
                    edits.append { stage.volume.set(v, frames: glide) }
                }
            }
            // A track that was not built (muted, or in a muted group) has nothing running to edit.
            if stage != nil, !chainEdits(a.fxChain, b.fxChain, a.automation, stage?.proc) { return false }
        }
        for (a, b) in zip(old.groups, next.groups) {
            guard a.id == b.id, a.pan == b.pan, a.muted == b.muted, a.automation == b.automation else { return false }
            let stage = groupStages[a.id]
            if a.volume != b.volume, let stage {
                guard !stage.bakedVolume else { return false }
                let v = filterVolume(b.volume)
                edits.append { stage.volume.set(v, frames: glide) }
            }
            if stage != nil, !chainEdits(a.fxChain, b.fxChain, a.automation, stage?.proc) { return false }
        }
        for e in edits { e() }
        project = next
        return true
    }

    /// Offline render of a whole project.
    public static func renderOffline(_ project: AudioGraphProject) -> [Float] { AudioGraphRenderer(project).renderAll() }
}
