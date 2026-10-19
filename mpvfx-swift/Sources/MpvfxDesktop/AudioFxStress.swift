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
#if os(Windows)
import MpvfxShared   // usleep
import WinSDK        // GetThreadTimes
#endif
import MpvfxAudio
import MpvfxAudioGraph
import MpvfxTimeline
import MpvfxPlayer

/// Smoke stress for audio FX edits while playing (MPVFX_SMOKE_AUDIOFX_STRESS=N with a clip selected): every audio
/// FX control of the inspector (each preset chip, Add EQ, each EQ band slider, chain bypass and remove, Clear
/// chain, group volume) is applied N times in quick succession, one edit per main-loop turn, alternating between
/// the clip's rack and the group bus rack, through the real inspector rows and the session's edit path, with the
/// audio graph running. A watchdog
/// thread checks the main loop's 10 ms heartbeat: any gap over `stallLimit` means the UI hung. Reports through
/// `done(passed, report)`.
#if os(Linux)
typealias StressBacktrace = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>, Int32) -> Int32
typealias StressBacktraceSymbols = @convention(c) (UnsafePointer<UnsafeMutableRawPointer?>, Int32, Int32) -> Void
nonisolated(unsafe) var stressBacktrace: StressBacktrace?
nonisolated(unsafe) var stressBacktraceSymbols: StressBacktraceSymbols?
#endif

final class AudioFxStress {
    static let stallLimit = 0.25
    let session: EditorSession
    let panels: SessionPanels
    let schedule: (Double, @escaping () -> Void) -> () -> Void
    let rounds: Int
    let lock = NSLock()
    var lastBeat = 0.0, maxGap = 0.0, stalls = 0, finished = false
    var maxStep = 0.0, maxStepName = "", steps = 0, missing = Set<String>()
    var plan: [(String, () -> Bool)] = []
    /// MPVFX_SMOKE_AUDIOFX_VERBOSE=1: every missing row and the plan go to stderr (set by `SmokeRunner`).
    var verbose = false
    /// MPVFX_SMOKE_AUDIOFX_STACKS=1 (Linux): on a stall, the main thread prints its own stack.
    var dumpStacks = false

    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
    /// CPU time of the calling thread: separates work done on the main thread from time it lost to other load
    /// (a shared 2-core CI box) or spent blocked.
    static func cpu() -> Double {
#if os(Windows)
        var creation = FILETIME(), exit = FILETIME(), kernel = FILETIME(), user = FILETIME()
        guard GetThreadTimes(GetCurrentThread(), &creation, &exit, &kernel, &user) else { return 0 }
        func ticks(_ t: FILETIME) -> Double { Double(UInt64(t.dwHighDateTime) << 32 | UInt64(t.dwLowDateTime)) }
        return (ticks(kernel) + ticks(user)) / 1e7   // 100 ns units
#else
        var spec = timespec(); clock_gettime(CLOCK_THREAD_CPUTIME_ID, &spec)
        return Double(spec.tv_sec) + Double(spec.tv_nsec) / 1e9
#endif
    }
    var maxStepCPU = 0.0, maxStepCPUName = ""

    init(session: EditorSession, panels: SessionPanels, rounds: Int, schedule: @escaping (Double, @escaping () -> Void) -> () -> Void) {
        self.session = session; self.panels = panels; self.rounds = rounds; self.schedule = schedule
    }

    var clipId: String?, groupId: String?
    var lastPaused = false

