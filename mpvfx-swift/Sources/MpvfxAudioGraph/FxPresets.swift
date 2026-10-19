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

// FX presets, profiles and the Tone EQ.

public struct FxPresetNode: Sendable {
    public let type: String
    public let label: String?
    public let params: [String: JSONValue]
}

public struct FxPreset: Sendable {
    public let id: String
    public let label: String
    public let family: String
    public let description: String
    public let nodes: [FxPresetNode]
}

private func n(_ type: String, _ label: String, _ params: [String: JSONValue]) -> FxPresetNode { FxPresetNode(type: type, label: label, params: params) }
private func steep(_ type: String, _ f: Double, _ label: String) -> [FxPresetNode] {
    [n(type, label, ["frequency": .number(f), "q": .number(0.707), "poles": .string("2")]), n(type, label, ["frequency": .number(f), "q": .number(0.707), "poles": .string("2")])]
}
private func hp(_ f: Double, _ label: String) -> FxPresetNode { n("highpass", label, ["frequency": .number(f), "q": .number(0.707), "poles": .string("2")]) }
private func lp(_ f: Double, _ label: String) -> FxPresetNode { n("lowpass", label, ["frequency": .number(f), "q": .number(0.707), "poles": .string("2")]) }
private func pk(_ f: Double, _ g: Double, _ q: Double, _ label: String) -> FxPresetNode { n("peaking", label, ["frequency": .number(f), "gain": .number(g), "q": .number(q)]) }
private func shelf(_ type: String, _ f: Double, _ g: Double, _ label: String) -> FxPresetNode { n(type, label, ["frequency": .number(f), "gain": .number(g)]) }
private func nums(_ pairs: [(String, Double)]) -> [String: JSONValue] { Dictionary(uniqueKeysWithValues: pairs.map { ($0.0, .number($0.1)) }) }
private func sat(_ curve: String, _ threshold: Double, _ output: Double, _ label: String) -> FxPresetNode {
    n("saturate", label, ["type": .string(curve), "threshold": .number(threshold), "output": .number(output)])
}

