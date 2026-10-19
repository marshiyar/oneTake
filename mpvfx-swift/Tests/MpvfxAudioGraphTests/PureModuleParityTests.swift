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

/// The graph's pure modules, compared against recorded reference values (reference.json).
final class PureModuleParityTests: XCTestCase {
    let ref = Fixtures.reference

    func testNormalizeParams() {
        for c in ref["normalize"]!.array {
            let raw = try! parseJSON(c["raw"]!.str)
            var dict: [String: JSONValue] = [:]
            if case let .object(e) = raw { for (k, v) in e { dict[k] = v.stringValue == "Infinity" ? .number(.infinity) : v } }
            XCTAssertEqual(AudioFx.normalize(c["type"]!.str, dict).json.json, c["out"]!.json, c["type"]!.str)
        }
    }

    func testChainCodec() {
        for c in ref["chains"]!.array {
            do {
                let chain = try AudioFx.parseChain(c["doc"]!.str)
                XCTAssertEqual(AudioFx.serializeChain(chain), c["ok"]?.str, c["doc"]!.str)
            } catch {
                let expected = c["error"]?.str ?? "<no error>"
                if expected.hasPrefix("Chain file is not valid JSON:") {
                    // V8's JSON.parse wording is engine-specific; only the prefix is the module's.
                    XCTAssertTrue("\(error)".hasPrefix("Chain file is not valid JSON:"), "\(error)")
                } else {
                    XCTAssertEqual("\(error)", expected)
                }
            }
        }
    }

