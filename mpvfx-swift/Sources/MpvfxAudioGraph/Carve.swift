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

// Voice carve: find the bands a voice occupies, dip a bed there.
public enum AudioCarve {
    public static let attribute = "data-fx-carve"
    static let candidateCentersHz: [Double] = [160, 250, 400, 630, 1000, 1600, 2500, 4000, 6000]
    static let frame = 4096
    static let hop = 2048

    // Lookbehind/lookahead keep short words whole.
    static func wordish(_ term: String) -> String { "(?<![a-z0-9])\(term)(?![a-z0-9])" }
    static let sfxName = try! NSRegularExpression(pattern: "sfx|foley|whoosh|impact|riser|stinger|swoosh|thud|boom|click|ding|beep|ambien|room[-_ ]?tone", options: .caseInsensitive)
    static let musicName = try! NSRegularExpression(pattern: "music|bgm|\(wordish("bed"))|soundtrack|score|\(wordish("song"))|theme|instrumental|track\\d", options: .caseInsensitive)
    static let voiceName = try! NSRegularExpression(pattern: "voice|\(wordish("vo"))|\(wordish("vox"))|narrat|speech|dialog|monolog|announce|\(wordish("tts"))|talk|interview|podcast|recap|script", options: .caseInsensitive)

    public enum NameKind: String, Sendable { case voice, sfx, music, unknown }

