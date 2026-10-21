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

/// The plain-language layer over the effect registry (the audio-fx copy): what to call an
/// effect and its knobs in front of an author, the sentence a rack row reads, and the complaint each preset answers.
/// The registry (`AudioFx.definitions`) stays the authority on ranges, steps and units; only the words live here.
public enum AudioFxCopy {
    public struct Effect: Sendable {
        public let title: String
        public let does: String
        /// The knob the module opens on: a real parameter key, or "strength" for a derived profile knob.
        public let primary: String
        public let ends: (low: String, high: String)
        /// Plain parameter names by key.
        public let params: [String: String]
    }

    public static let effects: [String: Effect] = [
        "gain": Effect(title: "Volume", does: "Turns this track up or down.", primary: "gain", ends: ("Silent", "Louder"), params: ["gain": "Level"]),
        "highpass": Effect(title: "Remove Rumble", does: "Cuts the very bottom — traffic, footsteps, air conditioning, hands on the mic.",
                           primary: "frequency", ends: ("Only the deepest", "Thins it out"),
                           params: ["frequency": "Cut below", "q": "Sharpness", "poles": "Steepness"]),
        "lowpass": Effect(title: "Muffle", does: "Takes the top off, like the sound is coming through a door.",
                          primary: "frequency", ends: ("Very muffled", "Barely changed"),
                          params: ["frequency": "Cut above", "q": "Sharpness", "poles": "Steepness"]),
        "peaking": Effect(title: "Shape One Range", does: "Lifts or lowers one part of the sound and leaves the rest alone.",
                          primary: "gain", ends: ("Take it out", "Bring it forward"),
                          params: ["frequency": "Where", "gain": "How much", "q": "How wide"]),
        "lowshelf": Effect(title: "Bass", does: "More or less weight underneath everything.", primary: "gain", ends: ("Thinner", "Heavier"),
                           params: ["frequency": "Up to", "gain": "How much"]),
        "highshelf": Effect(title: "Brightness", does: "More or less sparkle at the top.", primary: "gain", ends: ("Duller", "Brighter"),
                            params: ["frequency": "From", "gain": "How much"]),
        "compressor": Effect(title: "Even Out Loudness",
                             does: "Brings the quiet parts up and holds the loud parts down, so nothing jumps out at the listener.",
                             primary: "strength", ends: ("Barely touched", "Very even, quite squashed"),
                             params: ["threshold": "Starts working at", "ratio": "How hard", "attack": "How fast it grabs",
                                      "release": "How fast it lets go", "knee": "How gradual", "makeup": "Volume back up", "mix": "Blend with the original"]),
        "deesser": Effect(title: "De-ess", does: "Tames sharp s and sh sounds only when they get loud. Listen isolates the detector band.",
                          primary: "threshold", ends: ("Catches quieter s sounds", "Only the loudest"),
                          params: ["frequency": "Listen around", "threshold": "Starts working at", "range": "Maximum reduction",
                                   "attack": "How fast it catches", "release": "How fast it recovers", "listen": "Listen to detector"]),
        "limiter": Effect(title: "Peak Ceiling", does: "Nothing gets louder than this, ever. A safety net at the end of the chain.",
                          primary: "limit", ends: ("A lot of headroom", "Right up to the edge"),
                          params: ["limit": "Never exceed", "attack": "How fast it catches", "release": "How fast it recovers", "level_out": "Level after"]),
        "gate": Effect(title: "Silence the Gaps",
                       does: "Mutes the pauses. Whatever sits underneath stays — this closes the gaps, it does not remove noise.",
                       primary: "strength", ends: ("Only true silence", "Cuts quiet parts too"),
                       params: ["threshold": "Quieter than this is a gap", "range": "How far to duck the gaps", "ratio": "How hard",
                                "attack": "How fast it opens", "release": "How fast it closes", "knee": "How gradual"]),
        "saturate": Effect(title: "Warmth", does: "Adds a little grit and density, the way analogue gear does.",
                           primary: "strength", ends: ("Just a sheen", "Openly distorted"),
                           params: ["type": "Character", "threshold": "How much drive", "output": "Level after", "oversample": "Quality"]),
        "bitcrush": Effect(title: "Lo-Fi", does: "Crushes the sound down to fewer steps, like an old sampler or a bad phone line.",
                           primary: "strength", ends: ("Slightly gritty", "Destroyed"),
                           params: ["bits": "How many steps", "samples": "How rough", "mix": "Blend with the original"]),
        "pitchshift": Effect(title: "Higher or Lower", does: "Shifts everything up or down without changing its speed.",
                             primary: "semitones", ends: ("Much deeper", "Much higher"),
                             params: ["semitones": "How far", "mix": "Blend with the original"]),
        "delay": Effect(title: "Echo", does: "Repeats the sound after a gap.", primary: "mix", ends: ("A hint", "Washed out"),
                        params: ["time": "Gap between repeats", "feedback": "How many repeats", "mix": "How loud"]),
        "reverb": Effect(title: "Room", does: "Puts the sound somewhere, instead of nowhere.", primary: "strength",
                         ends: ("A small tight room", "A big open hall"),
                         params: ["size": "How big the space is", "damping": "How soft the walls are", "wet": "How much room", "dry": "How much original"]),
        "chorus": Effect(title: "Thicken", does: "Doubles the sound slightly out of tune, which makes it wider and less exact.",
                         primary: "mix", ends: ("Just wider", "Obviously wobbling"),
                         params: ["delay": "Spread", "depth": "How much wobble", "speed": "How fast it wobbles", "mix": "How much"]),
        "phaser": Effect(title: "Swirl", does: "A filter that sweeps up and down, giving a moving, hollow shimmer.",
                         primary: "out_gain", ends: ("Subtle", "Strong"),
                         params: ["in_gain": "Depth in", "out_gain": "How strong", "delay": "Where it sweeps", "decay": "How resonant",
                                  "speed": "How fast it sweeps", "type": "Shape of the sweep"]),
    ]

