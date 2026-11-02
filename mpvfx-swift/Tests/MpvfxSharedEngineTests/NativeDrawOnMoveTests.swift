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
// Issue #325 A1/A2 (shared half): the draw-on In move carries a draw progress and nothing else, evaluated through the
// real keyframe engine like every other move.
import XCTest
@testable import MpvfxShared
import OneTakeKeyframes

final class NativeDrawOnMoveTests: XCTestCase {
    let canvas = NativeCanvas(width: 200, height: 100, background: "#000000")
    func clip(_ moves: NativeClipMoves) -> NativeProjectClip {
        var c = NativeProjectClip.fresh(id: "c", assetId: "a", startFrame: 0, durationFrames: 41); c.moves = moves; return c
    }
    func offsets(_ moves: NativeClipMoves, _ f: Int, _ engine: KeyframeEngine) throws -> NativeMoveOffsets {
        try nativeClipMoveOffsets(clip(moves), clipFrame: f, canvas: canvas, engine: engine)
    }

    func testDrawProgressRisesFromZeroToOneOverTheInAndTouchesNothingElse() throws {
        let engine = try KeyframeRuntime()
        let moves = NativeClipMoves(in: NativeEdgeMove(kind: .draw, frames: 10, ease: .linear))
        for (frame, progress) in [(0, 0.0), (5, 0.5), (8, 0.8), (10, 1.0), (30, 1.0)] {
            let o = try offsets(moves, frame, engine)
            XCTAssertEqual(o.drawProgress, progress, accuracy: 1e-9, "frame \(frame)")
            XCTAssertEqual(NativeMoveOffsets(dx: o.dx, dy: o.dy, scale: o.scale, rotation: o.rotation, opacity: o.opacity), .identity,
                           "frame \(frame): draw-on moves no other property")
        }
        XCTAssertEqual(try offsets(moves, 10, engine), .identity, "at rest the offsets are the identity")
    }

    func testDrawProgressCombinesWithOtherMovesAndTheKindHasNoDirectionOrAmount() throws {
        let engine = try KeyframeRuntime()
        let moves = NativeClipMoves(in: NativeEdgeMove(kind: .draw, frames: 10, ease: .linear),
                                    loop: NativeLoopMove(kind: .pulse, periodFrames: 20, amount: 10, ease: .linear))
        let o = try offsets(moves, 5, engine)
        XCTAssertEqual(o.drawProgress, 0.5, accuracy: 1e-9)
        XCTAssertEqual(o.scale, 1.05, accuracy: 1e-9, "the loop still plays while the stroke draws on")
        XCTAssertFalse(NativeEdgeMoveKind.draw.takesDirection)
        XCTAssertFalse(NativeEdgeMoveKind.draw.fades)
        XCTAssertFalse(NativeEdgeMoveKind.draw.accepts(amount: 50))
        XCTAssertEqual(NativeMoveOffsets(drawProgress: 0.5).combined(with: NativeMoveOffsets(drawProgress: 0.5)).drawProgress, 0.25)
    }
}
