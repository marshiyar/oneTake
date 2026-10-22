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
// Issue #273 A2: every move kind at its first, middle and last frame against the formula in NativeClipMoves.swift,
// evaluated through the real keyframe engine (linear ease, so the formula's weight is exact).
import XCTest
@testable import MpvfxShared
import OneTakeKeyframes

final class NativeClipMovesFormulaTests: XCTestCase {
    let canvas = NativeCanvas(width: 200, height: 100, background: "#000000")
    /// A 41-frame clip: an In of 10 frames covers 0…10, an Out of 10 covers 30…40, a Loop of 20 has halves of 10.
    func clip(_ moves: NativeClipMoves) -> NativeProjectClip {
        var c = NativeProjectClip.fresh(id: "c", assetId: "a", startFrame: 0, durationFrames: 41); c.moves = moves; return c
    }
    func offsets(_ moves: NativeClipMoves, _ f: Int, _ engine: KeyframeEngine) throws -> NativeMoveOffsets {
        try nativeClipMoveOffsets(clip(moves), clipFrame: f, canvas: canvas, engine: engine)
    }
    func assertClose(_ a: NativeMoveOffsets, _ b: NativeMoveOffsets, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        for (x, y, name) in [(a.dx, b.dx, "dx"), (a.dy, b.dy, "dy"), (a.scale, b.scale, "scale"), (a.rotation, b.rotation, "rotation"), (a.opacity, b.opacity, "opacity")] {
            XCTAssertEqual(x, y, accuracy: 1e-9, "\(what) \(name)", file: file, line: line)
        }
    }

    /// (kind, amount, In offsets at weight 1 and 0.5, Out offsets at weight 1) from the formulas, W 200, H 100.
    static let edgeTable: [(NativeEdgeMoveKind, Double, NativeMoveOffsets, NativeMoveOffsets)] = [
        (.slide, 50, NativeMoveOffsets(dx: -100), NativeMoveOffsets(dx: -100)),                       // direction left
        (.rise, 10, NativeMoveOffsets(dy: 10, opacity: 0), NativeMoveOffsets(dy: -10, opacity: 0)),
        (.drop, 20, NativeMoveOffsets(dy: -20, opacity: 0), NativeMoveOffsets(dy: 20, opacity: 0)),
        (.grow, 40, NativeMoveOffsets(scale: 0.6, opacity: 0), NativeMoveOffsets(scale: 1.4, opacity: 0)),
        (.shrink, 40, NativeMoveOffsets(scale: 1.4, opacity: 0), NativeMoveOffsets(scale: 0.6, opacity: 0)),
        (.spin, 90, NativeMoveOffsets(rotation: -90, opacity: 0), NativeMoveOffsets(rotation: 90, opacity: 0)),
    ]

    func half(_ o: NativeMoveOffsets) -> NativeMoveOffsets {
        NativeMoveOffsets(dx: o.dx / 2, dy: o.dy / 2, scale: 1 + (o.scale - 1) / 2, rotation: o.rotation / 2, opacity: 1 - (1 - o.opacity) / 2)
    }

    func testA2EveryInAndOutKindAtItsFirstMiddleAndLastFrameMatchesItsFormula() throws {
        let engine = try KeyframeRuntime()
        for (kind, amount, inAway, outAway) in Self.edgeTable {
            let move = NativeEdgeMove(kind: kind, frames: 10, amount: amount, ease: .linear)
            let entering = NativeClipMoves(in: move)
            assertClose(try offsets(entering, 0, engine), inAway, "\(kind) In first frame")
            assertClose(try offsets(entering, 5, engine), half(inAway), "\(kind) In middle")
            assertClose(try offsets(entering, 10, engine), .identity, "\(kind) In last frame: at rest")
            let leaving = NativeClipMoves(out: move)
            assertClose(try offsets(leaving, 30, engine), .identity, "\(kind) Out first frame: at rest")
            assertClose(try offsets(leaving, 35, engine), half(outAway), "\(kind) Out middle")
            assertClose(try offsets(leaving, 40, engine), outAway, "\(kind) Out last frame")
        }
    }

    func testA2SlideDirectionsLeaveByTheirEdge() throws {
        let engine = try KeyframeRuntime()
        let expected: [(NativeMoveDirection, NativeMoveOffsets)] = [(.left, .init(dx: -200)), (.right, .init(dx: 200)), (.up, .init(dy: -100)), (.down, .init(dy: 100))]
        for (d, o) in expected {
            assertClose(try offsets(NativeClipMoves(in: NativeEdgeMove(kind: .slide, frames: 10, direction: d)), 0, engine), o, "slide \(d)")
        }
    }

