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
import MpvfxCanvas
import MpvfxDesktopCore
import MpvfxShared
import MpvfxTimeline
import MpvfxPlayer
import MpvfxPanels

/// Smoke stress for memory (MPVFX_SMOKE_MEMORY=<rounds>): drives the open project through rounds of play, scrub,
/// grade edits (every visible video clip, undone every other round), reverse play and replay, drawing the preview
/// each step through the session's compositor, and samples the process footprint (`ResidentMemory`: phys_footprint
/// on macOS, VmRSS on Linux) after every round. Halfway through it simulates a memory-pressure warning and checks
/// the frame cache gave memory back.
///
/// Fails when the footprint grows by more than MPVFX_SMOKE_MEMORY_LIMIT_MB (default 256) after the first round,
/// not counting what the budgeted caches added (they may fill up to their budgets), or when a cache is ever over its
/// budget. Prints `[MpVFX] memory-stress PASS|FAIL: ...` and exits 0 / 4. MPVFX_SMOKE_MEMORY_VERBOSE=1 prints every
/// round; MPVFX_SMOKE_MEMORY_MEDIA puts bin files on the timeline first.
final class MemoryStress {
    let session: EditorSession
    let rounds: Int
    let schedule: (Double, @escaping () -> Void) -> () -> Void
    let limitBytes: Int
    let verbose: Bool
    /// Bin files put on the timeline first, each on its own track.
    let media: [String]
    let view = CanvasRect(x: 0, y: 0, width: 960, height: 540)
    #if os(Linux)
    let target: CairoImageTarget
    var canvas: CanvasContext? { target.canvas }
    #elseif canImport(CoreGraphics) && canImport(CoreText)
    let offscreen: CoreGraphicsCanvas?
    var canvas: CanvasContext? { offscreen }
    #else
    var canvas: CanvasContext? { nil }
    #endif

    struct Sample { var footprint: Int; var cached: Int }
    var samples: [Sample] = []
    var overBudget: [String] = []
    var pressureFreed = true
    var draws = 0

    init(session: EditorSession, rounds: Int, hooks: SmokeHooks, schedule: @escaping (Double, @escaping () -> Void) -> () -> Void) {
        self.session = session; self.rounds = max(2, rounds); self.schedule = schedule
        limitBytes = hooks.memoryLimitMB << 20
        verbose = hooks.memoryVerbose; media = hooks.memoryMedia
        #if os(Linux)
        target = CairoImageTarget(width: Int(view.width), height: Int(view.height))
        #elseif canImport(CoreGraphics) && canImport(CoreText)
        offscreen = CoreGraphicsCanvas.offscreen(width: Int(view.width), height: Int(view.height))
        #endif
    }

    var compositor: PreviewCompositor { session.compositor }
    /// Bytes the budgeted caches hold right now (subtracted from footprint growth).
    var cachedBytes: Int { compositor.cache.bytes + compositor.gradedMemoBytes + session.mediaThumbnails.bytes }

    func draw(playing: Bool, speed: Double = 1) {
        draws += 1
        if let c = canvas {
            compositor.draw(c, in: view, time: session.playback.currentTime, elements: [],
                            context: FrameDrawContext(isPlaying: playing, speed: speed))
        }
        session.redraw()
        let cache = compositor.cache
        if cache.bytes > cache.budgetBytes { overBudget.append("frames \(cache.bytes >> 20)MB > \(cache.budgetBytes >> 20)MB") }
        if session.mediaThumbnails.bytes > session.mediaThumbnails.budgetBytes { overBudget.append("thumbnails") }
    }

