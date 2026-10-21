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
import XCTest
@testable import MpvfxAudioGraph

final class AudioFxABTests: XCTestCase {
    func testOldChainBytesStayUnchangedAndSlotsRoundTrip() throws {
        let old = try AudioFx.parseChain(#"{"version":1,"nodes":[{"type":"gain","id":"g","params":{"gain":-12}}]}"#)
        let bytes = AudioFx.serializeChain(old)
        XCTAssertEqual(bytes, #"{"version":1,"nodes":[{"type":"gain","id":"g","params":{"gain":-12}}]}"#)
        XCTAssertFalse(bytes.contains("paramsB"))
        XCTAssertFalse(bytes.contains("activeSlot"))
        XCTAssertEqual(AudioFx.serializeChain(try AudioFx.parseChain(bytes)), bytes)
        var edited = old
        edited.nodes[0].selectSlotB(true)
        edited.nodes[0].params?["gain"] = .number(-30)
        XCTAssertEqual(edited.nodes[0].paramsA?.num("gain"), -12)
        XCTAssertEqual(edited.nodes[0].params?.num("gain"), -30)
        XCTAssertEqual(try AudioFx.parseChain(AudioFx.serializeChain(edited)), edited)
        edited.nodes[0].selectSlotB(false)
        XCTAssertEqual(edited.nodes[0].params?.num("gain"), -12)
        edited.nodes[0].copyAToB()
        XCTAssertEqual(edited.nodes[0].paramsA, edited.nodes[0].paramsB)
    }
    func testUpdatingSoundMigratesBothSlots() throws {
        var chain = try AudioFx.parseChain(#"{"version":1,"nodes":[{"type":"compressor","params":{"knee":2}}]}"#)
        chain.nodes[0].selectSlotB(true)
        chain.nodes[0].params?["knee"] = .number(4)
        let updated = chain.updatedSound()
        XCTAssertTrue(updated.nodes[0].activeSlotB)
        XCTAssertEqual(try XCTUnwrap(updated.nodes[0].paramsA).num("knee"), 20 * log10(2), accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(updated.nodes[0].paramsB).num("knee"), 20 * log10(4), accuracy: 0.01)
    }

    func testFactoryDefaultsExistForEveryEffectAndPresetsKeepOtherSlot() throws {
        for def in AudioFx.definitions {
            XCTAssertFalse(AudioFxPresets.modulePresets(def.id).isEmpty, def.id)
        }
        var node = FxNode(type: "gain", version: 2, params: AudioFx.normalize("gain", ["gain": .number(-20)], version: 2))
        node.selectSlotB(true)
        let preset = try XCTUnwrap(AudioFxPresets.modulePresets("gain").first)
        let loaded = preset.applying(to: node)
        XCTAssertEqual(loaded.paramsA, node.paramsA)
        XCTAssertEqual(loaded.params, preset.params)
    }
}
