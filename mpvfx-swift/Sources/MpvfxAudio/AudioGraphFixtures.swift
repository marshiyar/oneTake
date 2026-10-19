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
import MpvfxAudioGraph

/// The every-FX graph project (same content as MpvfxAudioGraphTests' PlaybackIdentityTests.everythingProject at
/// 1.4 s): every core FX type, a preset wrap, FX-param automation, a volume lane, a group with its own chain and
/// envelope, pan and a muted track. `seconds` stretches the clip layout (automation keeps its times) for
/// benchmarks and pre-roll timing.
public enum AudioGraphFixtures {
    public static func everyFX(seconds total: Double = 1.4) -> AudioGraphProject {
        let k = total / 1.4
        func noise(_ seconds: Double, seed: UInt32, amp: Float = 0.3) -> [[Float]] {
            var s = seed
            let n = Int(seconds * 48000)
            func r() -> Float { s = s &* 1664525 &+ 1013904223; return Float(Double(s) / 4294967296 * 2 - 1) }
            let l = (0..<n).map { i in amp * (0.6 * Float(sin(Double(i) * 0.031)) + 0.4 * r()) }
            let rr = (0..<n).map { i in amp * (0.6 * Float(sin(Double(i) * 0.017)) + 0.4 * r()) }
            return [l, rr]
        }
        let chainA = try! AudioFx.parseChain(#"""
        {"version":1,"nodes":[
         {"type":"highpass","id":"n1","params":{"frequency":120,"poles":"2"}},
         {"type":"lowpass","id":"n2","params":{"frequency":9000,"poles":"1"}},
         {"type":"peaking","id":"n3","params":{"frequency":2500,"gain":4,"q":1.4}},
         {"type":"lowshelf","id":"n4","params":{"frequency":200,"gain":-3}},
         {"type":"highshelf","id":"n5","params":{"frequency":6000,"gain":2}},
         {"type":"compressor","id":"n6","fromPreset":"voice-clean","presetAmount":0.7,"params":{"threshold":-20}},
         {"type":"gate","id":"n7","fromPreset":"voice-clean","presetAmount":0.7,"params":{}},
         {"type":"saturate","id":"n8","params":{"type":"atan","oversample":4,"threshold":-6}},
         {"type":"bitcrush","id":"n9","params":{"bits":10,"samples":2,"mix":0.4}},
         {"type":"pitchshift","id":"n10","params":{"semitones":3,"mix":0.5}},
         {"type":"limiter","id":"n11","params":{"limit":-2}}]}
        """#)
        let chainB = try! AudioFx.parseChain(#"""
        {"version":1,"nodes":[
         {"type":"delay","id":"d1","params":{"time":120,"feedback":0.4,"mix":0.3}},
         {"type":"chorus","id":"c1","params":{}},
         {"type":"phaser","id":"p1","params":{"type":"1"}},
         {"type":"saturate","id":"s1","params":{"type":"cubic","oversample":2}},
         {"type":"gain","id":"g1","params":{"gain":-2}}]}
        """#)
        let groupChain = try! AudioFx.parseChain(#"{"version":1,"nodes":[{"type":"reverb","id":"r1","params":{"size":0.05,"wet":0.3}},{"type":"compressor","params":{}}]}"#)
        let autoA = try! AudioAutomation.parse(#"{"version":1,"lanes":[{"target":"volume","points":[{"t":0,"v":0.5},{"t":0.4,"v":1.1,"curve":0.4},{"t":0.9,"v":0.7}]},{"target":"fx.n3.frequency","points":[{"t":0,"v":800},{"t":0.8,"v":4000,"viaX":0.3,"viaY":0.7}]},{"target":"fx.preset.voice-clean","points":[{"t":0.1,"v":1},{"t":0.6,"v":0.2}]}]}"#)
        let autoB = try! AudioAutomation.parse(#"{"version":1,"lanes":[{"target":"fx.d1.time","points":[{"t":0,"v":80},{"t":0.5,"v":200}]},{"target":"fx.c1.speed","points":[{"t":0,"v":0.5},{"t":0.6,"v":3}]},{"target":"fx.g1.gain","points":[{"t":0,"v":-6},{"t":0.7,"v":0,"curve":-0.5}]}]}"#)
        let gAuto = try! AudioAutomation.parse(#"{"version":1,"lanes":[{"target":"volume","points":[{"t":0,"v":1},{"t":1.2,"v":0.4}]},{"target":"fx.r1.wet","points":[{"t":0,"v":0.1},{"t":1,"v":0.6}]}]}"#)
        return AudioGraphProject(duration: total, tracks: [
            AudioGraphTrack(id: "a", stem: noise(1.0 * k, seed: 1), start: 0.05 * k, end: 1.0 * k, volume: 0.9, pan: -0.3, fxChain: chainA, automation: autoA, groupId: "bus"),
            AudioGraphTrack(id: "b", stem: noise(0.8 * k, seed: 2), start: 0.3 * k, end: 1.1 * k, volume: 1.2, fxChain: chainB, automation: autoB),
            AudioGraphTrack(id: "c", stem: noise(0.5 * k, seed: 3), start: 0.2 * k, end: 0.7 * k, volume: 0.7, groupId: "bus"),
            AudioGraphTrack(id: "m", stem: noise(0.5 * k, seed: 4), start: 0, end: 0.5 * k, muted: true),
        ], groups: [AudioGraphGroup(id: "bus", volume: 0.8, pan: 0.2, fxChain: groupChain, automation: gAuto)])
    }
}
