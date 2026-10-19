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

// The leveller ("Even Out Levels").
public enum AudioLeveller {
    static let frame = 4096
    static let pointBudget = 400
    static let floorBelowPeakDb = 42.0
    static let maxLiftDb = 12.0
    static let maxCutDb = 12.0
    static let snapDb = 0.4
    static let attackS = 0.35
    static let releaseS = 0.9
    public static let defaultStrength = 0.5

    public static func profile(_ strength: Double) -> (correction: Double, Void) {
        let s = strength.isFinite ? min(1, max(0, strength)) : 0.5
        return (jsRoundTo(0.25 + s * 0.6, 3), ())
    }

    /// RMS level in dB of `count` samples from `from`, -∞ for silence (stops at the end of `samples`).
    static func windowDb(_ samples: [Float], _ from: Int, _ count: Int) -> Double {
        var sum = 0.0, n = 0
        if from >= 0 {
            var i = from
            while i < from + count && i < samples.count { let s = Double(samples[i]); sum += s * s; n += 1; i += 1 }
        }
        if n == 0 { return -.infinity }
        let rms = (sum / Double(n)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -.infinity
    }

    public static func analyse(_ samples: [Float], sampleRate: Double, strength: Double = defaultStrength) -> [AutomationPoint] {
        if samples.isEmpty || sampleRate <= 0 { return [] }
        let correction = profile(strength).correction
        let hop = max(frame, Int((Double(samples.count) / Double(pointBudget)).rounded(.up)))
        var levels: [Double] = [], times: [Double] = []
        var start = 0
        while start < samples.count {
            levels.append(windowDb(samples, start, frame))
            times.append(Double(start + frame / 2) / sampleRate)
            start += hop
        }
        let speaking = levels.filter(\.isFinite)
        guard let peak = speaking.max() else { return [] }
        let floor = peak - floorBelowPeakDb
        let sorted = speaking.sorted()
        let target = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.8).rounded(.down)))]
        let attack = 1 - exp(-(Double(hop) / sampleRate) / attackS)
        let release = 1 - exp(-(Double(hop) / sampleRate) / releaseS)
        var applied = 0.0
        var raw: [AutomationPoint] = []
        for (i, db) in levels.enumerated() {
            let wanted = db.isFinite && db > floor ? max(-maxCutDb, min(maxLiftDb, (target - db) * correction)) : 0
            applied += (wanted > applied ? attack : release) * (wanted - applied)
            let v = abs(applied) < snapDb ? 0 : jsRoundTo(applied, 1)
            raw.append(AutomationPoint(t: jsRoundTo(times[i], 3), v: v))
        }
        var points: [AutomationPoint] = []
        var lastKept = 0.0
        var keptIndex = -1
        for (i, pt) in raw.enumerated() {
            if i != raw.count - 1 && abs(pt.v - lastKept) < snapDb { continue }
            if i > 0 && keptIndex != i - 1 { points.append(raw[i - 1]) }
            points.append(pt)
            lastKept = pt.v
            keptIndex = i
        }
        if points.isEmpty || points.allSatisfy({ $0.v == 0 }) { return [] }
        if points[0].t > 0 { points.insert(AutomationPoint(t: 0, v: points[0].v), at: 0) }
        return points
    }

    public static func result(_ chain: FxChain, samples: [Float], sampleRate: Double, strength: Double = defaultStrength) -> (chain: FxChain, automation: Automation)? {
        let points = analyse(samples, sampleRate: sampleRate, strength: strength)
        if points.isEmpty { return nil }
        let existing = chain.nodes.first { $0.fromLeveller == true }
        let id = existing?.id ?? chain.mintNodeId()
        let node = FxNode(type: "gain", id: id, label: "Even Out Levels", fromLeveller: true, enabled: true,
                          params: AudioFx.normalize("gain", ["gain": .number(0)]))
        let insertAt = existing == nil && chain.nodes.last?.type == "limiter" ? chain.nodes.count - 1 : chain.nodes.count
        let nodes = existing != nil ? chain.nodes.map { $0.fromLeveller == true ? node : $0 }
            : Array(chain.nodes.prefix(insertAt)) + [node] + Array(chain.nodes.dropFirst(insertAt))
        return (FxChain(nodes: nodes), Automation(lanes: [AutomationLane(target: AudioAutomation.fxTarget(id, "gain"), points: points)]))
    }

    public static func remove(_ chain: FxChain) -> (chain: FxChain, removedTarget: String?) {
        let node = chain.nodes.first { $0.fromLeveller == true }
        return (FxChain(nodes: chain.nodes.filter { $0.fromLeveller != true }), node?.id.map { AudioAutomation.fxTarget($0, "gain") })
    }

    public static func summary(_ points: [AutomationPoint]) -> String {
        let moves = points.filter { $0.v != 0 }
        if moves.isEmpty { return "Already even — nothing to do" }
        let lift = moves.map(\.v).max()!, cut = moves.map(\.v).min()!
        var parts: [String] = []
        if lift > 0 { parts.append("lifting quiet parts up to \(jsToFixed(lift, 1)) dB") }
        if cut < 0 { parts.append("holding loud parts down \(jsToFixed(abs(cut), 1)) dB") }
        return parts.joined(separator: ", ")
    }
}
