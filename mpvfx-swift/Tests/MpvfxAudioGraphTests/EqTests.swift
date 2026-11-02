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

/// The parametric EQ: the response the rack draws is the gain a sine measures through the unit, each band type does
/// what it says, and the node keeps its settings through the chain file and live edits.
final class EqTests: XCTestCase {
    let sr = 48000.0

    func eq(_ values: [String: JSONValue]) -> FxNode {
        FxNode(type: "eq", version: 2, id: "eq1", params: AudioFx.normalize("eq", values, version: 2))
    }

    /// Steady-state gain in dB of a 0.25 sine at `f` through the unit built for `n` (the same probe as `FxResponseTests`).
    func measuredDb(_ n: FxNode, _ f: Double) -> Double {
        let unit = buildFxUnit(n.type, n.params, sampleRate: sr, version: 2)
        let count = 24000
        var y: [Float] = [], x: [Float] = []
        var q = 0
        while q < count {
            let b = (0..<dspBlockSize).map { (i: Int) -> Float in Float(0.25 * sin(2 * Double.pi * f * Double(q + i) / sr)) }
            x += b; y += unit.process([b, b], frame: q)[0]; q += dspBlockSize
        }
        func rms(_ a: [Float]) -> Double { (a[12000...].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(a.count - 12000)).squareRoot() }
        return 20 * log10(rms(y) / rms(x))
    }

    /// 1/3-octave probes from 40 Hz to 16 kHz.
    var probes: [Double] { (0...25).map { 40 * pow(2, Double($0) / 3) }.filter { $0 < 16000 } }

    func testDrawnResponseIsWhatTheUnitDoesForEveryBandShape() {
        let cases: [(String, [String: JSONValue])] = [
            ("bell", ["bands": 1, "band1.type": "bell", "band1.freq": 1000, "band1.gain": 8, "band1.q": 1.6]),
            ("bell cut", ["bands": 1, "band1.type": "bell", "band1.freq": 250, "band1.gain": -12, "band1.q": 0.5]),
            ("low shelf", ["bands": 1, "band1.type": "lowshelf", "band1.freq": 200, "band1.gain": -9]),
            ("high shelf", ["bands": 1, "band1.type": "highshelf", "band1.freq": 4000, "band1.gain": 6]),
            ("notch", ["bands": 1, "band1.type": "notch", "band1.freq": 1000, "band1.q": 4]),
            ("low cut 12", ["bands": 1, "band1.type": "lowcut", "band1.freq": 300, "band1.slope": "12"]),
            ("low cut 24", ["bands": 1, "band1.type": "lowcut", "band1.freq": 300, "band1.slope": "24"]),
            ("low cut 48", ["bands": 1, "band1.type": "lowcut", "band1.freq": 300, "band1.slope": "48"]),
            ("high cut 12", ["bands": 1, "band1.type": "highcut", "band1.freq": 3000, "band1.slope": "12"]),
            ("high cut 24", ["bands": 1, "band1.type": "highcut", "band1.freq": 3000, "band1.slope": "24"]),
            ("high cut 48", ["bands": 1, "band1.type": "highcut", "band1.freq": 3000, "band1.slope": "48", "band1.q": 1.2]),
            ("four bands", ["bands": 4, "band1.type": "lowshelf", "band1.gain": 4, "band2.gain": -6, "band3.gain": 5, "band4.type": "highcut", "band4.freq": 9000]),
            ("eight bands", Dictionary(uniqueKeysWithValues: (1...8).flatMap { k in
                [("band\(k).gain", JSONValue.number(k.isMultiple(of: 2) ? 3 : -3)), ("band\(k).freq", .number(150 * pow(1.9, Double(k))))]
            } + [("bands", .number(8))])),
        ]
        for (name, values) in cases {
            let n = eq(values)
            for f in probes {
                let drawn = AudioFxResponse.gainDb(n, at: f, sampleRate: sr) ?? .nan
                XCTAssertEqual(drawn, measuredDb(n, f), accuracy: 0.05, "\(name) at \(f) Hz")
            }
        }
    }

    func testBandShapesDoWhatTheyAreCalled() {
        let bell = eq(["bands": 1, "band1.type": "bell", "band1.freq": 1000, "band1.gain": 9, "band1.q": 2])
        XCTAssertEqual(AudioFxResponse.gainDb(bell, at: 1000) ?? .nan, 9, accuracy: 0.01)
        XCTAssertEqual(AudioFxResponse.gainDb(bell, at: 40) ?? .nan, 0, accuracy: 0.2)
        let notch = eq(["bands": 1, "band1.type": "notch", "band1.freq": 1000, "band1.q": 8])
        XCTAssertLessThan(AudioFxResponse.gainDb(notch, at: 1000) ?? 0, -40)
        XCTAssertEqual(AudioFxResponse.gainDb(notch, at: 100) ?? .nan, 0, accuracy: 0.1)
        func cutDb(_ slope: String) -> Double {
            AudioFxResponse.gainDb(eq(["bands": 1, "band1.type": "lowcut", "band1.freq": 1000, "band1.slope": slope]), at: 250) ?? 0
        }
        // Two octaves below the corner: about -24, -48 and -96 dB for 12, 24 and 48 dB per octave.
        XCTAssertEqual(cutDb("12"), -24, accuracy: 1.5)
        XCTAssertEqual(cutDb("24"), -48, accuracy: 2)
        XCTAssertEqual(cutDb("48"), -96, accuracy: 4)
        let off = eq(["bands": 1, "band1.type": "bell", "band1.gain": 12, "band1.bypass": "on"])
        XCTAssertEqual(AudioFxResponse.gainDb(off, at: 400) ?? .nan, 0, accuracy: 1e-9, "a bypassed band does nothing")
        let beyond = eq(["bands": 1, "band2.gain": 12, "band2.freq": 400])
        XCTAssertEqual(AudioFxResponse.gainDb(beyond, at: 400) ?? .nan, 0, accuracy: 1e-9, "bands past the count do nothing")
    }

