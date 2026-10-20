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
import MpvfxAudio
import MpvfxAudioGraph
import MpvfxCanvas
import MpvfxTimeline
@testable import MpvfxDesktop

/// Issue #26: use the real audio feeder and a manually advanced device clock so crossing the
/// end happens deterministically between desktop timer ticks, including already queued wraps.
final class PlaybackLoopSyncTests: XCTestCase {
    final class Output: AudioOutput {
        let sink = NullAudioOutput()
        var starts = 0
        var format: AudioFormat { sink.format }
        var framesPlayed: Int { sink.framesPlayed }
        init() { sink.capacityFrames = 4096; sink.keepSamples = false }
        func start() throws { starts += 1; try sink.start() }
        func write(_ samples: [Float]) throws { try sink.write(samples) }
        func stop() { sink.stop() }
        func flush() { sink.flush() }
    }

    func makeSession() throws -> (EditorSession, Output) {
        let session = try EditorSession(projectPath: nil, demo: true)
        session.audio?.stop()
        session.graphUpdater?.waitUntilIdle()
        session.graphUpdater = nil
        let graph = GraphAudioSource(project: AudioGraphProject(duration: 3, sampleRate: 48000, tracks: []))
        let output = Output()
        session.graph = graph
        session.audio = AudioPlayback(output: output, source: graph)
        session.playback.externalClock = { [weak session] in
            session?.audio.flatMap { $0.isPlaying ? $0.currentTime : nil }
        }
        session.playback.duration = 3
        session.player.size = CanvasSize(1032, 640)
        return (session, output)
    }

    func toggle(_ session: EditorSession) {
        let button = session.player.view.buttonRect(.loop, in: session.player.size)
        session.player.pointerDown(x: button.x + 5, y: button.y + 5)
        session.player.pointerUp(x: button.x + 5, y: button.y + 5)
    }

    func refill(_ output: Output, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while output.sink.framesQueued - output.framesPlayed < 2048, Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        XCTAssertGreaterThanOrEqual(output.sink.framesQueued - output.framesPlayed, 2048, "audio feeder stalled", file: file, line: line)
    }

    func testLoopButtonSynchronizesAudioImmediatelyWhilePaused() throws {
        let (session, output) = try makeSession()
        defer { session.audio?.stop() }
        toggle(session)
        XCTAssertEqual(session.audio?.loop?.start, 0)
        XCTAssertEqual(session.audio?.loop?.end, 3)
        XCTAssertEqual(output.starts, 0, "enabling loop does not start paused playback")
        toggle(session)
        XCTAssertNil(session.audio?.loop)
        XCTAssertFalse(session.playback.isPlaying)
    }

    func testEnablingNearEndFollowsRepeatedDeviceWrapsWithoutRestarting() throws {
        let (session, output) = try makeSession()
        defer { session.audio?.stop() }
        session.playback.seek(2.9)
        session.playback.play()
        session.syncAudio()
        refill(output)
        toggle(session)
        XCTAssertEqual(session.audio?.loop?.end, 3, "the click reaches the feeder before another timer tick")
        refill(output)
        let starts = output.starts
        var wraps = 0, last = session.playback.currentTime
        for _ in 0..<620 {
            output.sink.advance(seconds: 0.01)
            let clock = try XCTUnwrap(session.audio).currentTime
            XCTAssertTrue(session.tick(0.01))
            XCTAssertEqual(session.playback.currentTime, clock, accuracy: 1e-6, "follow the device even when it crossed the end between ticks")
            XCTAssertEqual(output.starts, starts, "a seamless wrap is not a user seek")
            if session.playback.currentTime < last { wraps += 1 }
            last = session.playback.currentTime
            refill(output)
        }
        XCTAssertGreaterThanOrEqual(wraps, 3)
    }

    func testDeviceWrapJustAfterClockReadDoesNotRestartAudio() throws {
        let (session, output) = try makeSession()
        defer { session.audio?.stop() }
        session.playback.loopEnabled = true
        session.playback.seek(2.98)
        session.playback.play()
        session.syncAudio()
        refill(output)
        let audio = try XCTUnwrap(session.audio)
        let starts = output.starts
        output.sink.advance(seconds: 0.01)
        session.playback.externalClock = {
            let time = audio.currentTime
            // The real device keeps consuming while tick handles the time it just read.
            output.sink.advance(seconds: 0.02)
            return time
        }
        XCTAssertTrue(session.tick(0.01))
        XCTAssertEqual(output.starts, starts)
        XCTAssertEqual(session.playback.currentTime, 2.99, accuracy: 1e-6)
        session.playback.externalClock = { audio.currentTime }
        XCTAssertTrue(session.tick(0.01))
        XCTAssertEqual(session.playback.currentTime, 0.01, accuracy: 1e-6)
        XCTAssertEqual(output.starts, starts)
    }

    func testDisablingWithQueuedWrapStopsAtOutPoint() throws {
        let (session, output) = try makeSession()
        defer { session.audio?.stop() }
        session.playback.inPoint = 1
        session.playback.outPoint = 2
        session.playback.seek(1.99)
        session.playback.play()
        session.syncAudio()
        refill(output)
        XCTAssertGreaterThan(try XCTUnwrap(session.audio).wraps, 0, "the device buffer already contains a wrap")
        toggle(session)
        XCTAssertNil(session.audio?.loop, "turning loop off reaches the feeder immediately")
        refill(output)
        output.sink.advance(seconds: 0.02)
        XCTAssertFalse(session.tick(0.02))
        XCTAssertEqual(session.playback.currentTime, 2, accuracy: 1e-6)
        XCTAssertFalse(try XCTUnwrap(session.audio).isPlaying)
    }
}