    /// One round: every control of one rack once (even rounds the selected clip's rack, odd rounds the group bus
    /// rack opened from the timeline group header). Values alternate so each application changes the document.
    func round(_ i: Int) -> [(String, () -> Bool)] {
        var r: [(String, () -> Bool)] = []
        let bus = i % 2 == 1
        r.append((bus ? "open:bus" : "open:clip", { [unowned self] in
            if bus {
                guard let g = self.groupId else { return false }
                self.session.openAudioGroupRack(g)
                return self.panels.right.inspector.audioGroupId == g
            }
            guard let c = self.clipId else { return false }
            self.session.timeline.view.selection = [c]; self.session.syncStage(); self.session.redraw()
            return true
        }))
        let tag = bus ? "bus/" : "clip/"
        func row(_ key: String, _ value: String) -> (String, () -> Bool) {
            (tag + key, { [unowned self] in self.panels.applyInspectorRow(key, value) })
        }
        for p in AudioFxPresets.all { r.append(row("preset:\(p.id)", "")) }
        r.append(row("eq:add", ""))
        for band in ["Bass", "Middle", "Treble"] { r.append(row("eq:\(band)", String(Double((i * 7) % 25) - 12))) }
        r.append(row("groupVolume", i % 4 < 2 ? "0.3" : "0.7"))
        r.append(row("fx:0", "toggle"))
        r.append(row("fx:1", "remove"))
        if i % 10 >= 8 { r.append(row("fx:clear", "")) }
        r += mixed(i)
        return r
    }

    var videoId: String?
    var splitDone = false

    /// What users do around edits (the reported "edit, then play / replay hangs"): video edits (transform, crop)
    /// and audio edits (volume, trim, split), each with playback restarted, paused, resumed at the playhead and
    /// replayed from the start, plus undo. Every step goes through the session's own paths.
    func mixed(_ i: Int) -> [(String, () -> Bool)] {
        let s = session, ed = session.editor
        func edit(_ label: String, _ body: @escaping () -> Bool) -> (String, () -> Bool) {
            ("mix/" + label, { let ok = ed.withHistory(label) { body() }; if ok { s.syncStage(); s.redraw() }; return ok })
        }
        func transport(_ label: String, _ body: @escaping () -> Void) -> (String, () -> Bool) {
            ("mix/" + label, { body(); s.timeline.syncFromPlayback(); s.syncStage(); s.syncAudio(); s.redraw(); return true })
        }
        let replay = transport("replay") { s.playback.seek(0); s.playback.play() }
        let pause = transport("pause") { s.playback.pause() }
        let resume = transport("play") { s.playback.play() }
        var r: [(String, () -> Bool)] = [replay]
        if let v = videoId {
            r.append(edit("Edit transform") { ed.applyTransform(clipId: v, time: s.playback.currentTime, ClipTransform(x: Double(10 + i * 7), y: Double(5 + i * 3))) })
            r.append(pause)
            r.append(("mix/crop", { s.persistCrop(id: v, CropInsets(top: Double(i % 5) * 4, right: 0, bottom: 0, left: Double(i % 3) * 6)); s.syncStage(); s.redraw(); return true }))
            r.append(resume)
        }
        if let c = clipId {
            r.append(edit("Set volume") { ed.setClipVolume(clipId: c, i % 2 == 0 ? 0.6 : 0.9) })
            r.append(pause)
            r.append(edit("Trim clip") {
                guard let (_, clip) = ed.clip(c), let a = ed.address(clipId: c) else { return false }
                return ed.apply(.trimOut(address: a, endFrameExclusive: clip.startFrame + clip.durationFrames - 3))
            })
            r.append(resume)
            r.append(replay)
            if !splitDone, i % 2 == 1 {
                r.append(edit("Split clip") { [unowned self] in
                    guard let (_, clip) = ed.clip(c), let a = ed.address(clipId: c) else { return false }
                    self.splitDone = ed.apply(.split(address: a, splitFrame: (clip.startFrame + clip.durationFrames / 2).rounded()))
                    return self.splitDone
                })
            }
        }
        r.append(("mix/undo", { let ok = ed.undo(); s.syncStage(); s.redraw(); return ok }))
        r.append(transport("play at playhead") { s.playback.play() })
        return r
    }

