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

/// Audio FX edits while playing: the UI side (`LiveAudioGraphUpdater.submit`) never waits on the graph, the feeder
/// keeps playing through every edit, and the FX are really heard, in live playback and in the offline render export
/// uses (`DocumentAudioGraph.project` + `AudioGraphRenderer.renderAll`, the path `renderExportAudioMix` takes).
/// Every FX type, on the clip rack (the clip's chain) and on the group bus rack (the audio group's chain).
final class AudioFxLiveEditTests: XCTestCase {
    private final class WatchdogState: @unchecked Sendable {
        private let lock = NSLock()
        private var beat = DispatchTime.now().uptimeNanoseconds
        private var maxGap: UInt64 = 0
        private var done = false
        private var worst = ""
        private var phase = "start"

        func sample() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            let gap = DispatchTime.now().uptimeNanoseconds - beat
            if gap > maxGap { maxGap = gap; worst = phase }
            return true
        }

        func heartbeat(_ nextPhase: String) {
            lock.lock(); beat = DispatchTime.now().uptimeNanoseconds; phase = nextPhase; lock.unlock()
        }

        func finish() -> (gap: UInt64, phase: String) {
            lock.lock(); defer { lock.unlock() }
            done = true
            return (maxGap, worst)
        }
    }

    static let seconds = 1.0
    static let rate = 48000

    /// Near-silence (-55 dB) for the first 0.375 s (long enough for a gate's envelope to close), then loud bursts
    /// (peaks near 0 dBFS) and a quiet passage (-31 dB), so every processor has something to act on.
    static let stem: [[Float]] = {
        let n = Int(seconds * Double(rate))
        var s: UInt32 = 12345
        func r() -> Float { s = s &* 1664525 &+ 1013904223; return Float(Double(s) / 4294967296 * 2 - 1) }
        var l = [Float](repeating: 0, count: n), rr = l
        for i in 0..<n {
            let amp: Float = [0.002, 0.002, 0.002, 0.9, 0.03, 0.9, 0.9, 0.002][(i / 6000) % 8]
            let tone = Float(sin(2 * Double.pi * 220 * Double(i) / 48000))
            l[i] = amp * (0.7 * tone + 0.3 * r())
            rr[i] = amp * (0.7 * Float(sin(2 * Double.pi * 330 * Double(i) / 48000)) + 0.3 * r())
        }
        return [l, rr]
    }()
    static let clipKey = DocumentAudioGraph.StemKey(path: "/p/a.wav", sourceIn: 0, duration: seconds, rate: 1)
    static let otherKey = DocumentAudioGraph.StemKey(path: "/p/b.wav", sourceIn: 0, duration: seconds, rate: 1)
    static func loadStem(_ k: DocumentAudioGraph.StemKey) -> [[Float]] { stem }

    enum Rack: String, CaseIterable { case clip, bus }

    /// Clip "a" sits in group "bus" (the selection whose rack is edited); clip "b" plays beside it, ungrouped.
    static func inputs(clipFx: String? = nil, busFx: String? = nil, clipVolume: Double = 1, busVolume: Double = 1) -> DocumentAudioGraph.Inputs {
        var bus = NativeAudioGroup.bus(id: "bus")
        bus.volume = busVolume; bus.fxChain = busFx
        return DocumentAudioGraph.Inputs(duration: seconds, tracks: [
            .init(id: "a", stem: clipKey, start: 0, end: seconds, volume: clipVolume, muted: false, fxChain: clipFx, automation: nil, groupId: "bus"),
            .init(id: "b", stem: otherKey, start: 0, end: seconds, volume: 0.5, muted: false, fxChain: nil, automation: nil, groupId: nil),
        ], groups: [bus])
    }
    static func inputs(_ rack: Rack, _ chain: String?) -> DocumentAudioGraph.Inputs {
        rack == .clip ? inputs(clipFx: chain) : inputs(busFx: chain)
    }
    static func project(_ i: DocumentAudioGraph.Inputs) -> AudioGraphProject {
        var issues: [String] = []
        let p = DocumentAudioGraph.project(i, loadStem: loadStem, issues: &issues)
        XCTAssertEqual(issues, [])
        return p
    }

    /// One node of every registered FX type, with settings that change the sound (registry defaults leave gain,
    /// EQ gain and pitch at identity).
    static let everyType: [(String, String)] = [
        ("gain", #"{"gain":-9}"#), ("peaking", #"{"frequency":1000,"gain":9,"q":1}"#),
        ("lowshelf", #"{"frequency":300,"gain":-9}"#), ("highshelf", #"{"frequency":3000,"gain":9}"#),
        ("highpass", #"{"frequency":800}"#), ("lowpass", #"{"frequency":600}"#),
        ("compressor", #"{"threshold":-30,"ratio":8}"#), ("limiter", #"{"limit":-6}"#), ("gate", #"{"threshold":-25,"range":-60}"#),
        ("saturate", #"{"type":"hard","threshold":-12}"#), ("bitcrush", #"{"bits":4}"#), ("pitchshift", #"{"semitones":5}"#),
        ("delay", #"{"time":90,"feedback":0.5,"mix":0.5}"#), ("chorus", #"{"depth":5,"mix":0.6}"#), ("phaser", #"{"speed":1.5}"#),
        ("reverb", #"{"wet":0.6}"#), ("reverb-v2", #"{"wet":0.6}"#), ("denoise", #"{"amount":1,"learn":100}"#),
    ]
    static func chain(_ type: String, _ params: String, version: Int = 1) -> String {
        #"{"version":"# + String(version) + #","nodes":[{"type":""# + type + #"","id":"x","params":"# + params + "}]}"
    }

    static let dryOffline = AudioGraphRenderer.renderOffline(project(inputs()))

    func slice(_ a: [Float], frame: Int, frames: Int) -> [Float] {
        let lo = min(a.count, frame * 2), hi = min(a.count, (frame + frames) * 2)
        return Array(a[lo..<hi]) + [Float](repeating: 0, count: frames * 2 - (hi - lo))
    }
    /// The largest RMS difference relative to the RMS of `ref` over 0.125 s windows (a change confined to the quiet
    /// passages, like a gate's, counts as much as one on the loud parts).
    func segDiff(_ a: [Float], _ ref: [Float]) -> Double {
        let w = 2 * 6000
        var best = 0.0, i = 0
        while i < min(a.count, ref.count) {
            let j = min(i + w, a.count, ref.count)
            var r = 0.0
            for k in i..<j { r += Double(ref[k]) * Double(ref[k]) }
            if r / Double(j - i) > 1e-9 { best = max(best, relDiff(Array(a[i..<j]), Array(ref[i..<j]))) }
            i = j
        }
        return best
    }
    /// RMS of the difference relative to the RMS of `ref`.
    func relDiff(_ a: [Float], _ ref: [Float]) -> Double {
        var d = 0.0, r = 0.0
        for i in 0..<min(a.count, ref.count) { let x = Double(a[i] - ref[i]); d += x * x; r += Double(ref[i]) * Double(ref[i]) }
        return (d / max(r, 1e-12)).squareRoot()
    }

    func testRegistryCoverage() {
        XCTAssertEqual(Set(Self.everyType.map(\.0)), Set(AudioFx.ids), "every FX type is exercised")
    }

    // MARK: export (offline render)

    func testEveryFxTypeChangesTheExportRenderOnBothRacks() {
        for rack in Rack.allCases {
            for (type, params) in Self.everyType {
                let wet = AudioGraphRenderer.renderOffline(Self.project(Self.inputs(rack, Self.chain(type, params))))
                XCTAssertEqual(wet.count, Self.dryOffline.count)
                let d = segDiff(wet, Self.dryOffline)
                XCTAssertGreaterThan(d, 0.01, "\(rack) rack \(type): export output unchanged (rel diff \(d))")
            }
        }
    }

    func testEveryPresetChangesTheExportRenderOnBothRacks() {
        for rack in Rack.allCases {
            for p in AudioFxPresets.all {
                let chain = AudioFx.serializeChain(AudioFxPresets.apply(FxChain(), p))
                let d = segDiff(AudioGraphRenderer.renderOffline(Self.project(Self.inputs(rack, chain))), Self.dryOffline)
                XCTAssertGreaterThan(d, 0.01, "\(rack) rack preset \(p.id): export output unchanged (rel diff \(d))")
            }
        }
    }

    // MARK: preview (live playback)

    /// Plays from 0.3 s, applies the FX mid-playback through the updater (as the session does), and checks what the
    /// feeder renders once the swap's crossfade has passed: it is the FX project's own render at that position, bit
    /// for bit (the rebuilt graph is pre-rolled from frame 0), and it is not the dry signal.
    func testEveryFxTypeIsHeardInLivePlaybackOnBothRacks() {
        verifyEveryFxType(version: 1, requireAudibleChange: true)
    }

    /// V2 changes DSP semantics, while the live graph must still match the exported samples for every type.
    func testEveryV2TypeMatchesExportOnBothRacks() {
        verifyEveryFxType(version: 2, requireAudibleChange: false)
    }

    func verifyEveryFxType(version: Int, requireAudibleChange: Bool) {
        for rack in Rack.allCases {
            for (type, params) in Self.everyType {
                // Denoise learns its noise profile from the span `learn`/`learn_from` points at. The shared
                // params learn the first 100 ms (near-silence), which barely marks the loud slice this test
                // measures; learn from the loud burst under the slice instead, as a user pointing at the noisy
                // passage would. The export test keeps the shared params (it renders the whole second).
                let params = type == "denoise" ? #"{"amount":1,"learn":125,"learn_from":0.375}"# : params
                let source = GraphAudioSource(project: Self.project(Self.inputs()))
                let updater = LiveAudioGraphUpdater(source: source, loadStem: Self.loadStem)
                updater.submit(Self.inputs()); updater.waitUntilIdle()
                source.seek(0.3)
                _ = source.render(frames: 128 * 8)
                let fxInputs = Self.inputs(rack, Self.chain(type, params, version: version))
                updater.submit(fxInputs); updater.waitUntilIdle()
                XCTAssertEqual(source.lastReplace, .rebuilt, "\(rack) \(type)")
                XCTAssertEqual(source.position, 14400 + 128 * 8)
                // The rebuilt graph crossfades in over `declickFrames` (LiveDeclickTests), then plays alone.
                _ = source.render(frames: source.declickFrames)
                let at = source.position
                let got = source.render(frames: 128 * 100)
                let offline = AudioGraphRenderer.renderOffline(Self.project(fxInputs))
                XCTAssertTrue(got == slice(offline, frame: at, frames: 128 * 100), "\(rack) \(type): live differs from export at the same frame")
                if requireAudibleChange {
                    let d = segDiff(got, slice(Self.dryOffline, frame: at, frames: 128 * 100))
                    XCTAssertGreaterThan(d, 0.01, "\(rack) \(type): live output unchanged (rel diff \(d))")
                }
            }
        }
    }

    /// EQ band, gain-node and volume moves reach the running graph in place (no rebuild, no pre-roll), are heard
    /// at once, and settle onto the export render of the edited project.
    func testParameterSlidersApplyInPlaceAndAreHeard() {
        let eq = AudioEq.add(FxChain())
        for rack in Rack.allCases {
            let before = AudioFx.serializeChain(AudioFxPresets.apply(eq.chain, AudioFxPresets.preset("rumble-cut")!))
            var boosted = AudioFxPresets.apply(eq.chain, AudioFxPresets.preset("rumble-cut")!)
            boosted = AudioEq.setBandGain(boosted, eqId: eq.eqId, band: "Bass", gain: 9)
            boosted = AudioEq.setBandGain(boosted, eqId: eq.eqId, band: "Treble", gain: -9)
            let after = AudioFx.serializeChain(boosted)
            let source = GraphAudioSource(project: Self.project(Self.inputs(rack, before)))
            let updater = LiveAudioGraphUpdater(source: source, loadStem: Self.loadStem)
            updater.submit(Self.inputs(rack, before)); updater.waitUntilIdle()
            source.seek(0.2)
            let at = source.position
            let unedited = AudioGraphRenderer.renderOffline(Self.project(Self.inputs(rack, before)))
            updater.submit(Self.inputs(rack, after)); updater.waitUntilIdle()
            XCTAssertEqual(source.lastReplace, .parametersInPlace, "\(rack): an EQ band move must not rebuild the graph")
            let got = source.render(frames: 28800)
            XCTAssertGreaterThan(segDiff(got, slice(unedited, frame: at, frames: 28800)), 0.05, "\(rack): EQ move not heard")
            let edited = AudioGraphRenderer.renderOffline(Self.project(Self.inputs(rack, after)))
            // Filter state carries over from the old settings, so only the tail is compared with the export render.
            let tail = Array(got.suffix(2 * 12000)), ref = Array(slice(edited, frame: at, frames: 28800).suffix(2 * 12000))
            XCTAssertLessThan(relDiff(tail, ref), 1e-3, "\(rack): in-place EQ settles onto the export render")
            // Volume (clip or bus fader) is in place too.
            let vol = rack == .clip ? Self.inputs(clipFx: after, clipVolume: 0.25) : Self.inputs(busFx: after, busVolume: 0.25)
            updater.submit(vol); updater.waitUntilIdle()
            XCTAssertEqual(source.lastReplace, .parametersInPlace, "\(rack): a volume move must not rebuild the graph")
        }
    }

    // MARK: stress

    /// Every rack control (each preset, Add EQ, each EQ band as a drag, bypass, remove, Clear chain, the clip/bus
    /// volume) applied over and over on both racks, mixed with what the user does around edits: edit while playing,
    /// pause then edit then play, replay from the start, play from the playhead. The "main loop" (this thread)
    /// only does what the session's UI thread does (build inputs, submit, play/stop) and beats a heartbeat. Two
    /// things are measured. The property itself: the main loop makes no explicit wait on the graph worker
    /// (`LiveAudioGraphUpdater.waits` stays where it was; the one wait the test needs runs on another thread), and
    /// submit/play/stop each return in under 50 ms. And the wall clock: a watchdog thread records the largest gap
    /// between heartbeats, which must stay under a limit that starts at 250 ms and scales with what this runner
    /// does to an idle loop (a short calibration before the stress), so a GitHub runner shared with other jobs,
    /// which stalls every thread for hundreds of milliseconds, does not fail an unrelated change. The feeder must
    /// keep delivering audio and the last edit must be what plays.
    func testStressEveryControlBothRacksWithPlayPauseReplayNeverBlocksTheMainLoop() throws {
        let source = GraphAudioSource(project: Self.project(Self.inputs()))
        let updater = LiveAudioGraphUpdater(source: source, loadStem: Self.loadStem)
        updater.submit(Self.inputs()); updater.waitUntilIdle()
        let waitsBeforeStress = updater.waits
        let output = ClockedNullAudioOutput(format: source.format)
        let playback = AudioPlayback(output: output, source: source)

        // Calibration: the same 4 ms pacing the stress uses, with nothing of ours running yet. On an idle machine
        // each lap takes ~4 ms; a runner loaded by other jobs stretches the median and throws in long stalls.
        var laps: [UInt64] = []
        let calibrationEnd = DispatchTime.now().uptimeNanoseconds + 400_000_000
        while DispatchTime.now().uptimeNanoseconds < calibrationEnd {
            let t = DispatchTime.now().uptimeNanoseconds
            usleep(4000)
            laps.append(DispatchTime.now().uptimeNanoseconds - t)
        }
        laps.sort()
        let idleMedianMs = Double(laps[laps.count / 2]) / 1e6, idleMaxMs = Double(laps.last!) / 1e6
        let gapLimitMs = max(250, idleMedianMs * 40, idleMaxMs * 4)

        let watchdogState = WatchdogState()
        let watchdog = Thread {
            while true {
                usleep(2000)
                if !watchdogState.sample() { return }
            }
        }
        watchdog.start()
        func heartbeat(_ p: String) { watchdogState.heartbeat(p) }
        heartbeat("start")
        try playback.play(from: 0)
        heartbeat("play")
        defer { playback.stop() }

        var chains: [Rack: FxChain] = [.clip: FxChain(), .bus: FxChain()]
        var volumes: [Rack: Double] = [.clip: 1, .bus: 1]
        var last = Self.inputs()
        var steps = 0, replays = 0, maxSubmit: UInt64 = 0, maxTransport: UInt64 = 0
        func transport(_ name: String, _ body: () throws -> Void) rethrows {
            let t0 = DispatchTime.now().uptimeNanoseconds
            try body()
            maxTransport = max(maxTransport, DispatchTime.now().uptimeNanoseconds - t0)
            replays += 1
            heartbeat(name)
        }
        func apply(_ rack: Rack, _ next: FxChain? = nil, volume: Double? = nil) throws {
            if let next { chains[rack] = next }
            if let volume { volumes[rack] = volume }
            func s(_ c: FxChain) -> String? { c.nodes.isEmpty ? nil : AudioFx.serializeChain(c) }
            last = Self.inputs(clipFx: s(chains[.clip]!), busFx: s(chains[.bus]!), clipVolume: volumes[.clip]!, busVolume: volumes[.bus]!)
            let t0 = DispatchTime.now().uptimeNanoseconds
            updater.submit(last)
            maxSubmit = max(maxSubmit, DispatchTime.now().uptimeNanoseconds - t0)
            steps += 1
            heartbeat("\(rack) edit \(steps)")
            // The user's moves around edits, interleaved: replay from the start, pause + play at the playhead.
            switch steps % 23 {
            case 7: try transport("replay") { try playback.play(from: 0) }
            case 13: transport("pause") { playback.stop() }
            case 16: try transport("play at playhead") { try playback.play(from: playback.currentTime) }
            default: break
            }
            if !playback.isPlaying && steps % 23 > 16 { try transport("play") { try playback.play(from: 0.4) } }
            usleep(4000)   // ~250 edits a second: faster than any slider drag delivers
            heartbeat("between edits")
        }
        let framesBefore = output.framesWritten
        let t0 = Date()
        let rounds = 3
        for round in 0..<rounds {
            for rack in Rack.allCases {
                for p in AudioFxPresets.all {
                    let c = chains[rack]!
                    let on = AudioFxPresets.activeIds(c).contains(p.id)
                    try apply(rack, on ? FxChain(nodes: c.nodes.filter { $0.fromPreset != p.id }) : AudioFxPresets.apply(c, p))
                }
                let added = AudioEq.add(chains[rack]!)
                try apply(rack, added.chain)
                for band in ["Bass", "Middle", "Treble"] {
                    for k in 0...12 { try apply(rack, AudioEq.setBandGain(chains[rack]!, eqId: added.eqId, band: band, gain: Double(k - 6) * (round % 2 == 0 ? 1 : -1))) }
                }
                for k in 0..<10 { try apply(rack, volume: 0.2 + Double(k) * 0.08) }
                var c = chains[rack]!
                if !c.nodes.isEmpty { c.nodes[0].enabled = c.nodes[0].enabled == false ? nil : false; try apply(rack, c) }
                c = chains[rack]!
                if c.nodes.count > 1 { c.nodes.remove(at: 1); try apply(rack, c) }
                if round == rounds - 1 && rack == .clip { try apply(rack, FxChain()) }   // Clear chain
            }
        }
        if !playback.isPlaying { try playback.play(from: 0) }
        let editSeconds = Date().timeIntervalSince(t0)
        // The UI never waits for the worker; the test does, from another thread, while the main loop keeps beating.
        let waitsDuringStress = updater.waits - waitsBeforeStress
        let idle = DispatchSemaphore(value: 0)
        Thread.detachNewThread { updater.waitUntilIdle(); idle.signal() }
        var landed = false
        for _ in 0..<12000 {   // up to 120 s (debug build on a loaded CI box)
            if idle.wait(timeout: .now() + .milliseconds(10)) == .success { landed = true; break }
            heartbeat("idle: test polling for the worker")
        }
        heartbeat("landed")
        try playback.play(from: 0); heartbeat("final replay")
        for _ in 0..<30 { usleep(10_000); heartbeat("final play") }
        let watchdogResult = watchdogState.finish()
        let gapMs = Double(watchdogResult.gap) / 1e6, worstPhase = watchdogResult.phase
        let written = output.framesWritten - framesBefore
        print(String(format: "AUDIOFX-STRESS steps=%d transport=%d editSecs=%.2f waits=%d maxMainGapMs=%.1f(%@) gapLimitMs=%.0f idleMedianMs=%.2f idleMaxMs=%.1f maxSubmitMs=%.3f maxTransportMs=%.3f builds=%d framesWritten=%d lastReplace=%@",
                     steps, replays, editSeconds, waitsDuringStress, gapMs, worstPhase, gapLimitMs, idleMedianMs, idleMaxMs, Double(maxSubmit) / 1e6, Double(maxTransport) / 1e6, updater.builds, written,
                     "\(source.lastReplace.map { "\($0)" } ?? "nil")"))
        XCTAssertTrue(landed, "the graph worker never finished")
        XCTAssertEqual(waitsDuringStress, 0, "the main loop waited on the graph worker")
        XCTAssertLessThan(gapMs, gapLimitMs, "the main loop stalled (\(worstPhase)); idle laps median \(idleMedianMs) ms, max \(idleMaxMs) ms")
        XCTAssertLessThan(Double(maxSubmit) / 1e6, 50, "submit must not wait on the graph")
        XCTAssertLessThan(Double(maxTransport) / 1e6, 50, "play/stop must not wait on the graph or the feeder")
        XCTAssertTrue(playback.isPlaying, "playback stopped")
        XCTAssertGreaterThan(replays, 20)
        XCTAssertGreaterThan(written, 48000 / 2, "the feeder stalled")
        XCTAssertGreaterThan(updater.builds, 0)
        // What plays now is the last edit.
        let final = Self.project(last)
        XCTAssertEqual(source.project.tracks.map { $0.fxChain }, final.tracks.map { $0.fxChain })
        XCTAssertEqual(source.project.groups.map { $0.fxChain }, final.groups.map { $0.fxChain })
        XCTAssertEqual(source.project.groups.map { $0.volume }, final.groups.map { $0.volume })
        XCTAssertNil(source.project.tracks.first { $0.id == "a" }?.fxChain, "Clear chain landed on the clip")
        XCTAssertNotNil(source.project.groups.first?.fxChain, "the bus chain landed")
    }
}