    static func matches(_ re: NSRegularExpression, _ text: String) -> Bool {
        re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public static func classify(_ parts: String?...) -> NameKind { classify(parts) }
    public static func classify(_ parts: [String?]) -> NameKind {
        let text = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        if matches(voiceName, text) { return .voice }
        if matches(sfxName, text) { return .sfx }
        if matches(musicName, text) { return .music }
        return .unknown
    }

    public struct ClipSpan: Sendable { public var start: Double; public var duration: Double?; public init(start: Double, duration: Double?) { self.start = start; self.duration = duration } }
    public static func clipsOverlap(_ a: ClipSpan, _ b: ClipSpan) -> Bool {
        func end(_ c: ClipSpan) -> Double { if let d = c.duration, d.isFinite { return c.start + max(0, d) }; return .infinity }
        return a.start < end(b) && b.start < end(a)
    }
    public static func couldBeCarveSource(_ parts: [String?]) -> Bool { let k = classify(parts); return k == .voice || k == .unknown }
    public static func couldBeCarveBed(_ parts: [String?]) -> Bool { classify(parts) != .voice }
    public static func isNamedCarveBed(_ parts: [String?]) -> Bool { let k = classify(parts); return k == .music || k == .sfx }

    public struct Settings: Equatable, Sendable { public var enabled: Bool; public var sources: [String]; public var strength: Double }
    public static let defaultSettings = Settings(enabled: true, sources: [], strength: 0.25)

    public struct Profile: Equatable, Sendable {
        public var maxCutDb: Double, bands: Int, q: Double, intelligibilityBias: Double, duckDb: Double, headroomDb: Double
    }

    public static func profile(_ strength: Double) -> Profile {
        let s = strength.isFinite ? min(1, max(0, strength)) : 0.5
        return Profile(maxCutDb: jsRoundTo(2 + s * 16, 2), bands: max(1, min(6, Int(jsMathRound(1 + s * 6)))), q: jsRoundTo(1.1 + s * 1.2, 2),
                       intelligibilityBias: jsRoundTo(min(1, 0.6 + s * 0.4), 2), duckDb: jsRoundTo(s * 24, 2), headroomDb: jsRoundTo(6 + s * 12, 2))
    }

    /// `normalizeCarveSettings`. `raw == nil` means the attribute is absent (undefined or null).
    public static func normalizeSettings(_ raw: JSONValue?) -> Settings {
        guard let raw, raw != .null else { return defaultSettings }
        func num(_ v: JSONValue?) -> Double? {
            let n: Double
            switch v {
            case let .number(x)?: n = x
            case let .string(s)?: n = jsStringToNumber(s)
            case .bool(let b)?: n = b ? 1 : 0
            case .null?: n = 0
            case nil: n = .nan
            case let .array(a)?: n = a.isEmpty ? 0 : (a.count == 1 ? num(a[0]) ?? .nan : .nan)
            case .object?: n = .nan
            }
            return n.isFinite ? n : nil
        }
        let strength = num(raw["strength"])
        let legacyDepth = num(raw["maxCutDb"])
        let resolved = strength ?? legacyDepth.map { ($0 - 2) / 16 } ?? defaultSettings.strength
        var stored: [JSONValue] = []
        if case let .array(a)? = raw["sources"] { stored = a } else if case let .string(s)? = raw["source"] { stored = [.string(s)] }
        return Settings(enabled: raw["enabled"] != .bool(false),
                        sources: stored.compactMap { if case let .string(s) = $0, !s.isEmpty { return s }; return nil },
                        strength: min(1, max(0, resolved)))
    }

    public struct SourcePart: Sendable { public var samples: [Float]; public var offsetSeconds: Double
        public init(samples: [Float], offsetSeconds: Double) { self.samples = samples; self.offsetSeconds = offsetSeconds } }

    public static func mixSources(_ parts: [SourcePart], sampleRate: Double) -> [Float] {
        let placed = parts.map { ($0.samples, Int(jsMathRound($0.offsetSeconds * sampleRate))) }
        let length = placed.reduce(0) { max($0, $1.1 + $1.0.count) }
        if length <= 0 { return [] }
        var mixed = [Float](repeating: 0, count: length)
        for (samples, at) in placed {
            var i = at < 0 ? -at : 0
            while i < samples.count {
                let target = at + i
                if target >= 0 && target < length { mixed[target] = mixed[target] + samples[i] }
                i += 1
            }
        }
        return mixed
    }

    static let hannWindow: [Float] = (0..<frame).map { Float(0.5 - 0.5 * cos((2 * Double.pi * Double($0)) / Double(frame - 1))) }

    /// In-place iterative radix-2 FFT (fixed operation order, so recorded reference values match exactly).
    static func fft(_ re: inout [Double], _ im: inout [Double]) {
        let n = re.count
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j ^= bit
            if i < j { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var len = 2
        while len <= n {
            let ang = (-2 * Double.pi) / Double(len)
            let wr = cos(ang), wi = sin(ang)
            let half = len / 2
            var i = 0
            while i < n {
                var cr = 1.0, ci = 0.0
                for k in 0..<half {
                    let ur = re[i + k], ui = im[i + k]
                    let vr = re[i + k + half] * cr - im[i + k + half] * ci
                    let vi = re[i + k + half] * ci + im[i + k + half] * cr
                    re[i + k] = ur + vr; im[i + k] = ui + vi
                    re[i + k + half] = ur - vr; im[i + k + half] = ui - vi
                    let ncr = cr * wr - ci * wi
                    ci = cr * wi + ci * wr
                    cr = ncr
                }
                i += len
            }
            len <<= 1
        }
    }

    static func powerSpectrum(_ mono: [Float], _ sampleRate: Double) -> (freqs: [Double], power: [Double]) {
        let n = max(mono.count, frame)
        let padded = mono.count >= frame ? mono : mono + [Float](repeating: 0, count: frame - mono.count)
        let bins = frame / 2 + 1
        var acc = [Double](repeating: 0, count: bins)
        var re = [Double](repeating: 0, count: frame), im = [Double](repeating: 0, count: frame)
        var frames = 0
        var start = 0
        while start + frame <= n {
            for i in 0..<frame { im[i] = 0; re[i] = Double(padded[start + i]) * Double(hannWindow[i]) }
            fft(&re, &im)
            for k in 0..<bins { acc[k] += re[k] * re[k] + im[k] * im[k] }
            frames += 1
            start += hop
        }
        if frames == 0 { frames = 1 }
        return ((0..<bins).map { Double($0) * sampleRate / Double(frame) }, acc.map { $0 / Double(frames) })
    }

    static func bandPower(_ freqs: [Double], _ power: [Double], _ center: Double) -> Double {
        let lo = center / pow(2, 1.0 / 6), hi = center * pow(2, 1.0 / 6)
        var sum = 0.0, count = 0
        for i in 0..<freqs.count where freqs[i] >= lo && freqs[i] < hi { sum += power[i]; count += 1 }
        return count > 0 ? sum / Double(count) : 0
    }

    static let biasAuthorityDb = 30.0
    static func intelligibilityPenaltyDb(_ center: Double, _ bias: Double) -> Double {
        let o = log2(center / 2000)
        return bias * biasAuthorityDb * (1 - exp(-(o * o) / 2))
    }

    public struct Band: Equatable, Sendable { public var freq: Double; public var gainDb: Double; public var q: Double }

    public static func analyseBands(_ voice: [Float], sampleRate: Double, profile: Profile) -> [Band] {
        if voice.isEmpty { return [] }
        let (freqs, power) = powerSpectrum(voice, sampleRate)
        let scored = candidateCentersHz.map { center -> (center: Double, hasEnergy: Bool, scoreDb: Double) in
            let p = bandPower(freqs, power, center)
            return (center, p > 0, p > 0 ? 10 * log10(p) - intelligibilityPenaltyDb(center, profile.intelligibilityBias) : -.infinity)
        }.enumerated().sorted { a, b in
            // (b.scoreDb - a.scoreDb): NaN (−∞ − −∞) compares as "equal" and keeps order.
            let d = b.element.scoreDb - a.element.scoreDb
            if d.isNaN || d == 0 { return a.offset < b.offset }
            return d < 0
        }.map(\.element)
        let selected = scored.prefix(max(1, profile.bands)).filter(\.hasEnergy)
        guard let top = selected.first?.scoreDb else { return [] }
        return selected.map { item -> Band in
            let relative = pow(10, (item.scoreDb - top) / 10)
            let depth = min(profile.maxCutDb, max(profile.maxCutDb / 2, profile.maxCutDb * relative))
            return Band(freq: item.center, gainDb: -jsRoundTo(depth, 2), q: profile.q)
        }.sorted { $0.freq < $1.freq }
    }

    static let dynamicRangeDb = 30.0
    static let attackS = 0.05
    static let releaseS = 0.25
    static let duckReleaseS = 1.6
    static let pointBudget = 400
    static let snapDb = 0.2
    static let stepDb = 0.5

    static func simplifyStepPoints(_ raw: [AutomationPoint], _ stepDb: Double) -> [AutomationPoint] {
        var points = [AutomationPoint(t: 0, v: 0)]
        var lastKept = 0.0, keptIndex = -1
        for (i, pt) in raw.enumerated() {
            if i != raw.count - 1 && abs(pt.v - lastKept) < stepDb { continue }
            if i > 0 && keptIndex != i - 1 { points.append(raw[i - 1]) }
            points.append(pt)
            lastKept = pt.v
            keptIndex = i
        }
        return points
    }

    public struct BandEnvelope: Equatable, Sendable { public var freq: Double; public var points: [AutomationPoint] }

    public static func analyseDynamics(_ voice: [Float], sampleRate: Double, bands: [Band]) -> [BandEnvelope] {
        if voice.isEmpty || bands.isEmpty { return [] }
        let hop = max(frame, Int((Double(voice.count) / Double(pointBudget)).rounded(.up)))
        let bins = frame / 2 + 1
        let freqs = (0..<bins).map { Double($0) * sampleRate / Double(frame) }
        var times: [Double] = []
        var perBand = [[Double]](repeating: [], count: bands.count)
        var re = [Double](repeating: 0, count: frame), im = [Double](repeating: 0, count: frame)
        var start = 0
        while start < voice.count {
            for i in 0..<frame {
                im[i] = 0
                let s: Float = start + i < voice.count ? voice[start + i] : 0
                re[i] = Double(s) * Double(hannWindow[i])
            }
            fft(&re, &im)
            let power = (0..<bins).map { re[$0] * re[$0] + im[$0] * im[$0] }
            times.append(Double(start + frame / 2) / sampleRate)
            for (b, band) in bands.enumerated() { perBand[b].append(bandPower(freqs, power, band.freq)) }
            start += hop
        }
        let duration = Double(voice.count) / sampleRate
        let attack = 1 - exp(-(Double(hop) / sampleRate) / attackS)
        let release = 1 - exp(-(Double(hop) / sampleRate) / releaseS)
        return bands.enumerated().map { b, band in
            let powers = perBand[b]
            let peak = powers.reduce(-Double.infinity) { jsMax($0, $1) }
            var level = 0.0
            var raw: [AutomationPoint] = []
            for (i, p) in powers.enumerated() {
                let target = p > 0 && peak > 0 ? max(0, 1 + (10 * log10(p / peak)) / dynamicRangeDb) : 0
                level += (target > level ? attack : release) * (target - level)
                let scaled = band.gainDb * level
                raw.append(AutomationPoint(t: jsRoundTo(times[i], 3), v: abs(scaled) < snapDb ? 0 : jsRoundTo(scaled, 1)))
            }
            var points = simplifyStepPoints(raw, stepDb)
            points.append(AutomationPoint(t: jsRoundTo(max(duration, points.last!.t), 3), v: 0))
            return BandEnvelope(freq: band.freq, points: points)
        }
    }

    public static func analyseDuck(_ voice: [Float], bed: [Float], sampleRate: Double, profile: Profile, offsetSeconds: Double) -> [AutomationPoint] {
        if voice.isEmpty || profile.duckDb <= 0 { return [] }
        let hop = max(frame, Int((Double(voice.count) / Double(pointBudget)).rounded(.up)))
        let bedOffset = Int(jsMathRound(offsetSeconds * sampleRate))
        var voiceDbs: [Double] = [], bedDbs: [Double] = [], times: [Double] = []
        var start = 0
        while start < voice.count {
            voiceDbs.append(AudioLeveller.windowDb(voice, start, frame))
            bedDbs.append(AudioLeveller.windowDb(bed, start + bedOffset, frame))
            times.append(Double(start + frame / 2) / sampleRate)
            start += hop
        }
        let voicePeak = voiceDbs.reduce(-Double.infinity) { jsMax($0, $1) }
        let speakingFloor = voicePeak - dynamicRangeDb
        let attack = 1 - exp(-(Double(hop) / sampleRate) / attackS)
        let release = 1 - exp(-(Double(hop) / sampleRate) / duckReleaseS)
        var level = 0.0
        var raw: [AutomationPoint] = []
        for (i, vDb) in voiceDbs.enumerated() {
            let bDb = bedDbs[i]
            let over = vDb > speakingFloor && bDb.isFinite ? bDb - (vDb - profile.headroomDb) : 0
            let target = min(profile.duckDb, max(0, over))
            level += (target > level ? attack : release) * (target - level)
            raw.append(AutomationPoint(t: jsRoundTo(times[i], 3), v: level < snapDb ? 0 : -jsRoundTo(level, 1)))
        }
        let hopSeconds = Double(hop) / sampleRate
        var tailTime = times.last ?? 0
        while level >= snapDb {
            level += release * -level
            tailTime += hopSeconds
            raw.append(AutomationPoint(t: jsRoundTo(tailTime, 3), v: level < snapDb ? 0 : -jsRoundTo(level, 1)))
        }
        var points = simplifyStepPoints(raw, stepDb)
        let duration = Double(voice.count) / sampleRate
        let last = points.last!
        let endTime = jsRoundTo(max(duration, last.t), 3)
        if !(last.v == 0 && last.t >= endTime) { points.append(AutomationPoint(t: endTime, v: 0)) }
        return points
    }

    public static func bandsToChain(_ bands: [Band]) -> FxChain {
        FxChain(nodes: bands.map { b in
            var p = AudioFx.defaultParams("peaking")
            p["frequency"] = .number(b.freq); p["gain"] = .number(b.gainDb); p["q"] = .number(b.q)
            return FxNode(type: "peaking", enabled: true, params: p)
        })
    }
}