    /// The steps of one round, run one per main-loop turn ~1/30 s apart.
    func round(_ r: Int) -> [() -> Void] {
        var steps: [() -> Void] = []
        let duration = max(session.playback.duration, 1 / 30)
        // Play from the start (replay), about three seconds of real playback.
        steps.append { [unowned self] in self.session.playback.seek(0); self.session.playback.play() }
        for _ in 0..<90 { steps.append { [unowned self] in _ = self.session.tick(1.0 / 30); self.draw(playing: true) } }
        steps.append { [unowned self] in self.session.playback.pause(); self.session.syncAudio() }
        // Scrub across the timeline.
        for i in 0..<30 {
            steps.append { [unowned self] in
                self.session.playback.seek(duration * Double((i * 37 + r * 11) % 100) / 100)
                self.session.timeline.syncFromPlayback(); self.draw(playing: false)
            }
        }
        // Grade every visible video clip (one undo step each), then undo them on even rounds.
        steps.append { [unowned self] in
            let ids = self.compositor.composition?.entries.filter { $0.kind == .video }.map(\.clip.id) ?? []
            for id in ids {
                var g = self.session.editor.colorGrading(clipId: id) ?? ColorGrading()
                g.adjust["exposure"] = 0.1 + Double(r % 5) * 0.1
                g.adjust["saturation"] = Double(r % 3) * 0.2 - 0.2
                self.session.editor.setColorGrading(clipId: id, g)
            }
            self.session.syncStage(); self.draw(playing: false)
            if r % 2 == 0 { for _ in ids { self.session.editor.undo() }; self.session.syncStage(); self.draw(playing: false) }
        }
        // Reverse a second from the middle.
        steps.append { [unowned self] in self.session.playback.seek(duration / 2) }
        for _ in 0..<30 {
            steps.append { [unowned self] in
                self.session.playback.seek(max(0, self.session.playback.currentTime - 1.0 / 30)); self.draw(playing: true, speed: -1)
            }
        }
        if r == rounds / 2 {
            steps.append { [unowned self] in
                MemoryPressureMonitor.shared.simulate(.warning)
                let cache = self.compositor.cache
                if cache.bytes > cache.budgetBytes / 2 { self.pressureFreed = false }
            }
        }
        steps.append { [unowned self] in
            let s = Sample(footprint: ResidentMemory.footprintBytes() ?? 0, cached: self.cachedBytes)
            self.samples.append(s)
            if self.verbose {
                print("[MpVFX] memory-stress round \(r): footprint \(s.footprint >> 20) MB, caches \(s.cached >> 20) MB (frames \(self.compositor.cache.bytes >> 20) MB in \(self.compositor.cache.count), budget \(self.compositor.cache.budgetBytes >> 20) MB)")
            }
        }
        return steps
    }

    func start(done: @escaping (Bool, String) -> Void) {
        let start = ResidentMemory.footprintBytes() ?? 0
        // MPVFX_SMOKE_MEMORY_MEDIA: bin files (":"-separated) put on the timeline first, each on its own track.
        for path in media {
            session.panels?.addToTimeline(path: path, at: 0)
        }
        session.syncStage()
        var plan: [() -> Void] = []
        for r in 0..<rounds { plan += round(r) }
        var index = 0
        func step() {
            guard index < plan.count else { return finish(start, done) }
            plan[index](); index += 1
            _ = schedule(1.0 / 30, step)
        }
        _ = schedule(2.0, step)   // media added above is placed once its length is probed
    }

    func finish(_ start: Int, _ done: (Bool, String) -> Void) {
        let first = samples.first ?? Sample(footprint: start, cached: 0), last = samples.last ?? first
        let peak = samples.map(\.footprint).max() ?? 0
        // Growth after the first round that the caches do not account for.
        let unaccounted = (last.footprint - first.footprint) - (last.cached - first.cached)
        let passed = unaccounted <= limitBytes && overBudget.isEmpty && pressureFreed && last.footprint > 0
        let report = "rounds=\(rounds) draws=\(draws) start=\(start >> 20)MB afterRound1=\(first.footprint >> 20)MB end=\(last.footprint >> 20)MB peak=\(peak >> 20)MB "
            + "cachesEnd=\(last.cached >> 20)MB unaccountedGrowth=\(unaccounted >> 20)MB limit=\(limitBytes >> 20)MB "
            + "frameBudget=\(compositor.cache.budgetBytes >> 20)MB framePeak=\(compositor.cache.peakBytes >> 20)MB pressureFreed=\(pressureFreed)"
            + (overBudget.isEmpty ? "" : " overBudget=\(overBudget.prefix(3))")
        done(passed, report)
    }
}

extension EditorSession {
    /// MPVFX_SMOKE_MEMORY=<rounds>: runs `MemoryStress` on this session and exits with its verdict.
    func startMemoryStress(rounds: Int, hooks: SmokeHooks, schedule: @escaping (Double, @escaping () -> Void) -> () -> Void) -> MemoryStress {
        let stress = MemoryStress(session: self, rounds: rounds, hooks: hooks, schedule: schedule)
        stress.start { passed, report in
            print("[MpVFX] memory-stress \(passed ? "PASS" : "FAIL"): \(report)")
            exit(passed ? 0 : 4)
        }
        return stress
    }
}
