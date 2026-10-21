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

/// One built effect: a sub-graph processing one DSP block at a time.
/// The Swift form of an FX node handle.
protocol FxUnit: AnyObject {
    /// `frame` is the context frame of the quantum's first sample.
    func process(_ x: [[Float]], frame: Int) -> [[Float]]
    var automation: [String: [ParamTarget]] { get }
}

private func n(_ p: FxParams, _ k: String) -> Double { p.num(k) }
private let dbToLinearMap: @Sendable (Double) -> Double = { pow(10, $0 / 20) }
private func mixTargets(_ wet: ParamTimeline, _ dry: ParamTimeline) -> [ParamTarget] {
    [ParamTarget(param: wet, map: nil), ParamTarget(param: dry, map: { 1 - $0 })]
}

final class GainUnit: FxUnit {
    let g: GainStage
    init(_ p: FxParams, _ sr: Double) { g = GainStage(pow(10, n(p, "gain") / 20), sampleRate: sr) }
    func process(_ x: [[Float]], frame: Int) -> [[Float]] { g.process(x, frame: frame) }
    var automation: [String: [ParamTarget]] { ["gain": [ParamTarget(param: g.gain, map: dbToLinearMap)]] }
}

final class BiquadUnit: FxUnit {
    let f: BiquadFilter
    let usesQ: Bool, usesGain: Bool
    init(_ type: BiquadType, _ p: FxParams, _ sr: Double) {
        f = BiquadFilter(type, sampleRate: sr)
        usesQ = [.peaking, .highpass, .lowpass].contains(type)
        usesGain = [.peaking, .lowshelf, .highshelf].contains(type)
        f.frequency.value = Float(n(p, "frequency"))
        if p["q"] != nil { f.q.value = Float(n(p, "q")) }
        if usesGain { f.gain.value = Float(n(p, "gain")) }
    }
    func process(_ x: [[Float]], frame: Int) -> [[Float]] { f.process(x, frame: frame) }
    var automation: [String: [ParamTarget]] {
        var a: [String: [ParamTarget]] = ["frequency": [ParamTarget(param: f.frequency, map: nil)]]
        if usesQ { a["q"] = [ParamTarget(param: f.q, map: nil)] }
        if usesGain { a["gain"] = [ParamTarget(param: f.gain, map: nil)] }
        return a
    }
}

final class OnePoleUnit: FxUnit {
    let iir: IIRFilter
    init(highpass: Bool, _ p: FxParams, _ sr: Double) {
        let k = tan((Double.pi * n(p, "frequency")) / sr)
        iir = highpass
            ? IIRFilter(feedforward: [1 / (1 + k), -1 / (1 + k)], feedback: [1, (k - 1) / (k + 1)])
            : IIRFilter(feedforward: [k / (1 + k), k / (1 + k)], feedback: [1, (k - 1) / (k + 1)])
    }
    func process(_ x: [[Float]], frame: Int) -> [[Float]] { iir.process(x) }
    var automation: [String: [ParamTarget]] { [:] }
}

final class ProcessorUnit: FxUnit {
    let proc: BlockProcessor
    init(_ proc: BlockProcessor) { self.proc = proc }
    func process(_ x: [[Float]], frame: Int) -> [[Float]] {
        var out = x.map { [Float](repeating: 0, count: $0.count) }
        proc.process(x, &out)
        return out
    }
    var automation: [String: [ParamTarget]] { [:] }
}

private let curves: [String: @Sendable (Double) -> Double] = [
    "tanh": { tanh($0) },
    "atan": { (2 / Double.pi) * atan((Double.pi / 2) * $0) },
    "cubic": { abs($0) >= 1 ? jsSign($0) : $0 - pow($0, 3) / 3 },
    "exp": { jsSign($0) * (1 - exp(-abs($0))) },
    "alg": { $0 / (1 + $0 * $0).squareRoot() },
    "quintic": { abs($0) >= 1 ? jsSign($0) : $0 - pow($0, 5) / 5 },
    "sin": { abs($0) >= 1 ? jsSign($0) : sin((Double.pi / 2) * $0) },
    "erf": { tanh(1.20211 * $0) },
    "hard": { jsMax(-1, jsMin(1, $0)) },
]
func jsSign(_ x: Double) -> Double { x > 0 ? 1 : x < 0 ? -1 : x }