public enum AudioFxPresets {
    public static let all: [FxPreset] = [
        FxPreset(id: "voice-clean", label: "Clean Voice", family: "voice", description: "Cuts rumble and mud, evens out the level, adds a little clarity.", nodes: [
            hp(80, "Remove Rumble"), pk(250, -3, 1.2, "Reduce Mud"),
            n("compressor", "Even Out Loudness", nums([("threshold", -20), ("ratio", 3), ("attack", 12), ("release", 180), ("makeup", 3)])),
            pk(3000, 2.5, 1, "Add Clarity"), n("limiter", "Peak Ceiling", nums([("limit", -1), ("attack", 5), ("release", 50)])),
        ]),
        FxPreset(id: "voice-broadcast", label: "Broadcast", family: "voice", description: "Denser and more forward — a radio-presenter sound.", nodes: [
            hp(90, "Remove Rumble"), pk(400, -3, 1.4, "Reduce Boxiness"),
            n("compressor", "Even Out Loudness", nums([("threshold", -24), ("ratio", 4), ("attack", 8), ("release", 150), ("makeup", 5)])),
            pk(2500, 3, 0.9, "Add Clarity"), shelf("highshelf", 8000, 2, "Add Air"), sat("tanh", -12, 0, "Warmth"),
            n("limiter", "Peak Ceiling", nums([("limit", -1), ("attack", 5), ("release", 60)])),
        ]),
        FxPreset(id: "voice-warm", label: "Close & Warm", family: "voice", description: "Intimate and lightly handled, for a voice close to the mic.", nodes: [
            hp(70, "Remove Rumble"), shelf("lowshelf", 180, 2, "Add Weight"),
            n("compressor", "Even Out Loudness", nums([("threshold", -18), ("ratio", 2.5), ("attack", 20), ("release", 250), ("makeup", 2)])),
            pk(3000, 1.5, 0.8, "Add Clarity"), n("limiter", "Peak Ceiling", nums([("limit", -1.5)])),
        ]),
        FxPreset(id: "rumble-cut", label: "Cut Rumble", family: "repair", description: "Removes traffic, handling and air-conditioning from under a voice.", nodes: [hp(100, "Cut Rumble")]),
        FxPreset(id: "room-gate", label: "Quiet Between Phrases", family: "repair", description: "Silences the gaps between words. Room tone under speech stays — this closes the pauses, it does not remove noise.", nodes: [
            n("gate", "Silence the Gaps", nums([("threshold", -45), ("range", -18), ("ratio", 10), ("attack", 2), ("release", 180)])),
        ]),
        FxPreset(id: "boom-tame", label: "Tame Boominess", family: "repair", description: "Takes out the chestiness of a voice too close to the mic.", nodes: [pk(200, -4, 1.4, "Tame Boominess")]),
        FxPreset(id: "harsh-tame", label: "Soften Harshness", family: "repair", description: "Rounds off a brittle upper-mid. Broad and always-on; sibilance proper wants the measuring version.", nodes: [pk(3200, -3, 1.6, "Soften Harshness")]),
        FxPreset(id: "telephone", label: "Telephone", family: "character", description: "Down the line — the narrow band of a phone call.", nodes:
            steep("highpass", 300, "Strip the Bass") + steep("lowpass", 3400, "Strip the Treble") + [
                pk(1200, 6, 1.2, "Phone Honk"), pk(550, -4, 1, "De-mud"), sat("tanh", -9, -2, "Circuit Grit"),
            ]),
        FxPreset(id: "radio-am", label: "AM Radio", family: "character", description: "Narrow, gritty and a little crushed.", nodes: [
            hp(220, "Strip the Bass"), lp(2200, "Strip the Treble"), pk(1200, -5, 0.9, "IF Droop"), shelf("lowshelf", 500, 4, "Boxy"),
            sat("tanh", -8, -1, "Radio Grit"), n("bitcrush", "Carrier Hiss", nums([("bits", 8), ("samples", 1), ("mix", 0.45)])),
        ]),
        FxPreset(id: "megaphone", label: "Megaphone", family: "character", description: "Shouted through a horn, with the slap that comes with it.", nodes: [
            hp(700, "Strip the Bass"), lp(4000, "Strip the Treble"), pk(1900, 14, 3, "Horn Honk"), pk(3200, 6, 3, "Horn Ring"),
            sat("hard", -5, -3, "Overdrive"), n("delay", "Horn Slap", nums([("time", 65), ("feedback", 0.2), ("mix", 0.28)])),
        ]),
        FxPreset(id: "lofi-tape", label: "Tape", family: "character", description: "Worn, warm and slightly unsteady, like a played-out cassette.", nodes: [
            lp(6500, "Tape Rolloff"), shelf("lowshelf", 120, 2, "Add Weight"), sat("tanh", -14, 0, "Tape Warmth"),
            n("bitcrush", "Tape Noise", nums([("bits", 12), ("samples", 2), ("mix", 0.35)])),
            n("chorus", "Wow & Flutter", nums([("delay", 6), ("depth", 0.6), ("speed", 0.4), ("mix", 0.15)])),
        ]),
        FxPreset(id: "pa-system", label: "Tannoy", family: "character", description: "Announced across a concourse.", nodes: [
            hp(250, "Strip the Bass"), lp(5000, "Strip the Treble"), pk(2400, 9, 2, "Tannoy Honk"), sat("tanh", -10, -1, "Driver Grit"),
            n("reverb", "Concourse", nums([("size", 0.54), ("damping", 0.48), ("wet", 0.25), ("dry", 0.8)])),
        ]),
        FxPreset(id: "intercom", label: "Intercom", family: "character", description: "Buzzed through a door panel, squelch and all.", nodes: [
            n("gate", "Squelch", nums([("threshold", -40), ("range", -30), ("ratio", 10), ("attack", 1), ("release", 120)])),
            hp(500, "Strip the Bass"), lp(3000, "Strip the Treble"), pk(2000, 6, 2, "Panel Honk"),
            n("bitcrush", "Crunch", nums([("bits", 11), ("samples", 1), ("mix", 0.3)])),
        ]),
        FxPreset(id: "doofus-worble", label: "Doofus Worble", family: "character", description: "Seasick and wobbling — no straight signal left.", nodes: [
            n("chorus", "Worble", nums([("delay", 14.6), ("depth", 2.57), ("speed", 10), ("mix", 1)])),
        ]),
        FxPreset(id: "chipmunk", label: "Chipmunk", family: "character", description: "Small, fast and squeaky.", nodes: [
            n("pitchshift", "Up High", nums([("semitones", 7), ("mix", 1)])), shelf("highshelf", 4000, 3, "Extra Sparkle"),
        ]),
        FxPreset(id: "giant", label: "Giant", family: "character", description: "Huge, slow and deep.", nodes: [
            n("pitchshift", "Down Low", nums([("semitones", -5), ("mix", 1)])), shelf("lowshelf", 150, 4, "Add Weight"),
            n("compressor", "Hold It Together", nums([("threshold", -18), ("ratio", 3), ("attack", 10), ("release", 120), ("knee", 6), ("makeup", 2), ("mix", 1)])),
        ]),
        FxPreset(id: "monster", label: "Monster", family: "character", description: "Deep, rough and too close.", nodes: [
            n("pitchshift", "Down Low", nums([("semitones", -8), ("mix", 1)])), sat("tanh", -12, -1, "Growl"),
            n("reverb", "Right Behind You", nums([("size", 0.3), ("damping", 0.5), ("wet", 0.22), ("dry", 0.85)])),
        ]),
        FxPreset(id: "room-tight", label: "Tight Room", family: "space", description: "A small hard room — presence without wash.", nodes: [
            n("reverb", "Tight Room", nums([("size", 0.25), ("damping", 0.6), ("wet", 0.18), ("dry", 0.9)])),
        ]),
        FxPreset(id: "room-natural", label: "Natural Room", family: "space", description: "Sounds recorded somewhere rather than nowhere.", nodes: [
            n("reverb", "Natural Room", nums([("size", 0.5), ("damping", 0.5), ("wet", 0.25), ("dry", 0.85)])),
        ]),
        FxPreset(id: "hall", label: "Hall", family: "space", description: "Long and open, for something that should sit far back.", nodes: [
            n("reverb", "Hall", nums([("size", 0.9), ("damping", 0.3), ("wet", 0.4), ("dry", 0.75)])),
        ]),
        FxPreset(id: "slap-echo", label: "Slap Echo", family: "space", description: "One quick repeat — rockabilly vocal, not a wash.", nodes: [
            n("delay", "Slap Echo", nums([("time", 110), ("feedback", 0.12), ("mix", 0.22)])),
        ]),
        FxPreset(id: "dub-throw", label: "Dub Throw", family: "space", description: "Repeats that trail off well behind the beat.", nodes: [
            n("delay", "Dub Throw", nums([("time", 375), ("feedback", 0.55), ("mix", 0.3)])),
        ]),
    ]
    public static let families = ["voice", "repair", "character", "space"]
    public static func preset(_ id: String) -> FxPreset? { all.first { $0.id == id } }
    public static func byFamily(_ family: String) -> [FxPreset] { all.filter { $0.family == family } }

