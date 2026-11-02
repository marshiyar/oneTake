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
// "Even Out": the leveller (`AudioLeveller`) as a live effect with one Amount. It follows the leveller's recipe on the
// signal as it streams: the level of each 4096-frame window against the loud-end level heard so far (the 80th percentile
// of the speaking windows, where the offline leveller uses the whole clip's), quiet parts lifted and loud parts held down
// by at most 12 dB, with the leveller's 0.35 s attack and 0.9 s release and its 0.4 dB snap. The gain follows the windows
// already heard, so it needs no look-ahead and renders the same samples whatever the block size: playback and export
// agree because both run this unit.
import Foundation

final class LevellerUnit: FxUnit {
    static let histogramFloorDb = -120.0, histogramStepDb = 0.25
    static let bins = Int(-histogramFloorDb / histogramStepDb) + 1
    /// The share of the leveller's correction at Amount 100 % (`AudioLeveller.profile(1)`): a 12 dB gap closes by this much.
    static let fullCorrection = AudioLeveller.profile(1).correction

    let correction: Double
    let attack: Double, release: Double
    private var sumSquares = 0.0, filled = 0
    private var histogram = [Int](repeating: 0, count: LevellerUnit.bins)
    private var heard = 0
    private var peakBin = -1
    private var applied = 0.0, rampFrom = 0.0, rampTo = 0.0   // dB: the gain at the window's start, and where it is heading

    init(_ params: FxParams, _ sampleRate: Double) {
        let amount = min(1, max(0, params.num("amount")))
        correction = amount * Self.fullCorrection
        let hop = Double(AudioLeveller.frame) / max(1, sampleRate)
        attack = 1 - exp(-hop / AudioLeveller.attackS)
        release = 1 - exp(-hop / AudioLeveller.releaseS)
    }

    var automation: [String: [ParamTarget]] { [:] }

    func process(_ input: [[Float]], frame: Int) -> [[Float]] {
        guard let count = input.first?.count, count > 0 else { return input }
        var out = input
        let size = AudioLeveller.frame
        for i in 0..<count {
            var power = 0.0
            for channel in input { let s = Double(channel[i]); if s.isFinite { power += s * s } }
            sumSquares += power / Double(input.count)
            let t = Double(filled) / Double(size)
            let gain = Float(pow(10, (rampFrom + (rampTo - rampFrom) * t) / 20))
            if gain != 1 { for c in out.indices { out[c][i] = input[c][i] * gain } }
            filled += 1
            if filled == size { endWindow() }
        }
        return out
    }

    /// The window just heard sets where the gain heads during the next one.
    private func endWindow() {
        let meanSquare = sumSquares / Double(AudioLeveller.frame)
        sumSquares = 0; filled = 0
        let level = meanSquare > 0 ? 10 * log10(meanSquare) : -Double.infinity
        var wanted = 0.0
        if level.isFinite {
            let bin = min(Self.bins - 1, max(0, Int(((level - Self.histogramFloorDb) / Self.histogramStepDb).rounded())))
            histogram[bin] += 1; heard += 1; peakBin = max(peakBin, bin)
            let floor = Self.level(ofBin: peakBin) - AudioLeveller.floorBelowPeakDb
            if level > floor {
                wanted = max(-AudioLeveller.maxCutDb, min(AudioLeveller.maxLiftDb, (percentile(0.8) - level) * correction))
            }
        }
        applied += (wanted > applied ? attack : release) * (wanted - applied)
        rampFrom = rampTo
        rampTo = abs(applied) < AudioLeveller.snapDb ? 0 : applied
    }

    private static func level(ofBin bin: Int) -> Double { histogramFloorDb + Double(bin) * histogramStepDb }

    /// The level below which `share` of the speaking windows heard so far lie.
    private func percentile(_ share: Double) -> Double {
        let rank = min(heard - 1, Int((Double(heard) * share).rounded(.down)))
        var seen = 0
        for (bin, n) in histogram.enumerated() {
            seen += n
            if seen > rank { return Self.level(ofBin: bin) }
        }
        return Self.level(ofBin: peakBin)
    }
}