final class WaveShaperUnit: FxUnit {
    let ws = WaveShaper()
    let post: GainStage
    init(_ p: FxParams, _ sr: Double) {
        let shape = curves[p["type"]?.string ?? ""] ?? { tanh($0) }
        let threshold = pow(10, n(p, "threshold") / 20)
        let size = 8192
        ws.curve = (0..<size).map { i in
            let x = (Double(i) / Double(size - 1)) * 2 - 1
            return Float(shape(x / jsMax(1e-6, threshold)) * threshold)
        }
        let o = n(p, "oversample")
        ws.oversample = o >= 4 ? 4 : o >= 2 ? 2 : 1
        post = GainStage(pow(10, n(p, "output") / 20), sampleRate: sr)
    }
    func process(_ x: [[Float]], frame: Int) -> [[Float]] { post.process(ws.process(x), frame: frame) }
    var automation: [String: [ParamTarget]] { ["output": [ParamTarget(param: post.gain, map: dbToLinearMap)]] }
}

final class FeedbackDelayUnit: FxUnit {
    let dl: DelayLine
    let time: ParamTimeline
    let fb: GainStage, wet: GainStage, dry: GainStage
    var recirculation: [[Float]] = [] // fb output of the previous quantum (cycle break)
    private var tBuf = [Float](repeating: 0, count: dspBlockSize)
    var lines: [DelayLine] = []
    let sr: Double
    init(_ p: FxParams, _ sr: Double) {
        self.sr = sr
        dl = DelayLine(maxDelay: 5, sampleRate: sr)
        time = ParamTimeline(Float(min(5, n(p, "time") / 1000)), sampleRate: sr)
        fb = GainStage(n(p, "feedback"), sampleRate: sr)
        wet = GainStage(n(p, "mix"), sampleRate: sr)
        dry = GainStage(1 - n(p, "mix"), sampleRate: sr)
    }
    func process(_ x: [[Float]], frame: Int) -> [[Float]] {
        let count = x.first?.count ?? 0
        while lines.count < x.count { lines.append(DelayLine(maxDelay: 5, sampleRate: sr)) }
        if recirculation.count != x.count { recirculation = x.map { [Float](repeating: 0, count: $0.count) } }
        time.fill(frame: frame, count: count, into: &tBuf)
        let dIn = sum(x, recirculation)
        let dOut = (0..<x.count).map { lines[$0].process(dIn[$0], Array(tBuf[0..<count])) }
        recirculation = fb.process(dOut, frame: frame)
        return sum(wet.process(dOut, frame: frame), dry.process(x, frame: frame))
    }
    var automation: [String: [ParamTarget]] {
        ["time": [ParamTarget(param: time, map: { min(5, $0 / 1000) })],
         "feedback": [ParamTarget(param: fb.gain, map: nil)],
         "mix": mixTargets(wet.gain, dry.gain)]
    }
}

final class ChorusUnit: FxUnit {
    var lines: [DelayLine] = []
    let delay: ParamTimeline
    let depth: GainStage, wet: GainStage, dry: GainStage
    let lfo: LoopingBufferSource
    let sr: Double
    private var dBuf = [Float](repeating: 0, count: dspBlockSize)
    init(_ p: FxParams, _ sr: Double, elapsed: Double) {
        self.sr = sr
        delay = ParamTimeline(Float(n(p, "delay") / 1000), sampleRate: sr)
        depth = GainStage(n(p, "depth") / 1000, sampleRate: sr)
        lfo = LoopingBufferSource.lfo(wave: "sine", speed: n(p, "speed"), elapsed: elapsed, sampleRate: sr)
        wet = GainStage(n(p, "mix"), sampleRate: sr)
        dry = GainStage(1 - n(p, "mix"), sampleRate: sr)
    }
    func process(_ x: [[Float]], frame: Int) -> [[Float]] {
        let count = x.first?.count ?? 0
        while lines.count < x.count { lines.append(DelayLine(maxDelay: 0.5, sampleRate: sr)) }
        let mod = depth.process([lfo.render(frame: frame, count: count)], frame: frame)[0]
        delay.fill(frame: frame, count: count, into: &dBuf)
        let times = (0..<count).map { dBuf[$0] + mod[$0] }
        let dOut = (0..<x.count).map { lines[$0].process(x[$0], times) }
        return sum(wet.process(dOut, frame: frame), dry.process(x, frame: frame))
    }
    var automation: [String: [ParamTarget]] {
        ["delay": [ParamTarget(param: delay, map: { $0 / 1000 })],
         "depth": [ParamTarget(param: depth.gain, map: { $0 / 1000 })],
         "speed": [ParamTarget(param: lfo.playbackRate, map: nil)],
         "mix": mixTargets(wet.gain, dry.gain)]
    }
}

