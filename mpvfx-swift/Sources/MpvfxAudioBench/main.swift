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
import MpvfxAudio
import MpvfxAudioGraph

// Render-speed benchmark: every-FX fixture, offline renderAll and live 128-frame blocks, vs real time,
// plus seek pre-roll cost. Build with -c release.
func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
let args = CommandLine.arguments
let seconds = args.count > 1 ? Double(args[1]) ?? 30 : 30
let project = AudioGraphFixtures.everyFX(seconds: seconds)
print("every-FX fixture: \(seconds) s, \(project.totalFrames) frames @ \(Int(project.sampleRate)) Hz")
var best = Double.infinity
for _ in 0..<3 { let t = now(); _ = AudioGraphRenderer.renderOffline(project); best = min(best, now() - t) }
print(String(format: "renderAll:        %.3f s  -> %.1fx real time", best, seconds / best))
var bestBlocks = Double.infinity
for _ in 0..<3 {
    let src = GraphAudioSource(project: project); let t = now()
    while src.position < project.totalFrames { _ = src.render(frames: GraphAudioSource.quantum) }
    bestBlocks = min(bestBlocks, now() - t)
}
print(String(format: "128-frame blocks: %.3f s  -> %.1fx real time (%.1f us per block, budget %.0f us)",
             bestBlocks, seconds / bestBlocks, bestBlocks / Double(project.totalFrames / 128) * 1e6, 128.0 / 48000 * 1e6))
for frac in [0.25, 0.5, 0.95] {
    let src = GraphAudioSource(project: project)
    src.seek(seconds * frac)
    let p = src.lastPreRoll!
    print(String(format: "seek pre-roll to %5.1f s: %.3f s", Double(p.targetFrame) / 48000, p.seconds))
}