    func testAutomationParseResolveSample() {
        let chain = try! AudioFx.parseChain(#"{"version":1,"nodes":[{"type":"lowpass","id":"n1","params":{}},{"type":"gain","id":"n2","fromPreset":"voice-clean","params":{}}]}"#)
        for c in ref["automation"]!.array {
            do {
                let parsed = try AudioAutomation.parse(c["doc"]!.str)
                XCTAssertEqual(AudioAutomation.serialize(parsed), c["parsed"]?.str)
                let resolved = AudioAutomation.resolve(parsed, chain)
                XCTAssertEqual(AudioAutomation.serialize(resolved), c["resolved"]?.str)
                for (lane, s) in zip(resolved.lanes, c["samples"]!.array) {
                    let range = AudioAutomation.resolveRange(lane.target, chain)!
                    XCTAssertEqual(range.scale.rawValue, s["scale"]!.str)
                    for (i, v) in s["values"]!.array.enumerated() {
                        let t = -0.1 + Double(i) * 0.035
                        XCTAssertTrue(ulpClose(AudioAutomation.sampleLane(lane, t, range.scale), v.num), "\(lane.target) @\(t): \(AudioAutomation.sampleLane(lane, t, range.scale)) vs \(v.num)")
                    }
                }
            } catch {
                XCTAssertEqual("\(error)", c["error"]?.str ?? "<no error>")
            }
        }
    }

    func testShapeProgress() {
        for c in ref["shapeProgress"]!.array {
            let p = c["point"]!
            let pt = AutomationPoint(t: 0, v: 0, curve: p["curve"]?.numberValue, viaX: p["viaX"]?.numberValue, viaY: p["viaY"]?.numberValue)
            for (i, v) in c["values"]!.array.enumerated() {
                XCTAssertTrue(ulpClose(AudioAutomation.shapeProgress(Double(i) / 20, pt), v.num), "\(p.json) \(i)")
            }
        }
    }

    func testChainTail() {
        for c in ref["tails"]!.array {
            let chain = try! AudioFx.parseChain(c["chain"]!.json)
            let a = c["automation"].flatMap { $0 == .null ? nil : automationFromJSON($0) }
            XCTAssertEqual(FxTail.chainSeconds(chain, a), c["seconds"]!.num)
        }
    }

    func testPresets() {
        let presets = ref["presets"]!.array
        XCTAssertEqual(presets.count, AudioFxPresets.all.count)
        for (c, p) in zip(presets, AudioFxPresets.all) {
            XCTAssertEqual(p.id, c["id"]!.str); XCTAssertEqual(p.family, c["family"]!.str)
            XCTAssertEqual(AudioFx.serializeChain(AudioFxPresets.apply(FxChain(), p)), c["chain"]!.str, p.id)
        }
        let base = try! AudioFx.parseChain(#"{"version":1,"nodes":[{"type":"gain","id":"n1"},{"type":"limiter","id":"n2","fromPreset":"rumble-cut"},{"type":"highpass","id":"n3","fromPreset":"rumble-cut"}]}"#)
        XCTAssertEqual(AudioFx.serializeChain(AudioFxPresets.apply(base, AudioFxPresets.preset("rumble-cut")!)), ref["presetReapply"]!.str)
        XCTAssertEqual(AudioFx.serializeChain(AudioFxPresets.apply(base, AudioFxPresets.preset("hall")!)), ref["presetAppend"]!.str)
    }

    func testProfiles() {
        for c in ref["profiles"]!.array {
            let type = c["type"]!.str
            for at in c["at"]!.array {
                XCTAssertEqual(AudioFxProfiles.apply(type, strength: at["s"]!.num, params: FxParams()).json.json, at["params"]!.json, "\(type) \(at["s"]!.json)")
            }
            for (s, inv) in zip([0, 0.13, 0.5, 0.77, 1], c["inverse"]!.array) {
                XCTAssertEqual(AudioFxProfiles.strength(type, params: AudioFxProfiles.apply(type, strength: s, params: FxParams())), inv.num, "\(type) inverse \(s)")
            }
        }
    }

    func testEq() {
        let e = ref["eq"]!
        let a = AudioEq.add(try! AudioFx.parseChain(#"{"version":1,"nodes":[{"type":"gain","id":"n1"}]}"#))
        let b = AudioEq.add(a.chain, bands: AudioEq.fiveBand)
        XCTAssertEqual([a.eqId, b.eqId], e["ids"]!.array.map(\.str))
        let c = AudioEq.setBandGain(b.chain, eqId: "eq1", band: "Bass", gain: 30)
        let d = AudioEq.setBandGain(c, eqId: "eq2", band: "Clarity", gain: -4.26)
        XCTAssertEqual(AudioFx.serializeChain(d), e["chain"]!.str)
        func bandsJSON(_ bands: [AudioEqBand]) -> String {
            "[" + bands.map { b in
                var o: [(String, JSONValue)] = [("name", .string(b.name)), ("frequency", .number(b.frequency)), ("gain", .number(b.gain))]
                if let q = b.q { o.append(("q", .number(q))) }
                o.append(("kind", .string(b.kind)))
                return stringifyJSON(.object(o))
            }.joined(separator: ",") + "]"
        }
        XCTAssertEqual(bandsJSON(AudioEq.readBands(d, eqId: "eq1")), e["bands1"]!.json)
        XCTAssertEqual(bandsJSON(AudioEq.readBands(d, eqId: "eq2")), e["bands2"]!.json)
        XCTAssertEqual(AudioEq.summary(AudioEq.readBands(d, eqId: "eq1")), e["summary1"]!.str)
        XCTAssertEqual(AudioEq.summary(AudioEq.readBands(d, eqId: "eq2")), e["summary2"]!.str)
        XCTAssertEqual(AudioEq.summary(AudioEq.threeBand), e["summaryFlat"]!.str)
        XCTAssertEqual(AudioFx.serializeChain(AudioEq.remove(d, eqId: "eq1")), e["removed"]!.str)
    }

    func testLeveller() {
        let voice = Fixtures.f32("voice.f32")
        for c in ref["leveller"]!.array {
            XCTAssertEqual(pointsJSON(AudioLeveller.analyse(voice, sampleRate: 48000, strength: c["strength"]!.num)), c["points"]!.json)
        }
        XCTAssertEqual(AudioLeveller.summary(AudioLeveller.analyse(voice, sampleRate: 48000, strength: 0.5)), ref["levellerSummary"]!.str)
        let r = AudioLeveller.result(try! AudioFx.parseChain(#"{"version":1,"nodes":[{"type":"gain","id":"n1"},{"type":"limiter","id":"n2"}]}"#), samples: voice, sampleRate: 48000, strength: 0.5)!
        XCTAssertEqual(AudioFx.serializeChain(r.chain), ref["levellerResult"]!["chain"]!.str)
        XCTAssertEqual(AudioAutomation.serialize(r.automation), ref["levellerResult"]!["automation"]!.str)
    }

    func testCarve() {
        let voice = Fixtures.f32("voice.f32"), bed = Fixtures.f32("bed.f32")
        for c in ref["carve"]!.array {
            let s = c["strength"]!.num
            let profile = AudioCarve.profile(s)
            let p = c["profile"]!
            XCTAssertEqual([profile.maxCutDb, Double(profile.bands), profile.q, profile.intelligibilityBias, profile.duckDb, profile.headroomDb],
                           ["maxCutDb", "bands", "q", "intelligibilityBias", "duckDb", "headroomDb"].map { p[$0]!.num })
            let bands = AudioCarve.analyseBands(voice, sampleRate: 48000, profile: profile)
            XCTAssertEqual(bands.map { [$0.freq, $0.gainDb, $0.q] }, c["bands"]!.array.map { [$0["freq"]!.num, $0["gainDb"]!.num, $0["q"]!.num] }, "bands @\(s)")
            let dyn = AudioCarve.analyseDynamics(voice, sampleRate: 48000, bands: bands)
            XCTAssertEqual(dyn.count, c["dynamics"]!.array.count)
            for (d, e) in zip(dyn, c["dynamics"]!.array) {
                XCTAssertEqual(d.freq, e["freq"]!.num)
                XCTAssertEqual(pointsJSON(d.points), e["points"]!.json, "dynamics @\(s) \(d.freq)")
            }
            XCTAssertEqual(pointsJSON(AudioCarve.analyseDuck(voice, bed: bed, sampleRate: 48000, profile: profile, offsetSeconds: 0.37)), c["duck"]!.json, "duck @\(s)")
            XCTAssertEqual(AudioFx.serializeChain(AudioCarve.bandsToChain(bands)), c["chain"]!.str)
        }
        let mixed = AudioCarve.mixSources([.init(samples: [1, 2, 3], offsetSeconds: -1 / 48000.0), .init(samples: [0.5, 0.5], offsetSeconds: 2 / 48000.0)], sampleRate: 48000)
        XCTAssertEqual(mixed.map(Double.init), ref["carveMix"]!.array.map(\.num))
        for c in ref["carveNames"]!.array {
            let parts: [String?] = c["parts"]!.array.map(\.str)
            XCTAssertEqual(AudioCarve.classify(parts).rawValue, c["kind"]!.str, "\(parts)")
            XCTAssertEqual(AudioCarve.couldBeCarveBed(parts), c["bed"]! == .bool(true))
            XCTAssertEqual(AudioCarve.isNamedCarveBed(parts), c["named"]! == .bool(true))
        }
        for c in ref["carveSettings"]!.array {
            let raw: JSONValue? = c["raw"]!.str == "undefined" ? nil : try! parseJSON(c["raw"]!.str)
            let s = AudioCarve.normalizeSettings(raw)
            let o = c["out"]!
            XCTAssertEqual(s.enabled, o["enabled"]! == .bool(true)); XCTAssertEqual(s.sources, o["sources"]!.array.map(\.str)); XCTAssertEqual(s.strength, o["strength"]!.num)
        }
    }

    func testVolumeEnvelopeHelpers() {
        let a = try! AudioAutomation.parse(#"{"version":1,"lanes":[{"target":"volume","points":[{"t":0.1,"v":0.2,"curve":0.6},{"t":0.4,"v":1.5},{"t":0.6,"v":0.3}]}]}"#)
        let kf = VolumeEnvelope.laneKeyframes(AudioAutomation.resolve(a, nil), trackStart: 0.25, duration: 0.9)!
        let expected = ref["volumeLaneKeyframes"]!.array
        XCTAssertEqual(kf.count, expected.count)
        for (k, e) in zip(kf, expected) { XCTAssertTrue(ulpClose(k.time, e["time"]!.num) && ulpClose(k.volume, e["volume"]!.num), "\(k) vs \(e.json)") }
        var w = VolumeEnvelope.walker(kf, trackStart: 0.25, baseVolume: 0.7)!
        for (i, e) in ref["envelopeGains"]!.array.enumerated() { let g = w.gain(at: Double(i) * 0.02); XCTAssertTrue(ulpClose(g, e.num), "gain \(i): \(g) vs \(e.num)") }
        let n = VolumeEnvelope.normalise([.init(time: 0.5, volume: 9), .init(time: 0.3, volume: 0.2), .init(time: 0.3 + 1e-10, volume: 0.4), .init(time: .nan, volume: 1)], trackStart: 0.1, baseVolume: 0.8)
        XCTAssertEqual(n.map { [$0.time, $0.volume] }, ref["normaliseEnvelope"]!.array.map { [$0["time"]!.num, $0["volume"]!.num] })
    }

    func testReverbImpulseBitExact() {
        for (size, damping, name) in [(0.05, 0.5, "ir-0.05-0.5.f32"), (0.13, 0.9, "ir-0.13-0.9.f32")] {
            let ir = synthesizeReverbImpulse(sampleRate: 48000, size: size, damping: damping)
            let expected = Fixtures.f32(name)
            XCTAssertEqual(ir.count, expected.count)
            let d = peakDiffDb(ir, expected)
            parityLog("reverb IR size=\(size) damping=\(damping): \(fmtDb(d.db))")
            XCTAssertEqual(d.peak, 0, "IR \(name) differs at \(d.index)")
        }
    }
}
