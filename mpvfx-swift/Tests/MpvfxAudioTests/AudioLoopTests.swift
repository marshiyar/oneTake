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
import MpvfxShared
import MpvfxAudioGraph
@testable import MpvfxAudio

/// Loop playback through the audio device: the feeder wraps at the loop end inside the block (no gap, no repeat,
/// no restart) and the device clock follows the wrap. (The picture following that clock is covered by
/// MpvfxTimelineTests.TimelineLoopTests, so this target stays free of the UI modules.)
final class AudioLoopTests: XCTestCase {
    static let project = AudioGraphFixtures.everyFX()
    static let offline = AudioGraphRenderer.renderOffline(project)

    func slice(_ a: [Float], _ from: Int, _ to: Int) -> [Float] { Array(a[(from * 2)..<(to * 2)]) }

    func waitFor(_ cond: () -> Bool, _ seconds: Double = 60) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; usleep(2000) }
        return cond()
    }

    /// Waits until `count()` reaches `target`, failing only when it stops moving for `idle` seconds. The every-FX
    /// graph renders far slower than real time in a debug build on a CI runner, so a fixed deadline would fail a
    /// feeder that is still making progress.
    func waitForProgress(to target: Int, idle: Double = 30, _ count: () -> Int) -> Bool {
        var last = count(), lastMove = Date()
        while last < target {
            usleep(2000)
            let now = count()
            if now != last { last = now; lastMove = Date() } else if Date().timeIntervalSince(lastMove) > idle { return false }
        }
        return true
    }

    /// What the device receives across three wraps is the export render of the range, back to back, sample for
    /// sample: nothing missing at the seam, nothing doubled. Both with the loop start at 0 and deep inside.
    func testWrapIsSampleExactAcrossThreeWraps() throws {
        for (start, end) in [(0.0, 0.3), (0.5, 0.8)] {
            let src = GraphAudioSource(project: Self.project)
            let out = NullAudioOutput(format: src.format)
            let pb = AudioPlayback(output: out, source: src)
            pb.loop = (start, end)
            let from = start + 0.1
            let s = Int(start * 48000), e = Int(end * 48000), f = Int(from * 48000)
            let need = (e - f) + 3 * (e - s) + 1000
            // The device buffer holds what we compare and a block more, so the feeder parks once it is there and
            // the samples are read while nothing else writes (stop() flushes the device, so read before it).
            out.capacityFrames = need + pb.blockFrames
            try pb.play(from: from)
            XCTAssertTrue(waitForProgress(to: need) { out.framesQueued }, "feeder stalled")
            let got = Array(out.written.prefix(need * 2))
            pb.stop()
            var want = slice(Self.offline, f, e)
            while want.count < need * 2 { want += slice(Self.offline, s, e) }
            want = Array(want.prefix(need * 2))
            XCTAssertTrue(got == want, "loop \(start)-\(end): device stream differs from the range rendered back to back")
            XCTAssertGreaterThanOrEqual(pb.wraps, 3)
        }
    }

    /// The UI loop on the device clock: 60 ticks a second against a device consuming in real time steps. Over
    /// several wraps the clock stays inside the range, wraps back at the end, never restarts the audio, and FX
    /// edits submitted mid-loop land without blocking a tick.
    func testClockWrapsInsideTheRangeAndAnEditMidLoopDoesNotHang() throws {
        let inputsA = AudioFxLiveEditTests.inputs()
        let src = GraphAudioSource(project: AudioFxLiveEditTests.project(inputsA))
        let updater = LiveAudioGraphUpdater(source: src, loadStem: AudioFxLiveEditTests.loadStem)
        updater.submit(inputsA); updater.waitUntilIdle()
        let out = NullAudioOutput(format: src.format)
        out.capacityFrames = 4096
        let audio = AudioPlayback(output: out, source: src)
        let (loopStart, loopEnd) = (0.4, 0.7)
        audio.loop = (loopStart, loopEnd)
        try audio.play(from: 0.45)
        XCTAssertTrue(waitFor { out.framesQueued >= 4096 })
        var wraps = 0, last = audio.currentTime, maxTick = 0.0
        let dt = 1.0 / 60
        for i in 0..<120 {   // 2 s of playback = 6+ wraps of a 0.3 s loop
            out.advance(seconds: dt)
            let t0 = Date()
            let now = audio.currentTime
            if i == 50 {   // an FX edit mid-loop, as the inspector makes it
                updater.submit(AudioFxLiveEditTests.inputs(clipFx: #"{"version":1,"nodes":[{"type":"reverb","id":"r","params":{"wet":0.5}}]}"#))
            }
            if i == 70 { updater.submit(AudioFxLiveEditTests.inputs(busFx: #"{"version":1,"nodes":[{"type":"gain","id":"g","params":{"gain":-6}}]}"#, busVolume: 0.5)) }
            maxTick = max(maxTick, Date().timeIntervalSince(t0))
            XCTAssertGreaterThanOrEqual(now, loopStart - 1e-6); XCTAssertLessThan(now, loopEnd + 1e-6)
            if now < last - 0.1 { wraps += 1 }
            last = now
            // Let the feeder refill what the device took (it runs on its own thread).
            _ = waitFor({ out.framesQueued - out.framesPlayed >= 2048 }, 5)
        }
        updater.waitUntilIdle()
        XCTAssertEqual(src.project.groups.first?.volume, 0.5, "the mid-loop edits landed")
        XCTAssertNotNil(src.project.groups.first?.fxChain, "the bus chain from the second edit is live")
        print(String(format: "AUDIO-LOOP clockWraps=%d audioWraps=%d maxTickMs=%.2f builds=%d", wraps, audio.wraps, maxTick * 1000, updater.builds))
        XCTAssertGreaterThanOrEqual(wraps, 3)
        XCTAssertGreaterThanOrEqual(audio.wraps, 3)
        XCTAssertLessThan(maxTick, 0.25, "a UI tick blocked")
        XCTAssertTrue(audio.isPlaying)
        audio.stop()
    }
}
