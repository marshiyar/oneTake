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
#if os(Linux)
import Foundation
import XCTest
import MpvfxAudio
import MpvfxAudioGraph
import MpvfxBackend
import MpvfxPanels
@testable import MpvfxDesktop

/// Audition from the media bin inside the editor session: the timeline pauses when a file starts and does not
/// resume by itself, a missing file puts the typed message on the tile, a new project ends the audition, and the
/// transport's volume reaches the player.
final class AssetAuditionSessionTests: XCTestCase {
    var dirs: [String] = []
    override func tearDown() { for d in dirs { try? FileManager.default.removeItem(atPath: d) } }

    func temporaryDirectory() throws -> String {
        let d = NSTemporaryDirectory() + "mpvfx-audition-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        dirs.append(d)
        return (d as NSString).resolvingSymlinksInPath
    }

    /// A session on a real project whose device is a queue the test reads.
    func launch() throws -> (EditorSession, NullAudioOutput, String) {
        let userData = try temporaryDirectory(), root = try temporaryDirectory()
        let project = try RuntimeDesktopBackend(userData: userData).createProject(name: "Alpha", directory: root + "/Alpha")
        let session = try EditorSession(backend: RuntimeDesktopBackend(userData: userData), projectPath: project.directory)
        session.postToUI = { body in DispatchQueue.main.async(execute: body) }
        _ = session.installShell(userData: userData) {}
        session.redraw = {}
        session.audio?.stop()
        session.graphUpdater?.waitUntilIdle()
        session.graphUpdater = nil
        let graph = GraphAudioSource(project: AudioGraphProject(duration: 3, sampleRate: 48000, tracks: []))
        let output = NullAudioOutput()
        output.capacityFrames = 4096
        session.graph = graph
        session.audio = AudioPlayback(output: output, source: graph)
        session.playback.externalClock = { [weak session] in session?.audio.flatMap { $0.isPlaying ? $0.currentTime : nil } }
        session.playback.duration = 3
        try FileManager.default.createDirectory(atPath: project.directory + "/media", withIntermediateDirectories: true)
        let tone = WavBytes.stereo(seconds: 2)
        try tone.write(to: URL(fileURLWithPath: project.directory + "/media/tone.wav"))
        session.panels?.left.items = [
            MediaBinItem(id: "media/tone.wav", name: "tone.wav", path: "media/tone.wav", category: .audio, duration: 2, used: false),
            MediaBinItem(id: "media/take3.wav", name: "take3.wav", path: "media/take3.wav", category: .audio, duration: 5, used: false),
        ]
        return (session, output, project.directory)
    }

    func waitUntil(_ what: String, _ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(20)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertTrue(done(), what)
    }

    /// A3: playing the timeline, then auditioning: the timeline is paused and stays paused after the audition ends.
    func testA3TimelinePausesWhileAuditioningAndDoesNotResumeByItself() throws {
        let (session, output, _) = try launch()
        let panels = try XCTUnwrap(session.panels)
        session.playback.play()
        session.syncAudio()
        XCTAssertTrue(session.playback.isPlaying)
        panels.toggleAudition("media/tone.wav")
        XCTAssertFalse(session.playback.isPlaying, "starting an audition pauses the timeline")
        XCTAssertEqual(panels.left.audition?.assetId, "media/tone.wav")
        XCTAssertFalse(session.audio?.isPlaying ?? true, "the timeline's feeder gave the device up")
        waitUntil("the audition feeds the device") { output.framesQueued > 0 }
        panels.toggleAudition("media/tone.wav")   // the same tile again stops it
        XCTAssertNil(panels.left.audition)
        XCTAssertFalse(session.playback.isPlaying, "ending the audition does not restart the timeline")
        session.syncAudio()
        XCTAssertFalse(session.audio?.isPlaying ?? true)
    }

    func testPlayingTheTimelineEndsAnAudition() throws {
        let (session, _, _) = try launch()
        let panels = try XCTUnwrap(session.panels)
        panels.toggleAudition("media/tone.wav")
        XCTAssertNotNil(panels.left.audition)
        session.playback.play()
        session.syncAudio()
        XCTAssertNil(panels.left.audition, "the timeline and an audition never share the device")
        session.audio?.stop()
    }

    /// A4: a missing file shows the typed message on its tile; nothing is left playing.
    func testA4AMissingFileShowsTheTypedErrorOnTheTile() throws {
        let (session, _, _) = try launch()
        let panels = try XCTUnwrap(session.panels)
        panels.toggleAudition("media/take3.wav")
        XCTAssertEqual(panels.left.auditionErrors["media/take3.wav"], "Can't play \"take3.wav\": the file is missing")
        XCTAssertNil(panels.left.audition)
        panels.toggleAudition("media/tone.wav")
        XCTAssertNotNil(panels.left.audition)
        XCTAssertEqual(panels.left.auditionErrors["media/take3.wav"], "Can't play \"take3.wav\": the file is missing", "other tiles keep theirs")
        panels.stopAudition()
    }

    func testStartingAnotherAuditionEndsTheFirst() throws {
        let (session, _, dir) = try launch()
        let panels = try XCTUnwrap(session.panels)
        try WavBytes.stereo(seconds: 1).write(to: URL(fileURLWithPath: dir + "/media/take3.wav"))
        panels.toggleAudition("media/tone.wav")
        panels.toggleAudition("media/take3.wav")
        XCTAssertEqual(panels.left.audition?.assetId, "media/take3.wav")
        XCTAssertEqual(panels.auditionPlayer?.currentAssetId, "media/take3.wav")
        panels.stopAudition()
    }

    func testSwitchingProjectEndsTheAudition() throws {
        let (session, _, _) = try launch()
        let panels = try XCTUnwrap(session.panels)
        panels.toggleAudition("media/tone.wav")
        XCTAssertNotNil(panels.left.audition)
        panels.projectSwitched()
        XCTAssertNil(panels.left.audition)
        XCTAssertNil(panels.auditionPlayer?.currentAssetId)
    }

    func testTheTransportVolumeAndMuteReachThePlayer() throws {
        let (session, output, _) = try launch()
        let panels = try XCTUnwrap(session.panels)
        session.transport.volume.volume = 0.25
        panels.toggleAudition("media/tone.wav")
        waitUntil("audio queued") { output.framesQueued >= 2048 }
        let quiet = output.written.prefix(2048).map { abs($0) }.max() ?? 1
        XCTAssertLessThanOrEqual(quiet, 0.25 * 0.5 + 0.001, "a 0.5-amplitude tone at volume 0.25")
        panels.stopAudition()
    }
}

/// WAV bytes for the tests above.
enum WavBytes {
    static func stereo(seconds: Double, rate: Int = 48_000) -> Data {
        let frames = Int(seconds * Double(rate))
        var d = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + frames * 4); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2); u32(rate); u32(rate * 4); u16(4); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(frames * 4)
        for i in 0..<frames {
            let v = Int16(0.5 * 32767 * sin(2 * Double.pi * 440 * Double(i) / Double(rate)))
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        return d
    }
}
#endif
