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
// Audition of one file on the output the timeline uses: the sound is the engine's decode of the file, bit for bit, with
// no effects; a missing file is a typed error with the words the tile shows; one audition at a time. Every device is a
// NullAudioOutput whose queue the test reads; nothing waits on the clock.
import XCTest
import MpvfxShared
@testable import MpvfxAudio

final class AssetAuditionPlayerTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws { dir = try WavFixtures.tempDir() }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    /// A stereo WAV whose two channels differ and never repeat inside a block.
    func stereoFile(_ name: String, seconds: Double, rate: Int = 48_000) throws -> String {
        let frames = Int(seconds * Double(rate))
        let interleaved: [Float] = (0..<frames).flatMap { (i: Int) -> [Float] in
            let t = Double(i) / Double(rate)
            return [Float(0.5 * sin(2 * Double.pi * 440 * t)), Float(0.25 * sin(2 * Double.pi * 660 * t + Double(i % 97) * 0.001))]
        }
        return try WavFixtures.write(name, in: dir, interleaved, sampleRate: rate, channels: 2, encoding: .s16)
    }

    func waitForQueued(_ output: NullAudioOutput, frames: Int, idle: Double = 30) -> Bool {
        var last = output.framesQueued, lastMove = Date()
        while last < frames {
            usleep(1000)
            let now = output.framesQueued
            if now != last { last = now; lastMove = Date() } else if Date().timeIntervalSince(lastMove) > idle { return false }
        }
        return true
    }

    /// A2: at gain 1 the first two seconds the device receives are the decoded stem's samples, interleaved.
    func testA2AuditionOutputEqualsTheDecodedStemBitForBit() throws {
        let path = try stereoFile("take.wav", seconds: 3)
        let output = NullAudioOutput()
        let want = 2 * 48_000
        output.capacityFrames = want + 4096   // the feeder parks once it has queued what the test compares
        let player = AssetAuditionPlayer(output: output)
        try player.start(assetId: "media/take.wav", path: path, name: "take.wav", durationHint: 3)
        XCTAssertTrue(waitForQueued(output, frames: want), "the feeder stalled")
        let played = Array(output.written.prefix(want * 2))
        player.stop()
        let stem = try StemDecoder.decode(.init(path: path, sourceIn: 0, duration: 2, rate: 1), sampleRate: 48_000)
        let expected = (0..<want).flatMap { [stem[0][$0], stem[1][$0]] }
        XCTAssertEqual(played.count, expected.count)
        XCTAssertTrue(played == expected, "audition output differs from the stem")
    }

    func testVolumeScalesTheSamplesAndTheDefaultLeavesThemUntouched() throws {
        let path = try stereoFile("v.wav", seconds: 1)
        let output = NullAudioOutput()
        output.capacityFrames = 8192
        let player = AssetAuditionPlayer(output: output)
        player.volume = 0.5
        try player.start(assetId: "v", path: path, name: "v.wav")
        XCTAssertTrue(waitForQueued(output, frames: 4096))
        let half = Array(output.written.prefix(4096 * 2))
        player.stop()
        let stem = try StemDecoder.decode(.init(path: path, sourceIn: 0, duration: 1, rate: 1), sampleRate: 48_000)
        for i in 0..<4096 {
            XCTAssertEqual(half[2 * i], Float(Double(stem[0][i]) * 0.5), accuracy: 1e-7)
            XCTAssertEqual(half[2 * i + 1], Float(Double(stem[1][i]) * 0.5), accuracy: 1e-7)
        }
    }

    func testAMissingFileIsATypedErrorWithTheTileWordsAndNothingStarts() {
        let output = NullAudioOutput()
        let player = AssetAuditionPlayer(output: output)
        XCTAssertThrowsError(try player.start(assetId: "x", path: dir.path + "/take3.wav", name: "take3.wav")) { error in
            XCTAssertEqual(error as? AuditionError, AuditionError(name: "take3.wav", reason: "the file is missing"))
            XCTAssertEqual("\(error)", "Can't play \"take3.wav\": the file is missing")
        }
        XCTAssertNil(player.currentAssetId)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(output.started)
    }

    func testAFolderIsNotAFile() {
        let player = AssetAuditionPlayer(output: NullAudioOutput())
        XCTAssertThrowsError(try player.start(assetId: "d", path: dir.path, name: "media")) {
            XCTAssertEqual($0 as? AuditionError, AuditionError(name: "media", reason: "it isn't a file"))
        }
    }

    func testAFileTheEngineCannotDecodeEndsWithAnErrorFromTheAudioThread() throws {
        let path = dir.appendingPathComponent("junk.wav").path
        try Data("this is not audio".utf8).write(to: URL(fileURLWithPath: path))
        let output = NullAudioOutput()
        output.capacityFrames = 4096
        let player = AssetAuditionPlayer(output: output)
        try player.start(assetId: "j", path: path, name: "junk.wav")
        var status: AssetAuditionPlayer.Status?
        let deadline = Date().addingTimeInterval(20)
        while status?.error == nil, Date() < deadline { status = player.poll() ?? status; usleep(1000) }
        XCTAssertEqual(status?.error?.name, "junk.wav")
        XCTAssertFalse(player.isPlaying, "a failed audition gives the device back")
        XCTAssertNil(player.currentAssetId)
    }

    func testStartingASecondAuditionEndsTheFirst() throws {
        let first = try stereoFile("one.wav", seconds: 2), second = try stereoFile("two.wav", seconds: 2)
        let output = NullAudioOutput()
        output.capacityFrames = 4096
        let player = AssetAuditionPlayer(output: output)
        try player.start(assetId: "one", path: first, name: "one.wav")
        XCTAssertEqual(player.currentAssetId, "one")
        try player.start(assetId: "two", path: second, name: "two.wav")
        XCTAssertEqual(player.currentAssetId, "two")
        XCTAssertEqual(player.poll()?.assetId, "two")
        player.stop()
        XCTAssertNil(player.currentAssetId)
        XCTAssertNil(player.poll())
    }

    func testSeekByFiveSecondsMovesTheStartOfWhatIsHeardAndClampsToTheFile() throws {
        let path = try stereoFile("long.wav", seconds: 12)
        let output = NullAudioOutput()
        output.capacityFrames = 4096
        let player = AssetAuditionPlayer(output: output)
        try player.start(assetId: "l", path: path, name: "long.wav", durationHint: 12)
        XCTAssertTrue(waitForQueued(output, frames: 2048))
        player.seek(by: AssetAuditionPlayer.seekStep)
        XCTAssertTrue(waitForQueued(output, frames: 4096), "audio resumes after the seek")
        let heard = output.written
        let stem = try StemDecoder.decode(.init(path: path, sourceIn: 5, duration: 0.1, rate: 1), sampleRate: 48_000)
        let wanted = (0..<100).flatMap { [stem[0][$0], stem[1][$0]] }
        // A block the old feeder was writing when the seek came may land first (the device flush cannot recall it);
        // the new sound follows it at a block boundary.
        let starts = stride(from: 0, through: 2 * 1024 * 2, by: 1024 * 2).filter { $0 + wanted.count <= heard.count && Array(heard[$0..<($0 + wanted.count)]) == wanted }
        XCTAssertFalse(starts.isEmpty, "the sound now starts at 5 s")
        XCTAssertEqual(try XCTUnwrap(player.poll()).position, 5, accuracy: 0.05)
        player.seek(by: -60)
        XCTAssertEqual(try XCTUnwrap(player.poll()).position, 0, accuracy: 0.05, "seeking back stops at the start")
        player.seek(by: 600)
        let end = try XCTUnwrap(player.poll())
        XCTAssertLessThan(end.position, 12, "seeking past the end stays inside the file")
        player.stop()
    }

    func testReachingTheEndStopsOnItsOwnAndSaysSoOnce() throws {
        let path = try stereoFile("short.wav", seconds: 0.2)
        let output = NullAudioOutput()
        output.capacityFrames = 24_000   // a device buffer: the feeder blocks on it instead of queueing silence without end
        let player = AssetAuditionPlayer(output: output)
        try player.start(assetId: "s", path: path, name: "short.wav", durationHint: 0.2)
        XCTAssertTrue(waitForQueued(output, frames: 12_000))
        output.advance(seconds: 1)   // the device plays everything it was given
        var finished: AssetAuditionPlayer.Status?
        let deadline = Date().addingTimeInterval(20)
        while finished?.finished != true, Date() < deadline { finished = player.poll() ?? finished; output.advance(seconds: 0.5); usleep(1000) }
        XCTAssertEqual(finished?.finished, true)
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.currentAssetId)
        XCTAssertNil(player.poll(), "reported once")
    }
}