    public static func title(_ type: String) -> String { effects[type]?.title ?? AudioFx.definition(type)?.label ?? type }
    public static func paramLabel(_ type: String, _ key: String, fallback: String) -> String { effects[type]?.params[key] ?? fallback }

    /// The real parameter a module opens on (nil for the derived-knob effects and anything unknown).
    public static func primaryParam(_ type: String) -> String? {
        guard let p = effects[type]?.primary, p != "strength", let def = AudioFx.definition(type),
              def.params.contains(where: { $0.key == p }) else { return nil }
        return p
    }

    /// Which everyday complaint each preset answers.
    public static let presetProblem: [String: String] = [
        "voice-clean": "My voice sounds amateur", "voice-broadcast": "I want it to sound like radio",
        "voice-warm": "I want it intimate and close", "rumble-cut": "There's a hum or thump underneath",
        "room-gate": "I can hear the room in the gaps", "boom-tame": "It sounds boomy",
        "harsh-tame": "It's harsh and tiring to listen to", "telephone": "Make it sound like a phone call",
        "radio-am": "Make it sound like an old radio", "megaphone": "Make it sound shouted through a horn",
        "lofi-tape": "Make it sound like an old tape", "pa-system": "Make it sound like a station announcement",
        "intercom": "Make it sound like a door intercom", "doofus-worble": "Make it wobble like it is seasick",
        "chipmunk": "Make it small and squeaky", "giant": "Make it huge and deep", "monster": "Make it a monster",
        "room-tight": "It sounds dry and stuck to the speaker", "room-natural": "It should sound like a real place",
        "hall": "It should sound far away and big", "slap-echo": "I want one quick echo", "dub-throw": "I want long trailing echoes",
    ]

    static func n(_ p: FxParams, _ key: String, _ fallback: Double = 0) -> Double {
        if case let .number(v)? = p[key] { return v }
        return fallback
    }
    static func hz(_ x: Double) -> String {
        if x >= 1000 {
            let k = x / 1000
            return (x.truncatingRemainder(dividingBy: 1000) == 0 ? String(format: "%.0f", k) : String(format: "%.1f", k)) + " kHz"
        }
        return "\(Int(jsMathRound(x))) Hz"
    }
    static func s(_ v: Double) -> String { jsNumberToString(v) }
    static func strength(_ x: Double, _ words: [String]) -> String { x < 0.34 ? words[0] : x < 0.67 ? words[1] : words[2] }