    public static func nodes(_ preset: FxPreset, joining chain: FxChain) -> [FxNode] {
        var running = chain
        var out: [FxNode] = []
        for node in preset.nodes {
            let made = FxNode(type: node.type, id: running.mintNodeId(), fromPreset: preset.id, label: node.label, enabled: true,
                              params: AudioFx.normalize(node.type, node.params))
            out.append(made)
            running.nodes.append(made)
        }
        return out
    }

    public static func apply(_ chain: FxChain, _ preset: FxPreset, replaceChain: Bool = false) -> FxChain {
        if replaceChain { return FxChain(nodes: nodes(preset, joining: FxChain())) }
        guard let existing = chain.nodes.firstIndex(where: { $0.fromPreset == preset.id }) else {
            return FxChain(nodes: chain.nodes + nodes(preset, joining: chain))
        }
        let kept = chain.nodes.filter { $0.fromPreset != preset.id }
        let made = nodes(preset, joining: FxChain(nodes: kept))
        return FxChain(nodes: Array(kept.prefix(existing)) + made + Array(kept.dropFirst(existing)))
    }

    public static func activeIds(_ chain: FxChain) -> [String] {
        var seen: [String] = []
        for node in chain.nodes { if let p = node.fromPreset, !p.isEmpty, !seen.contains(p) { seen.append(p) } }
        return seen
    }
}

