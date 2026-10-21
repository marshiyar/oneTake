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
import OneTakeKeyframes
@testable import MpvfxTimeline
@testable import MpvfxPanels

/// The Easing panel's model: which keys it edits (following the clip, property and timeline key selection), applying
/// a curve to every target key in one undo step, copy / paste, influence and velocity per key, and the graph samples.
final class KeyframeEasingModelTests: XCTestCase {
    let pos = TimelineEditor.positionId, rot = TimelineEditor.rotationId

    /// clip:a: position keyed at clip frames 0, 60, 120 (demo values), rotation 0° at 0 and 90° at 30 (30 fps).
    func make() throws -> TimelineEditor {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON, engine: KeyframeRuntime())
        for t in [0.0, 2, 4] { XCTAssertTrue(e.togglePositionKeyframe(clipId: "clip:a", time: t)) }
        for (f, v) in [(0.0, 0.0), (30, 90)] { XCTAssertTrue(upsert(e, rot, frame: f, .number(v))) }
        return e
    }
    func upsert(_ e: TimelineEditor, _ pid: String, frame: Double, _ v: NativeParameterValue) -> Bool {
        guard let a = e.parameterAddress(clipId: "clip:a", pid) else { return false }
        return e.applyProperty(.atomic(.keyframe(.upsert(address: a, valueType: .number, frame: frame, value: v, baselineValue: v))))
    }
    func ref(_ pid: String, _ f: Double) -> TimelineKeyframeRef { TimelineKeyframeRef(clipId: "clip:a", parameterId: pid, frame: f) }
    func target(_ e: TimelineEditor, _ sel: Set<TimelineKeyframeRef> = [], time: Double = 0, chosen: String? = nil) throws -> KeyframeEasingTarget {
        try XCTUnwrap(KeyframeEasingTarget.resolve(e, clipId: "clip:a", selected: sel, time: time, chosen: chosen))
    }

    func testTargetFollowsTheSelectedKeys() throws {
        let e = try make()
        let t = try target(e, [ref(pos, 60), ref(pos, 0), ref(rot, 30), TimelineKeyframeRef(clipId: "other", parameterId: pos, frame: 0)])
        XCTAssertEqual(t.parameterId, pos, "the earliest selected key's property")
        XCTAssertEqual(t.refs, [ref(pos, 0), ref(pos, 60)], "that property's selected keys on this clip, in time order")
        XCTAssertTrue(t.fromSelection)
        XCTAssertEqual(t.properties, [pos, rot], "the clip's animated easable properties")
    }

    func testTargetFallsBackToTheChosenPropertyAtThePlayhead() throws {
        let e = try make()
        let t = try target(e, time: 1.5, chosen: rot)
        XCTAssertEqual(t.parameterId, rot); XCTAssertEqual(t.refs, [ref(rot, 30)]); XCTAssertFalse(t.fromSelection)
        let first = try target(e, time: 1.5, chosen: "visual.opacity")
        XCTAssertEqual(first.parameterId, pos, "a chosen property that is not animated falls back to the first one")
        XCTAssertEqual(first.refs, [ref(pos, 0)])
        XCTAssertNil(KeyframeEasingTarget.resolve(e, clipId: "missing", selected: [], time: 0, chosen: nil))
        XCTAssertNil(KeyframeEasingTarget.resolve(e, clipId: nil, selected: [], time: 0, chosen: nil))
    }

    func testApplyEditsEveryTargetKeyInOneUndoStep() throws {
        let e = try make()
        let t = try target(e, [ref(pos, 0), ref(pos, 60)])
        let before = e.document, undo = e.undoStack.count
        XCTAssertTrue(KeyframeEasing.apply(e, t, .hold))
        XCTAssertEqual([e.outgoing(ref(pos, 0)), e.outgoing(ref(pos, 60))], [.hold, .hold])
        XCTAssertEqual(e.undoStack.count, undo + 1); XCTAssertEqual(e.undoLabel, "Edit keyframe easing")
        e.undo()
        XCTAssertEqual(e.document, before)
    }

    func testCopyAndPasteAnEase() throws {
        let e = try make(), state = KeyframeEasingState()
        let curve = NativeInterpolation.cubicBezier(.init(x1: 0.2, y1: 0.4, x2: 0.6, y2: 1))
        XCTAssertFalse(state.paste(e, try target(e, [ref(rot, 0)])), "nothing copied yet")
        XCTAssertTrue(e.setOutgoing([(ref(pos, 60), curve)]))
        XCTAssertTrue(state.copy(e, try target(e, [ref(pos, 60)])))
        XCTAssertEqual(state.clipboard, curve)
        let undo = e.undoStack.count
        XCTAssertTrue(state.paste(e, try target(e, [ref(rot, 0)])))
        XCTAssertEqual(e.outgoing(ref(rot, 0)), curve, "pasted onto another property's key")
        XCTAssertEqual(e.undoStack.count, undo + 1)
    }

    func testEditingOneSideKeepsTheOtherSideExactly() throws {
        let e = try make()
        XCTAssertTrue(e.setOutgoing([(ref(rot, 0), .cubicBezier(.init(x1: 0.42, y1: 0, x2: 1, y2: 2.5)))]))
        XCTAssertTrue(KeyframeEasing.setSide(e, try target(e, [ref(rot, 0)]), .out, influence: 0.25, velocity: nil))
        guard case .cubicBezier(let p)? = e.outgoing(ref(rot, 0)) else { return XCTFail("not a curve") }
        XCTAssertEqual(p.x1, 0.25); XCTAssertEqual(p.y1, 0)
        XCTAssertEqual(p.x2, 1, "x2 is not pulled to the 0.1 % reach"); XCTAssertEqual(p.y2, 2.5, "y2 is not clamped")
    }

    func testInfluenceIsSetOnEveryKeyAndVelocityPerSegment() throws {
        let e = try make()
        // Rotation 0 → 90° over 30 frames at 30 fps: the linear speed is 90°/s.
        let seg = try XCTUnwrap(KeyframeEasing.segment(e, ref(rot, 0)))
        XCTAssertEqual(seg.valueChange, 90); XCTAssertEqual(seg.seconds, 1)
        XCTAssertNil(KeyframeEasing.segment(e, ref(rot, 30)), "the last key has no segment")
        let t = try target(e, [ref(rot, 0)])
        XCTAssertTrue(KeyframeEasing.setSide(e, t, .out, influence: 0.5, velocity: 45))
        guard case .cubicBezier(let p)? = e.outgoing(ref(rot, 0)) else { return XCTFail("not a curve") }
        XCTAssertEqual(p.x1, 0.5, accuracy: 1e-12); XCTAssertEqual(p.y1, 0.25, accuracy: 1e-12, "45°/s is half the linear speed")
        XCTAssertEqual(p.x2, 2.0 / 3, accuracy: 1e-12); XCTAssertEqual(p.y2, 2.0 / 3, accuracy: 1e-12, "the in side kept linear")
        let shown = try XCTUnwrap(KeyframeEasing.sides(e, ref(rot, 0)))
        XCTAssertEqual(shown.outVelocity, 45, accuracy: 1e-9); XCTAssertEqual(shown.outInfluence, 0.5, accuracy: 1e-12)
        XCTAssertEqual(shown.inVelocity, 90, accuracy: 1e-9)
    }

    func testGraphSamplesAreTheEngineValues() throws {
        let e = try make()
        let g = try XCTUnwrap(KeyframeEasingGraph.samples(e, try target(e, [ref(rot, 0)])))
        XCTAssertEqual(g.frames.first, 0); XCTAssertEqual(g.frames, (0...30).map(Double.init)); XCTAssertEqual(g.values.count, 31)
        XCTAssertEqual(g.values[15], [45], "linear halfway"); XCTAssertEqual(g.values[30], [90])
        XCTAssertEqual(g.speeds[15], 90, accuracy: 1e-9, "degrees per second")
        XCTAssertTrue(KeyframeEasing.apply(e, try target(e, [ref(rot, 0)]), .cubicBezier(.init(x1: 0.42, y1: 0, x2: 0.58, y2: 1))))
        let eased = try XCTUnwrap(KeyframeEasingGraph.samples(e, try target(e, [ref(rot, 0)])))
        XCTAssertEqual(eased.values[15][0], 45, accuracy: 1e-9, "a symmetric ease passes the middle at the middle")
        XCTAssertLessThan(eased.speeds[1], 20, "slow start"); XCTAssertGreaterThan(eased.speeds[15], 90, "fast middle")
    }

    func testGraphSamplesStayBoundedOnLongRanges() throws {
        let e = try make()
        XCTAssertTrue(upsert(e, rot, frame: 179, .number(0)))
        let g = try XCTUnwrap(KeyframeEasingGraph.samples(e, try target(e, [ref(rot, 0)]), maxSamples: 40))
        XCTAssertLessThanOrEqual(g.values.count, 41); XCTAssertEqual(g.values.count, g.speeds.count)
        XCTAssertEqual(g.frames.count, g.values.count)
        XCTAssertEqual(g.frames.last, 179, "the last sample is the last key, not past it")
        let gap = try XCTUnwrap(g.frames.last) - g.frames[g.frames.count - 2]
        XCTAssertLessThan(gap, g.frames[1] - g.frames[0], "the shortened final gap is kept")
        // Rotation 90° → 0° over frames 30…179 is linear: the speed at the end key is that segment's speed.
        XCTAssertEqual(try XCTUnwrap(g.speeds.last), 90 / (149.0 / 30), accuracy: 1e-6)
    }
}