final class PhaserUnit: FxUnit {
    let inTrim: GainStage, outTrim: GainStage, depth: GainStage
    let lfo: LoopingBufferSource
    let stages: [BiquadFilter]
    init(_ p: FxParams, _ sr: Double, elapsed: Double) {
        lfo = LoopingBufferSource.lfo(wave: p["type"]?.string == "1" ? "sine" : "triangle", speed: n(p, "speed"), elapsed: elapsed, sampleRate: sr)
        let centre = 1000 / jsMax(0.1, n(p, "delay"))
        stages = (0..<6).map { _ in
            let ap = BiquadFilter(.allpass, sampleRate: sr, frequency: centre, q: 0.7071)
            return ap
        }
        depth = GainStage(centre * n(p, "decay"), sampleRate: sr)
        inTrim = GainStage(n(p, "in_gain"), sampleRate: sr)
        outTrim = GainStage(n(p, "out_gain"), sampleRate: sr)
    }
    func process(_ x: [[Float]], frame: Int) -> [[Float]] {
        let count = x.first?.count ?? 0
        let mod = depth.process([lfo.render(frame: frame, count: count)], frame: frame)[0]
        let trimmed = inTrim.process(x, frame: frame)
        var y = trimmed
        for ap in stages { ap.frequencyInput = mod; y = ap.process(y, frame: frame) }
        return outTrim.process(sum(y, trimmed), frame: frame) // wet = dry = 1
    }
    var automation: [String: [ParamTarget]] {
        ["speed": [ParamTarget(param: lfo.playbackRate, map: nil)],
         "in_gain": [ParamTarget(param: inTrim.gain, map: nil)],
         "out_gain": [ParamTarget(param: outTrim.gain, map: nil)]]
    }
}

final class ReverbUnit: FxUnit {
    let conv: FFTConvolver
    let wet: GainStage, dry: GainStage
    init(_ p: FxParams, _ sr: Double) {
        conv = FFTConvolver(impulse: synthesizeReverbImpulse(sampleRate: sr, size: n(p, "size"), damping: n(p, "damping")))
        wet = GainStage(n(p, "wet"), sampleRate: sr)
        dry = GainStage(n(p, "dry"), sampleRate: sr)
    }
    func process(_ x: [[Float]], frame: Int) -> [[Float]] { sum(wet.process(conv.process(x), frame: frame), dry.process(x, frame: frame)) }
    var automation: [String: [ParamTarget]] { ["wet": [ParamTarget(param: wet.gain, map: nil)], "dry": [ParamTarget(param: dry.gain, map: nil)]] }
}

/// `buildFxUnit`.
func buildFxUnit(_ type: String, _ params: FxParams?, sampleRate sr: Double, elapsed: Double = 0) -> FxUnit {
    guard let def = AudioFx.definition(type) else { fatalError("Unknown effect type: \(type)") }
    let p = AudioFx.normalize(type, params)
    if (type == "highpass" || type == "lowpass") && p["poles"]?.string == "1" { return OnePoleUnit(highpass: type == "highpass", p, sr) }
    switch def.implementation {
    case "gain": return GainUnit(p, sr)
    case "biquad-peaking": return BiquadUnit(.peaking, p, sr)
    case "biquad-lowshelf": return BiquadUnit(.lowshelf, p, sr)
    case "biquad-highshelf": return BiquadUnit(.highshelf, p, sr)
    case "biquad-highpass": return BiquadUnit(.highpass, p, sr)
    case "biquad-lowpass": return BiquadUnit(.lowpass, p, sr)
    case "compressor": return ProcessorUnit(CompressorProcessor(p, sampleRate: sr))
    case "limiter": return ProcessorUnit(LimiterProcessor(p, sampleRate: sr))
    case "gate": return ProcessorUnit(GateProcessor(p, sampleRate: sr))
    case "bitcrusher": return ProcessorUnit(BitcrusherProcessor(p))
    case "pitch-shift": return ProcessorUnit(PitchShiftProcessor(p, sampleRate: sr))
    case "waveshaper": return WaveShaperUnit(p, sr)
    case "delay-feedback": return FeedbackDelayUnit(p, sr)
    case "chorus-lfo": return ChorusUnit(p, sr, elapsed: elapsed)
    case "allpass-phaser": return PhaserUnit(p, sr, elapsed: elapsed)
    case "convolver": return ReverbUnit(p, sr)
    default: fatalError("No builder for \(def.implementation)")
    }
}