public enum AudioFxProfiles {
    static func clamp01(_ s: Double) -> Double { s.isFinite ? min(1, max(0, s)) : 0.5 }
    static func to2(_ v: Double) -> Double { jsRoundTo(v, 2) }

    public struct Profile: Sendable {
        public let label: String
        public let derives: [String]
        public let at: @Sendable (Double) -> [(String, Double)]
    }

    public static let profiles: [String: Profile] = [
        "compressor": Profile(label: "Evenness", derives: ["threshold", "ratio", "attack", "release", "makeup"]) { strength in
            let s = clamp01(strength)
            return [("threshold", to2(-12 - s * 18)), ("ratio", to2(2 + s * 4)), ("attack", to2(25 - s * 20)), ("release", to2(300 - s * 210)), ("makeup", to2(s * s * 9.5))]
        },
        "gate": Profile(label: "Tightness", derives: ["threshold", "range", "release"]) { strength in
            let s = clamp01(strength)
            return [("threshold", to2(-55 + s * 23)), ("range", to2(-10 - s * 20)), ("release", to2(120 - s * 105))]
        },
        "saturate": Profile(label: "Warmth", derives: ["threshold", "output"]) { strength in
            let s = clamp01(strength)
            return [("threshold", to2(-3 - s * 15)), ("output", to2(s * s * 2.8))]
        },
        "reverb": Profile(label: "Space", derives: ["size", "wet", "dry"]) { strength in
            let s = clamp01(strength)
            return [("size", to2(s <= 0.5 ? 0.25 + s * 0.6 : 0.55 + (s - 0.5) * 0.7)), ("wet", to2(0.15 + s * 0.3)), ("dry", to2(0.92 - s * 0.2))]
        },
        "bitcrush": Profile(label: "Crush", derives: ["bits", "samples", "mix"]) { strength in
            let s = clamp01(strength)
            return [("bits", to2(14 - s * 8)), ("samples", max(1, jsMathRound(1 + s * 3))), ("mix", to2(0.25 + s * 0.75))]
        },
    ]

    public static func apply(_ type: String, strength: Double, params: FxParams) -> FxParams {
        guard let profile = profiles[type] else { return params }
        var merged = params
        for (k, v) in profile.at(strength) { merged[k] = .number(v) }
        return AudioFx.normalize(type, merged)
    }

    public static func strength(_ type: String, params: FxParams) -> Double {
        guard let profile = profiles[type], let key = profile.derives.first, case let .number(value)? = params[key] else { return 0.5 }
        var best = 0.5, bestErr = Double.infinity
        for i in 0...100 {
            let s = to2(Double(i) / 100)
            guard let at = profile.at(s).first(where: { $0.0 == key })?.1 else { continue }
            let err = abs(at - value)
            if err < bestErr { bestErr = err; best = s }
        }
        return bestErr == .infinity ? 0.5 : to2(best)
    }
}

public struct AudioEqBand: Equatable, Sendable {
    public var name: String
    public var frequency: Double
    public var gain: Double
    public var q: Double?
    public var kind: String
    public init(name: String, frequency: Double, gain: Double, q: Double? = nil, kind: String) {
        self.name = name; self.frequency = frequency; self.gain = gain; self.q = q; self.kind = kind
    }
}

