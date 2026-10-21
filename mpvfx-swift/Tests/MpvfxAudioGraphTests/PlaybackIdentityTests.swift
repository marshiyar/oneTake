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
import XCTest
@testable import MpvfxAudioGraph

/// Live playback (real-time block API) and offline export are the same pull
/// path; any block partition must give bit-identical samples.
final class PlaybackIdentityTests: XCTestCase {
    /// Every core FX type, a preset wrap, FX-param automation, a volume lane, a
    /// group with its own chain and envelope, pan, and a muted track.
    static func everythingProject() -> AudioGraphProject {
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
         {"type":"limiter","id":"n11","params":{"limit":-2}},
         {"type":"denoise","id":"n12","params":{"amount":0.8,"learn":100}}]}
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
        return AudioGraphProject(duration: 1.4, tracks: [
            AudioGraphTrack(id: "a", stem: noise(1.0, seed: 1), start: 0.05, end: 1.0, volume: 0.9, pan: -0.3, fxChain: chainA, automation: autoA, groupId: "bus"),
            AudioGraphTrack(id: "b", stem: noise(0.8, seed: 2), start: 0.3, end: 1.1, volume: 1.2, fxChain: chainB, automation: autoB),
            AudioGraphTrack(id: "c", stem: noise(0.5, seed: 3), start: 0.2, end: 0.7, volume: 0.7, groupId: "bus"),
            AudioGraphTrack(id: "m", stem: noise(0.5, seed: 4), start: 0, end: 0.5, muted: true),
        ], groups: [AudioGraphGroup(id: "bus", volume: 0.8, pan: 0.2, fxChain: groupChain, automation: gAuto)])
    }

    func identity(_ project: AudioGraphProject, seed: UInt64, label: String) {
        let offline = AudioGraphRenderer.renderOffline(project)
        XCTAssertEqual(offline.count, project.totalFrames * 2)
        var rng = SplitMix(seed)
        for pass in 0..<3 {
            let live = AudioGraphRenderer(project)
            var out: [Float] = []
            let sizes = pass == 0 ? [128] : pass == 1 ? [1, 7, 64, 333, 480, 1024, 4096] : []
            while live.position < live.totalFrames {
                let n = sizes.isEmpty ? Int(rng.next() % 2000) + 1 : sizes[Int(rng.next() % UInt64(sizes.count))]
                out += live.render(n)
            }
            XCTAssertEqual(live.render(64).count, 0)
            let d = peakDiffDb(out, offline)
            if pass == 2 { parityLog("playback vs offline \(label): peak diff \(fmtDb(d.db)) over \(offline.count / 2) frames") }
            XCTAssertTrue(out == offline, "\(label) pass \(pass) differs at sample \(d.index)")
        }
    }

    func testEverythingProjectBlocksEqualOffline() {
        let p = Self.everythingProject()
        let out = AudioGraphRenderer.renderOffline(p)
        XCTAssertTrue(out.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(out.map { abs($0) }.max()!, 0.01)
        identity(p, seed: 42, label: "every-FX project")
    }

    func testFixtureProjectsBlocksEqualOffline() {
        for name in ["flat", "grouped", "busGain"] { identity(RenderParityTests.project(name), seed: 7, label: name) }
    }

    func testRendererIsDeterministicAcrossInstances() {
        let p = Self.everythingProject()
        XCTAssertTrue(AudioGraphRenderer.renderOffline(p) == AudioGraphRenderer.renderOffline(p))
    }
}

struct SplitMix { var s: UInt64; init(_ s: UInt64) { self.s = s }
    mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) } }
