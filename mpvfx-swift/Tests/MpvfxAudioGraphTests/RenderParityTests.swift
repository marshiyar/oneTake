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

/// Rendered-sample parity against references generated without Chrome:
/// the worklet processors run from the shipped source in a Node shim, and the
/// mix-stage references were recorded once from the original app's export path
/// (see Fixtures/generate-reference.mjs); the tests read only the recorded files.
final class RenderParityTests: XCTestCase {
    static let bar = -90.0

    func testWorkletProcessorsMatchShippedSource() {
        let input = Fixtures.planes(Fixtures.f32("worklet-input.f32"))
        for c in Fixtures.reference["worklets"]!.array {
            let type = c["type"]!.str
            var params = FxParams()
            if case let .object(e) = c["params"]! { for (k, v) in e { params[k] = v.stringValue.map(FxParamValue.string) ?? .number(v.num) } }
            let chain = FxChain(nodes: [FxNode(type: type, params: params)])
            let frames = Int(c["frames"]!.num)
            let out = renderChain(chain, input, frames: frames)
            let d = peakDiffDb(out, Fixtures.f32(c["file"]!.str))
            parityLog("worklet \(c["file"]!.str) \(c["params"]!.json): peak diff \(fmtDb(d.db))")
            XCTAssertLessThanOrEqual(d.db, Self.bar, "\(c["file"]!.str) at sample \(d.index)")
        }
    }

    /// Offline render of a chain, zero-padded input, interleaved output.
    func renderChain(_ chain: FxChain, _ planes: [[Float]], frames: Int) -> [Float] {
        let proc = FxChainProcessor(chain, sampleRate: 48000)
        var out = [Float](repeating: 0, count: frames * 2)
        var q = 0
        while q < frames {
            let block: [[Float]] = (0..<planes.count).map { (c: Int) -> [Float] in
                (0..<renderQuantum).map { (i: Int) -> Float in q + i < planes[c].count ? planes[c][q + i] : 0 }
            }
            let y = proc.process(block, frame: q)
            for i in 0..<min(renderQuantum, frames - q) { out[2 * (q + i)] = y[0][i]; out[2 * (q + i) + 1] = y[1][i] }
            q += renderQuantum
        }
        return out
    }

    static func project(_ name: String) -> AudioGraphProject {
        let p = Fixtures.reference["projects"]![name]!
        var tracks: [AudioGraphTrack] = [], groups: [AudioGraphGroup] = []
        for e in p["elements"]!.array {
            let gid = e["groupId"]?.stringValue
            let chain = e["fxChain"].map { try! AudioFx.parseChain($0.str) }
            tracks.append(AudioGraphTrack(id: e["id"]!.str, stem: Fixtures.planes(Fixtures.f32("stem-\(e["src"]!.str).f32")),
                                          start: e["start"]!.num, end: e["end"]!.num, volume: e["volume"]?.num ?? 1,
                                          fxChain: chain, automation: e["automation"].map { try! AudioAutomation.parse($0.str) }, groupId: gid))
            if let gid, !groups.contains(where: { $0.id == gid }) {
                groups.append(AudioGraphGroup(id: gid, volume: e["groupVolume"]?.num ?? 1,
                                              fxChain: e["groupFxChain"].map { try! AudioFx.parseChain($0.str) },
                                              automation: e["groupAutomation"].map { try! AudioAutomation.parse($0.str) }))
            }
        }
        return AudioGraphProject(duration: p["total"]!.num, tracks: tracks, groups: groups)
    }

    func testProjectMixesMatchEnginePipeline() {
        for name in ["flat", "grouped", "busGain"] {
            let expected = Fixtures.f32("mix-\(name).f32")
            let out = AudioGraphRenderer.renderOffline(Self.project(name))
            XCTAssertEqual(out.count, expected.count, name)
            let d = peakDiffDb(out, expected)
            parityLog("mix \(name) (\(expected.count / 2) frames): peak diff \(fmtDb(d.db)) at frame \(d.index / 2)")
            XCTAssertLessThanOrEqual(d.db, Self.bar, "\(name) frame \(d.index / 2)")
        }
    }
}