public enum AudioEq {
    public static let rangeDb = 12.0
    public static let threeBand = [AudioEqBand(name: "Bass", frequency: 200, gain: 0, kind: "lowshelf"),
                                   AudioEqBand(name: "Middle", frequency: 1000, gain: 0, q: 0.9, kind: "peaking"),
                                   AudioEqBand(name: "Treble", frequency: 4000, gain: 0, kind: "highshelf")]
    public static let fiveBand = [AudioEqBand(name: "Bass", frequency: 160, gain: 0, kind: "lowshelf"),
                                  AudioEqBand(name: "Warmth", frequency: 350, gain: 0, q: 1, kind: "peaking"),
                                  AudioEqBand(name: "Middle", frequency: 1000, gain: 0, q: 0.9, kind: "peaking"),
                                  AudioEqBand(name: "Clarity", frequency: 3000, gain: 0, q: 1, kind: "peaking"),
                                  AudioEqBand(name: "Air", frequency: 9000, gain: 0, kind: "highshelf")]

    static func clampGain(_ db: Double) -> Double { db.isFinite ? max(-rangeDb, min(rangeDb, db)) : 0 }

    public static func nodes(_ bands: [AudioEqBand], eqId: String, chain: FxChain) -> [FxNode] {
        var running = chain
        var out: [FxNode] = []
        for band in bands {
            var raw: [String: JSONValue] = ["frequency": .number(band.frequency), "gain": .number(clampGain(band.gain))]
            if band.kind == "peaking" { raw["q"] = .number(band.q ?? 1) }
            let made = FxNode(type: band.kind, id: running.mintNodeId(), label: band.name, fromEq: eqId, enabled: true, params: AudioFx.normalize(band.kind, raw))
            out.append(made)
            running.nodes.append(made)
        }
        return out
    }

    public static func add(_ chain: FxChain, bands: [AudioEqBand] = threeBand) -> (chain: FxChain, eqId: String) {
        let taken = Set(chain.nodes.compactMap(\.fromEq))
        var eqId = "eq1"
        var i = 1
        while taken.contains(eqId) { eqId = "eq\(i + 1)"; i += 1 }
        return (FxChain(nodes: chain.nodes + nodes(bands, eqId: eqId, chain: chain)), eqId)
    }

    public static func ids(_ chain: FxChain) -> [String] {
        var seen: [String] = []
        for node in chain.nodes { if let e = node.fromEq, !e.isEmpty, !seen.contains(e) { seen.append(e) } }
        return seen
    }

    public static func readBands(_ chain: FxChain, eqId: String) -> [AudioEqBand] {
        chain.nodes.compactMap { node in
            guard node.fromEq == eqId, ["lowshelf", "peaking", "highshelf"].contains(node.type) else { return nil }
            let p = node.params ?? FxParams()
            var f = 1000.0, g = 0.0, q: Double? = nil
            if case let .number(v)? = p["frequency"] { f = v }
            if case let .number(v)? = p["gain"] { g = v }
            if case let .number(v)? = p["q"] { q = v }
            return AudioEqBand(name: node.label ?? node.type, frequency: f, gain: g, q: q, kind: node.type)
        }
    }

    public static func setBandGain(_ chain: FxChain, eqId: String, band: String, gain: Double) -> FxChain {
        FxChain(nodes: chain.nodes.map { node in
            guard node.fromEq == eqId && node.label == band else { return node }
            var copy = node
            var p = node.params ?? FxParams()
            p["gain"] = .number(clampGain(gain))
            copy.params = AudioFx.normalize(node.type, p)
            return copy
        })
    }

    public static func remove(_ chain: FxChain, eqId: String) -> FxChain { FxChain(nodes: chain.nodes.filter { $0.fromEq != eqId }) }

    public static func summary(_ bands: [AudioEqBand]) -> String {
        let moved = bands.filter { abs($0.gain) >= 0.1 }
        if moved.isEmpty { return "Flat — nothing changed yet" }
        return moved.map { "\($0.name) \($0.gain > 0 ? "+" : "−")\(jsNumberToString(abs(jsRoundTo($0.gain, 1))))" }.joined(separator: ", ")
    }
}