    func testDefaultsAreFlatAndBandCountClamps() {
        let node = eq([:])
        for f in probes { XCTAssertEqual(AudioFxResponse.gainDb(node, at: f) ?? .nan, 0, accuracy: 1e-9) }
        let p = AudioFx.normalize("eq", ["bands": 99, "band3.gain": 99, "band3.q": 0, "band3.type": "wobble"], version: 2)
        XCTAssertEqual(p.num("bands"), 8)
        XCTAssertEqual(p.num("band3.gain"), 24)
        XCTAssertEqual(p.num("band3.q"), 0.1)
        XCTAssertEqual(p["band3.type"]?.string, "bell")
        XCTAssertEqual(AudioFx.normalize("eq", ["bands": 0], version: 2).num("bands"), 1)
    }

    func testChainFileKeepsEveryBandSetting() throws {
        let node = eq(["bands": 3, "band1.type": "lowcut", "band1.freq": 90, "band1.slope": "24", "band2.gain": -4.5, "band2.q": 2.2, "band3.type": "notch", "band3.bypass": "on"])
        let chain = FxChain(nodes: [node])
        let back = try AudioFx.parseChain(AudioFx.serializeChain(chain))
        XCTAssertEqual(back.nodes.first?.params, node.params)
        XCTAssertEqual(back.nodes.first?.type, "eq")
    }

    func testAutomationReachesBandParameters() {
        XCTAssertEqual(AudioAutomation.parseTarget("fx.eq1.band2.freq"), .fx(nodeId: "eq1", param: "band2.freq"))
        XCTAssertNil(AudioAutomation.parseTarget("fx.eq1.band2."))
        XCTAssertNil(AudioAutomation.parseTarget("fx.eq1.gain.extra"))
        let chain = FxChain(nodes: [eq(["bands": 2])])
        let range = AudioAutomation.resolveRange("fx.eq1.band2.gain", chain)
        XCTAssertEqual(range?.min, -24)
        XCTAssertEqual(range?.max, 24)
        XCTAssertNil(AudioAutomation.resolveRange("fx.eq1.band2.type", chain), "a shape is not automatable")
        let processor = FxChainProcessor(chain, automation: Automation(lanes: [AudioAutomationLane(target: "fx.eq1.band2.gain", points: [.init(time: 0, value: 12), .init(time: 1, value: 12)])]))
        XCTAssertFalse(processor.isEmpty)
    }

    func testBandEditsGlideInPlaceAndStructuralEditsRebuild() throws {
        let node = eq(["bands": 2, "band1.freq": 800, "band1.gain": 3])
        let chain = FxChain(nodes: [node])
        let processor = FxChainProcessor(chain, sampleRate: sr)
        func next(_ edit: (inout FxParams) -> Void) -> FxChain {
            var n = node
            var p = n.params ?? FxParams()
            edit(&p)
            n.params = AudioFx.normalize("eq", p, version: 2)
            return FxChain(nodes: [n])
        }
        XCTAssertNotNil(processor.parameterEdits(to: next { $0["band1.freq"] = .number(1200) }), "frequency glides")
        XCTAssertNotNil(processor.parameterEdits(to: next { $0["band1.gain"] = .number(-5); $0["band2.q"] = .number(2) }), "gain and Q glide")
        XCTAssertNotNil(processor.parameterEdits(to: next { $0["band6.gain"] = .number(5) }), "an unbuilt band has nothing to move")
        XCTAssertNil(processor.parameterEdits(to: next { $0["band1.type"] = .string("notch") }), "a shape change rebuilds")
        XCTAssertNil(processor.parameterEdits(to: next { $0["bands"] = .number(3) }), "a band count change rebuilds")
        XCTAssertNil(processor.parameterEdits(to: next { $0["band2.bypass"] = .string("on") }), "bypass rebuilds")
        XCTAssertNil(processor.parameterEdits(to: next { $0["band1.type"] = .string("lowcut"); $0["band1.slope"] = .string("48") }), "slope rebuilds")
    }

    func testLiveEditEndsAtTheSoundOfAFreshBuild() {
        let before = eq(["bands": 1, "band1.freq": 800, "band1.gain": 3])
        let after = eq(["bands": 1, "band1.freq": 1500, "band1.gain": -6, "band1.q": 3])
        let live = FxChainProcessor(FxChain(nodes: [before]), sampleRate: sr)
        let fresh = FxChainProcessor(FxChain(nodes: [after]), sampleRate: sr)
        let block = (0..<dspBlockSize).map { Float(0.2 * sin(2 * Double.pi * 1000 * Double($0) / sr)) }
        _ = live.process([block, block], frame: 0)
        guard let edits = live.parameterEdits(to: FxChain(nodes: [after])) else { return XCTFail("not editable in place") }
        edits.forEach { $0() }
        var frame = dspBlockSize
        var a: [[Float]] = [], b: [[Float]] = []
        for _ in 0..<400 {
            a = live.process([block, block], frame: frame)
            b = fresh.process([block, block], frame: frame)
            frame += dspBlockSize
        }
        // After the 20 ms glide the filters hold the new values; the state memory has long decayed.
        XCTAssertEqual(a[0].last ?? .nan, b[0].last ?? .nan, accuracy: 1e-3)
    }
}
