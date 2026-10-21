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

/// Voice room (issue #309): speech regions become tagged ducking points on a bed.
final class VoiceRoomTests: XCTestCase {
    static let regions = [SpeechRegion(start: 1, end: 3), SpeechRegion(start: 5, end: 6)]

    func db(_ a: Automation, at t: Double) -> Double {
        let lane = a.lanes.first { $0.target == "volume" }!
        return 20 * log10(AudioAutomation.sampleLane(lane, t))
    }

    func testBedDipsForEachPhraseWithTheSetRamps() {
        let a = VoiceRoom.apply(to: nil, regions: Self.regions)
        XCTAssertEqual(db(a, at: 0.5), 0, accuracy: 1e-9)
        XCTAssertEqual(db(a, at: 0.75), 0, accuracy: 1e-9)
        XCTAssertEqual(db(a, at: 1.0), -12, accuracy: 1e-9)
        XCTAssertEqual(db(a, at: 2.0), -12, accuracy: 1e-9)
        XCTAssertEqual(db(a, at: 3.0), -12, accuracy: 1e-9)
        XCTAssertEqual(db(a, at: 3.4), 0, accuracy: 1e-9)
        XCTAssertEqual(db(a, at: 4.5), 0, accuracy: 1e-9)
        XCTAssertEqual(db(a, at: 5.5), -12, accuracy: 1e-9)
        XCTAssertEqual(db(a, at: 6.4), 0, accuracy: 1e-9)
        XCTAssertTrue(a.lanes[0].points.allSatisfy { $0.origin == "voice-room" })
    }

    func testGapsShorterThanHoldStayDipped() {
        let a = VoiceRoom.apply(to: nil, regions: [SpeechRegion(start: 1, end: 2), SpeechRegion(start: 2.3, end: 3)],
                                settings: VoiceRoomSettings(attackMs: 50, releaseMs: 50, holdMs: 500))
        XCTAssertEqual(db(a, at: 2.15), -12, accuracy: 1e-9)
    }

    func testRerunReplacesOnlyVoiceRoomPoints() throws {
        let hand = AutomationPoint(t: 8, v: 0.5)
        let first = VoiceRoom.apply(to: Automation(lanes: [AutomationLane(target: "volume", points: [hand])]), regions: Self.regions)
        let again = VoiceRoom.apply(to: first, regions: [SpeechRegion(start: 2, end: 2.5)])
        let pts = again.lanes[0].points
        XCTAssertTrue(pts.contains(hand), "the hand-drawn point survives")
        XCTAssertEqual(pts.filter { $0.origin == "voice-room" }.count, 4)
        XCTAssertFalse(pts.contains { $0.origin == "voice-room" && $0.t == 5 })
        let reread = try AudioAutomation.parse(AudioAutomation.serialize(again))
        XCTAssertEqual(reread, again, "the tag survives the stored form")
    }

    func testHostileRegionsAndSettingsGiveFinitePoints() {
        let a = VoiceRoom.apply(to: nil, regions: [SpeechRegion(start: .nan, end: 2), SpeechRegion(start: 3, end: 1), SpeechRegion(start: -5, end: 0.5)],
                                settings: VoiceRoomSettings(amountDb: .infinity, attackMs: -1, releaseMs: .nan, holdMs: 1e9))
        XCTAssertTrue(a.lanes[0].points.allSatisfy { $0.t.isFinite && $0.v.isFinite && $0.t >= 0 })
        XCTAssertEqual(VoiceRoom.apply(to: nil, regions: []).lanes, [])
    }

    func testDuckedBedRendersTheSameLiveAndInExport() {
        let n = 10 * 48_000
        let plane = [Float](repeating: 0.5, count: n)
        let auto = VoiceRoom.apply(to: nil, regions: Self.regions)
        let p = AudioGraphProject(duration: 10, tracks: [AudioGraphTrack(id: "bed", stem: [plane, plane], start: 0, end: 10, automation: auto)])
        let live = ClipFadeTests.live(p), export = ClipFadeTests.export(p)
        XCTAssertTrue(live == export)
        XCTAssertEqual(Double(live[2 * 2 * 48_000]) / 0.5, pow(10, -12.0 / 20), accuracy: 0.01)
    }
}