/// `buildFxChain` plus `scheduleChainAutomation`: a whole chain as a block processor.
public final class FxChainProcessor {
    struct Run { var presetId: String?; var units: [FxUnit]; var wet: GainStage?; var dry: GainStage? }
    var runs: [Run] = []
    var byId: [String: FxUnit] = [:]
    /// Every built unit, in `chain.enabledNodes` order (in-place parameter edits address units by position).
    var units: [FxUnit] = []
    let chain: FxChain
    public let sampleRate: Double
    public var isEmpty: Bool { runs.isEmpty }

    public init(_ chain: FxChain, automation: Automation? = nil, sampleRate: Double = 48000,
                timing: FxAutomationScheduler.Timing = .init()) {
        self.sampleRate = sampleRate
        self.chain = chain
        var presetTargets: [String: [ParamTarget]] = [:]
        for node in chain.enabledNodes {
            let preset = node.fromPreset
            if let last = runs.last, last.presetId == preset {
                let u = buildFxUnit(node.type, node.params, sampleRate: sampleRate)
                units.append(u)
                runs[runs.count - 1].units.append(u)
                if let id = node.id { byId[id] = u }
                continue
            }
            let amount = min(1, max(0, node.presetAmount ?? 1))
            var run = Run(presetId: preset, units: [])
            if let preset {
                run.wet = GainStage(amount, sampleRate: sampleRate)
                run.dry = GainStage(1 - amount, sampleRate: sampleRate)
                presetTargets[preset, default: []].append(contentsOf: mixTargets(run.wet!.gain, run.dry!.gain))
            }
            let u = buildFxUnit(node.type, node.params, sampleRate: sampleRate)
            units.append(u)
            run.units.append(u)
            if let id = node.id, byId[id] == nil { byId[id] = u } else if let id = node.id { byId[id] = u }
            runs.append(run)
        }
        guard let automation else { return }
        for lane in automation.lanes {
            guard let parsed = AudioAutomation.parseTarget(lane.target) else { continue }
            let targets: [ParamTarget]?
            switch parsed {
            case let .preset(id): targets = presetTargets[id]
            case let .fx(nodeId, param): targets = byId[nodeId]?.automation[param]
            case .volume: targets = nil
            }
            guard let targets, !targets.isEmpty, let range = AudioAutomation.resolveRange(lane.target, chain) else { continue }
            FxAutomationScheduler.scheduleLane(targets, lane, range.scale, timing)
        }
    }

    /// Parameter-only edit, applied to the running units without rebuilding them (live playback: an EQ band
    /// or gain slider must not restart the graph). Returns the setters to run, or nil when `next` differs from
    /// the built chain in anything but an un-automated biquad frequency/Q/gain or gain-node gain; then the
    /// caller rebuilds. The setters write exactly what the unit initialisers write, so a unit edited before
    /// its first DSP block renders bit-identically to one built from `next`.
    func parameterEdits(to next: FxChain) -> [() -> Void]? {
        let a = chain.enabledNodes, b = next.enabledNodes
        guard a.count == b.count, a.count == units.count else { return nil }
        var edits: [() -> Void] = []
        for i in a.indices {
            var x = a[i], y = b[i]
            let px = AudioFx.normalize(x.type, x.params), py = AudioFx.normalize(y.type, y.params)
            x.params = nil; y.params = nil
            guard x == y else { return nil }
            if px == py { continue }
            let keys = Set(px.entries.map(\.0)).union(py.entries.map(\.0)).filter { px[$0] != py[$0] }
            switch units[i] {
            case let u as BiquadUnit:
                for k in keys {
                    guard let v = py[k]?.number, v.isFinite else { return nil }
                    let param: ParamTimeline
                    switch k {
                    case "frequency": param = u.f.frequency
                    case "q": param = u.f.q
                    case "gain" where u.usesGain: param = u.f.gain
                    default: return nil
                    }
                    guard !param.hasEvents else { return nil }
                    edits.append { param.value = Float(v) }
                }
            case let u as GainUnit:
                guard keys == ["gain"], let v = py["gain"]?.number, v.isFinite, !u.g.gain.hasEvents else { return nil }
                edits.append { u.g.gain.value = Float(pow(10, v / 20)) }
            default:
                return nil
            }
        }
        return edits
    }

    /// Process one DSP block (≤128 frames) whose first frame is context frame `frame`.
    public func process(_ x: [[Float]], frame: Int) -> [[Float]] {
        var tail = x
        for run in runs {
            let entry = tail
            for u in run.units { tail = u.process(tail, frame: frame) }
            if let wet = run.wet, let dry = run.dry {
                tail = sum(wet.process(tail, frame: frame), dry.process(entry, frame: frame))
            }
        }
        return tail
    }
}
