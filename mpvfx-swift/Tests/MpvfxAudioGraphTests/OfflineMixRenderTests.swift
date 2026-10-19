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

/// The export entry points: `AudioGraphRenderer.render(_:from:frames:)` and `advance(to:)` give the same samples as
/// the whole-project render (and therefore as live playback, which `GraphPlaybackTests` holds to `renderAll`).
final class OfflineMixRenderTests: XCTestCase {
    func testSpanFromAnyFrameEqualsTheWholeRender() {
        let mismatches = ["flat", "grouped", "busGain"].flatMap(spanMismatches)
        XCTAssertEqual(mismatches, [], "spans that differ from renderOffline")
    }

    /// "<project>@<start>" for every span start whose render differs from that span of the whole render.
    func spanMismatches(_ name: String) -> [String] {
        let project = RenderParityTests.project(name)
        let whole = AudioGraphRenderer.renderOffline(project)
        let total = whole.count / 2
        let spans = [0, 1, 127, 128, 4801, total / 2, total - 300, total - 10, total + 5].map { start -> String? in
            let got = AudioGraphRenderer.render(project, from: start, frames: 256)
            let lo = min(total, start), hi = min(total, start + 256)
            return got == Array(whole[(2 * lo)..<(2 * hi)]) ? nil : "\(name)@\(start)"
        }
        return spans.compactMap { $0 }
    }

    func testAdvanceThenChunksEqualsTheWholeRender() {
        let project = RenderParityTests.project("grouped")
        let whole = AudioGraphRenderer.renderOffline(project)
        let r = AudioGraphRenderer(project)
        r.advance(to: 3000)
        XCTAssertEqual(r.position, 3000)
        r.advance(to: 100)
        XCTAssertEqual(r.position, 3000, "advance never goes back")
        let chunks = (0..<((r.totalFrames - 3000 + 999) / 1000)).flatMap { _ in r.render(1000) }
        XCTAssertTrue(chunks == Array(whole[6000...]))
        r.advance(to: r.totalFrames + 50)
        XCTAssertEqual(r.position, r.totalFrames)
    }

    func testOfflineMixIsNotSilentAndInRange() {
        let pcm = AudioGraphRenderer.renderOffline(RenderParityTests.project("grouped"))
        XCTAssertGreaterThan(rms(pcm, at: 0.2), 0.001)
        XCTAssertTrue(pcm.allSatisfy { $0.isFinite })
    }
}