    /// What an effect is doing to the sound, as the sentence under its rack row (SUMMARY).
    public static func summary(_ type: String, _ p: FxParams) -> String? {
        switch type {
        case "gain":
            let g = n(p, "gain")
            return g == 0 ? "No change" : g > 0 ? "Up \(s(g)) dB" : "Down \(s(abs(g))) dB"
        case "highpass": return "Cutting everything below \(hz(n(p, "frequency")))"
        case "lowpass": return "Muffled above \(hz(n(p, "frequency")))"
        case "peaking":
            let g = n(p, "gain")
            return g == 0 ? "Sitting on \(hz(n(p, "frequency"))), doing nothing yet"
                : "\(g > 0 ? "Lifting" : "Cutting") \(hz(n(p, "frequency"))) by \(s(abs(g))) dB"
        case "lowshelf":
            let g = n(p, "gain")
            return g == 0 ? "Doing nothing yet" : "\(g > 0 ? "More" : "Less") weight below \(hz(n(p, "frequency")))"
        case "highshelf":
            let g = n(p, "gain")
            return g == 0 ? "Doing nothing yet" : "\(g > 0 ? "More" : "Less") sparkle above \(hz(n(p, "frequency")))"
        case "compressor": return "Evening out — \(strength(min(1, (n(p, "ratio", 3) - 1) / 7), ["gentle", "moderate", "firm"]))"
        case "deesser": return "Taming s sounds around \(s(n(p, "frequency", 6500))) Hz, up to \(s(-n(p, "range", -18))) dB"
        case "limiter": return "Nothing louder than \(s(n(p, "limit", -1))) dB"
        case "gate": return "Closing gaps quieter than \(s(n(p, "threshold", -45))) dB"
        case "saturate": return "\(strength(min(1, abs(n(p, "threshold", -6)) / 30), ["A little", "Some", "Heavy"])) warmth"
        case "bitcrush": return "Crushed to \(s(n(p, "bits", 8))) bits"
        case "pitchshift":
            let st = n(p, "semitones")
            return st == 0 ? "Unchanged pitch" : "\(st > 0 ? "Up" : "Down") \(s(abs(st))) semitones"
        case "delay": return "Echo every \(s(n(p, "time", 250))) ms"
        case "reverb":
            return "\(strength(n(p, "size", 0.7), ["A small", "A medium", "A large"])) room, \(strength(n(p, "wet", 0.35), ["lightly", "moderately", "heavily"]))"
        case "chorus": return "Thickened\(n(p, "mix", 0.5) > 0.6 ? ", wobbling" : "")"
        case "phaser": return "Swirling"
        default: return nil
        }
    }
}

/// The add menu's named jobs: effects with their purpose and starting settings already chosen.
public struct FxJob: Sendable {
    public let id: String, label: String, does: String, type: String
    public let params: [(String, Double)]
}

public enum AudioFxJobs {
    public static let all: [FxJob] = [
        FxJob(id: "de-ess", label: "De-ess", does: "Sharp s and sh sounds jump out of the voice.", type: "deesser", params: []),
        FxJob(id: "tame-boominess", label: "Tame Boominess", does: "Too much low-end body — it booms.", type: "peaking",
              params: [("frequency", 200), ("gain", -4), ("q", 1.4)]),
        FxJob(id: "reduce-mud", label: "Reduce Mud", does: "Muffled, like it is behind cardboard.", type: "peaking",
              params: [("frequency", 250), ("gain", -3), ("q", 1.2)]),
        FxJob(id: "reduce-boxiness", label: "Reduce Boxiness", does: "Sounds like a small room, or a box.", type: "peaking",
              params: [("frequency", 400), ("gain", -3), ("q", 1.4)]),
        FxJob(id: "add-clarity", label: "Add Clarity", does: "It is hard to make out — it sits back.", type: "peaking",
              params: [("frequency", 3000), ("gain", 2.5), ("q", 1)]),
        FxJob(id: "soften-harshness", label: "Soften Harshness", does: "Harsh and tiring to listen to.", type: "peaking",
              params: [("frequency", 3200), ("gain", -3), ("q", 1.6)]),
    ]
    /// Effect ids the jobs stand in for (the add menu offers the jobs instead).
    public static let types: Set<String> = Set(all.map(\.type))

    /// The node a job adds: an ordinary effect carrying the job's name (audioFxJobNode).
    public static func node(_ job: FxJob, joining chain: FxChain) -> FxNode {
        var p = AudioFx.defaultParams(job.type)
        for (k, v) in job.params { p[k] = .number(v) }
        return FxNode(type: job.type, version: 2, id: chain.mintNodeId(), label: job.label, enabled: true, params: AudioFx.normalize(job.type, p, version: 2))
    }

    /// One effect appended at the values its module opens on (FxSection `withEffect`): through the profile for the
    /// derived-knob effects, so the knob and the mechanism agree from the first frame.
    public static func effectNode(_ type: String, joining chain: FxChain) -> FxNode {
        let defaults = AudioFx.defaultParams(type, version: 2)
        let params = AudioFxProfiles.profiles[type] != nil ? AudioFxProfiles.apply(type, strength: 0.5, params: defaults, version: 2) : defaults
        return FxNode(type: type, version: 2, id: chain.mintNodeId(), enabled: true, params: params)
    }
}