    /// (kind, amount, offsets at phase 1); phase 0 is the kind's rest, except Sway, which swings from -a to +a.
    static let loopTable: [(NativeLoopMoveKind, Double, NativeMoveOffsets, NativeMoveOffsets)] = [
        (.float, 10, .identity, NativeMoveOffsets(dy: -10)),
        (.pulse, 10, .identity, NativeMoveOffsets(scale: 1.1)),
        (.sway, 4, NativeMoveOffsets(rotation: -4), NativeMoveOffsets(rotation: 4)),
        (.drift, 10, .identity, NativeMoveOffsets(dx: 20, scale: 1.1)),
    ]

    func testA2EveryLoopKindAtItsFirstMiddleAndLastFrameMatchesItsFormula() throws {
        let engine = try KeyframeRuntime()
        for (kind, amount, rest, peak) in Self.loopTable {
            let moves = NativeClipMoves(loop: NativeLoopMove(kind: kind, periodFrames: 20, amount: amount, ease: .linear))
            assertClose(try offsets(moves, 0, engine), rest, "\(kind) first frame")
            assertClose(try offsets(moves, 10, engine), peak, "\(kind) middle: the peak at half a period")
            assertClose(try offsets(moves, 20, engine), rest, "\(kind) one period on: back at rest")
            assertClose(try offsets(moves, 40, engine), rest, "\(kind) last frame (two periods)")
            let mid = kind.offsets(phase: 0.5, amount: amount, canvas: canvas)
            assertClose(try offsets(moves, 5, engine), mid, "\(kind) quarter period")
            assertClose(try offsets(moves, 15, engine), mid, "\(kind) three quarters, on the way back")
        }
    }

    func testDefaultEasesAreTheKeyframeEnginesEaseOutInAndInOut() throws {
        let engine = try KeyframeRuntime()
        let move = NativeEdgeMove(kind: .rise, frames: 10)
        let eased = try nativeMoveEasedProgress(NativeMoveEase.easeOut, frame: 5, span: 10, engine: engine)
        XCTAssertGreaterThan(eased, 0.5, "ease-out is past halfway at the middle")
        assertClose(try offsets(NativeClipMoves(in: move), 5, engine), move.offsets(edge: .in, weight: 1 - eased, canvas: canvas),
                    "In eases out by default")
        let easedIn = try nativeMoveEasedProgress(NativeMoveEase.easeIn, frame: 5, span: 10, engine: engine)
        XCTAssertLessThan(easedIn, 0.5)
        assertClose(try offsets(NativeClipMoves(out: move), 35, engine), move.offsets(edge: .out, weight: easedIn, canvas: canvas),
                    "Out eases in by default")
        XCTAssertEqual(try nativeMoveEasedProgress(NativeMoveEase.easeInOut, frame: 5, span: 10, engine: engine), 0.5, accuracy: 1e-6)
    }

    func testInOutAndLoopCombine() throws {
        let engine = try KeyframeRuntime()
        let moves = NativeClipMoves(in: NativeEdgeMove(kind: .grow, frames: 10, ease: .linear),
                                    out: NativeEdgeMove(kind: .slide, frames: 10, direction: .down, ease: .linear),
                                    loop: NativeLoopMove(kind: .pulse, periodFrames: 20, amount: 10, ease: .linear))
        let o = try offsets(moves, 5, engine)
        XCTAssertEqual(o.scale, (1 - 0.4 * 0.5) * 1.05, accuracy: 1e-9, "grow and pulse multiply")
        XCTAssertEqual(o.opacity, 0.5, accuracy: 1e-9)
        XCTAssertEqual(try offsets(moves, 40, engine).dy, 100, accuracy: 1e-9)
    }

    /// Budget (issue #238, estimated < 5 µs per layer per frame): measured here, reported, not asserted (shared CI machines).
    func testEvaluationCost() throws {
        let engine = try KeyframeRuntime()
        let c = clip(NativeClipMoves(in: NativeEdgeMove(kind: .slide, frames: 10), out: NativeEdgeMove(kind: .spin, frames: 10),
                                     loop: NativeLoopMove(kind: .float, periodFrames: 20)))
        let start = Date()
        for f in 0..<4_100 { _ = try nativeClipMoveOffsets(c, clipFrame: f % 41, canvas: canvas, engine: engine) }
        print("moves evaluation: \(Date().timeIntervalSince(start) / 4_100 * 1e6) µs per layer per frame")
    }
}