    /// Waits (up to 20 s) for the media that MPVFX_SMOKE_ADD_MEDIA adds to land on the timeline selected (the add
    /// probes the file first), then runs.
    func start(seek: Double, startPlayTimer: @escaping () -> Void, done: @escaping (Bool, String) -> Void, waited: Double = 0) {
        let sel = session.timeline.view.selection.first
        if (sel == nil || session.editor.clip(sel!) == nil) && waited < 20 {
            _ = schedule(0.1) { [self] in start(seek: seek, startPlayTimer: startPlayTimer, done: done, waited: waited + 0.1) }
            return
        }
        // A second copy of the clip, grouped with the selection, so group volume and group FX have a bus to edit.
        let ed = session.editor
        if let sel = session.timeline.view.selection.first, let (_, c) = ed.clip(sel),
           let other = ed.insertClip(assetId: c.assetId, at: 0) {
            clipId = sel
            groupId = ed.createAudioGroup(clipIds: [sel, other])
            if groupId == nil { print("[MpVFX] audiofx-stress: could not group (\(ed.lastFailure.map { "\($0)" } ?? "?"))") }
            // A video clip above it for the picture edits (any video asset the project has).
            if let v = ed.document.assets.first(where: { $0.kind == .video }) { videoId = ed.insertClip(assetId: v.id, at: 0) }
            session.timeline.view.selection = [sel]; session.syncStage()
        }
        for i in 0..<rounds { plan += round(i) }
        if verbose { FileHandle.standardError.write(Data("[MpVFX] audiofx-stress: clip \(clipId ?? "none") group \(groupId ?? "none") video \(videoId ?? "none"), \(plan.count) steps\n".utf8)) }
        lastBeat = Self.now()
        // Main-loop heartbeat.
        func beat() {
            lock.lock(); let over = finished; lastBeat = Self.now(); lock.unlock()
            if !over { _ = schedule(0.01, beat) }
        }
        beat()
        // Watchdog: measures the longest heartbeat gap from outside the main thread (a hung main loop cannot report).
        #if os(Linux)
        // dumpStacks: on a stall, the main thread prints its own stack (SIGUSR1 handler), so a hang names the code
        // it is stuck in without a debugger.
        let dumpStacks = self.dumpStacks
        let mainThread = pthread_self()
        if dumpStacks {
            stressBacktrace = dlsym(nil, "backtrace").map { unsafeBitCast($0, to: StressBacktrace.self) }
            stressBacktraceSymbols = dlsym(nil, "backtrace_symbols_fd").map { unsafeBitCast($0, to: StressBacktraceSymbols.self) }
            signal(SIGUSR1) { _ in
                guard let bt = stressBacktrace, let sym = stressBacktraceSymbols else { return }
                var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 48)
                let n = bt(&frames, 48)
                sym(&frames, n, 2)
                _ = write(2, "----\n", 5)
            }
        }
        #endif
        Thread.detachNewThread { [weak self] in
            var dumped = 0, level = 0
            while let self {
                usleep(5000)
                self.lock.lock()
                if self.finished { self.lock.unlock(); return }
                let gap = Self.now() - self.lastBeat
                if gap > self.maxGap { self.maxGap = gap }
                if gap > Self.stallLimit && gap - 0.005 <= Self.stallLimit { self.stalls += 1 }
                self.lock.unlock()
                #if os(Linux)
                if dumpStacks, gap > 0.2, dumped < 40, Int(gap / 0.2) > level {
                    dumped += 1; level = Int(gap / 0.2)
                    FileHandle.standardError.write(Data(String(format: "[MpVFX] audiofx-stress stall %.0f ms, main stack:\n", gap * 1000).utf8))
                    pthread_kill(mainThread, SIGUSR1)
                }
                if gap < 0.05 { level = 0 }
                #endif
            }
        }
        session.playback.seek(seek); session.timeline.syncFromPlayback()
        session.playback.play(); startPlayTimer()
        let t0 = Self.now()
        var index = 0
        func step() {
            guard index < plan.count else { finish(t0, done); return }
            let (name, run) = plan[index]; index += 1
            let s = Self.now(), c = Self.cpu()
            if !run() {
                if verbose && missing.isEmpty {
                    let ins = panels.right.inspector
                    FileHandle.standardError.write(Data("[MpVFX] audiofx-stress: no row \(name); selection=\(ins.selection) groups=\(ins.groups.map { "\($0.id):\($0.rows.count)" })\n".utf8))
                }
                missing.insert(name)
            }
            let d = Self.now() - s, dc = Self.cpu() - c
            if dc > maxStepCPU { maxStepCPU = dc; maxStepCPUName = name }
            steps += 1
            if d > maxStep { maxStep = d; maxStepName = name }
            if verbose && index % 10 == 0 { profile() }
            if verbose {
                lock.lock(); let gap = maxGap; lock.unlock()
                FileHandle.standardError.write(Data(String(format: "[MpVFX] audiofx-stress step %d %@ ok=%@ %.1f ms wall %.1f ms cpu (max main gap so far %.1f ms)\n",
                                                           index, name, "\(!missing.contains(name))", d * 1000, dc * 1000, gap * 1000).utf8))
            }
            if name == "mix/pause" { lastPaused = true } else if lastPaused || !session.playback.isPlaying {
                lastPaused = false
                if !session.playback.isPlaying { session.playback.play() }
            }
            if session.playback.isPlaying { startPlayTimer() }
            _ = schedule(0, step)
        }
        _ = schedule(0.3, step)
    }

    /// Verbose: what each piece of the edit path costs on the main thread right now.
    func profile() {
        func t(_ body: () -> Void) -> String { let s = Self.now(); body(); return String(format: "%.1f", (Self.now() - s) * 1000) }
        let ed = session.editor
        let onChange = t { ed.onChange?() }
        let decoders = t { session.composedDocument = nil; session.syncDecoderClips() }
        let stage = t { session.syncStage() }
        let items = t { panels.syncItems() }
        let inputs = t { _ = DocumentAudioGraph.inputs(ed.document, duration: ed.duration, projectDir: nil) }
        let groups = t { _ = panels.right.inspector.groups }
        let docEq = t { _ = ed.document == session.savedDocument }
        let chainLen = (session.graphInputs?.tracks.compactMap(\.fxChain).map(\.count).max() ?? 0)
        FileHandle.standardError.write(Data("[MpVFX] audiofx-stress profile ms: onChange=\(onChange) decoders=\(decoders) syncStage=\(stage) syncItems=\(items) audioInputs=\(inputs) inspectorGroups=\(groups) docCompare=\(docEq) fxChainChars=\(chainLen)\n".utf8))
    }

    func finish(_ t0: Double, _ done: @escaping (Bool, String) -> Void) {
        // Let the graph worker land the last edit while still playing, then check the main loop stayed live.
        _ = schedule(1.0) { [self] in
            lock.lock(); finished = true; let gap = maxGap, n = stalls; lock.unlock()
            let audio = session.audio
            let report = String(format: "steps=%d secs=%.1f maxMainGapMs=%.1f stalls=%d maxStepMs=%.1f(%@) maxStepCpuMs=%.1f(%@) builds=%d lastReplace=%@ playing=%@ audioTime=%.2f playhead=%.2f missing=%@",
                                steps, Self.now() - t0, gap * 1000, n, maxStep * 1000, maxStepName, maxStepCPU * 1000, maxStepCPUName, session.graphUpdater?.builds ?? -1,
                                "\(session.graph?.lastReplace.map { "\($0)" } ?? "nil")", "\(audio?.isPlaying ?? false)",
                                audio?.currentTime ?? -1, session.playback.currentTime, missing.sorted().joined(separator: ","))
            done(gap <= Self.stallLimit && maxStep <= Self.stallLimit, report)
        }
    }
}
