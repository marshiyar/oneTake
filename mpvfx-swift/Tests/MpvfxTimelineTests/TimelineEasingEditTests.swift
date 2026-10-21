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
@testable import MpvfxTimeline
import MpvfxShared
import OneTakeKeyframes

/// The document edits behind the Easing panel and F9: per-key outgoing changes, easy ease on either side of a key and
/// the project's custom presets, each one undo step that undo fully restores.
final class TimelineEasingEditTests: XCTestCase {
    let pid = TimelineEditor.positionId

    /// Demo document: clip:a keyed (position) at clip frames 0, 60 and 120, every segment linear.
    func make() throws -> TimelineEditor {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON, engine: KeyframeRuntime())
        for t in [0.0, 2, 4] { XCTAssertTrue(e.togglePositionKeyframe(clipId: "clip:a", time: t)) }
        return e
    }
    func ref(_ f: Double) -> TimelineKeyframeRef { TimelineKeyframeRef(clipId: "clip:a", parameterId: pid, frame: f) }
    func outs(_ e: TimelineEditor) -> [NativeInterpolation?] { [0, 60, 120].map { e.outgoing(ref($0)) } }

    func testSetOutgoingPerKeyIsOneUndoStep() throws {
        let e = try make()
        let before = e.document, undo = e.undoStack.count
        XCTAssertTrue(e.setOutgoing([(ref(0), .hold), (ref(60), .cubicBezier(.init(x1: 0.1, y1: 0, x2: 0.9, y2: 1)))]))
        XCTAssertEqual(outs(e), [.hold, .cubicBezier(.init(x1: 0.1, y1: 0, x2: 0.9, y2: 1)), .linear])
        XCTAssertEqual(e.undoStack.count, undo + 1)
        e.undo()
        XCTAssertEqual(e.document, before, "undo restores every key")
        XCTAssertFalse(e.setOutgoing([(ref(0), .linear)]), "no change, no undo step")
        XCTAssertFalse(e.setOutgoing([(ref(7), .hold)]), "no key at that frame")
        XCTAssertEqual(e.undoStack.count, undo)
    }

    func testPreviousAndNextKeyframe() throws {
        let e = try make()
        XCTAssertNil(e.previousKeyframe(ref(0)))
        XCTAssertEqual(e.previousKeyframe(ref(120)), ref(60))
        XCTAssertEqual(e.nextKeyframe(ref(60)), ref(120))
        XCTAssertNil(e.nextKeyframe(ref(120)))
    }

    func testEasyEaseBothSidesOfTheMiddleKey() throws {
        let e = try make()
        let undo = e.undoStack.count
        XCTAssertTrue(e.easyEase([ref(60)], out: true, in: true))
        guard case .cubicBezier(let before)? = e.outgoing(ref(0)), case .cubicBezier(let after)? = e.outgoing(ref(60)) else {
            return XCTFail("both segments around the key are curves")
        }
        XCTAssertEqual(before.x2, 1 - KeyframeEase.easyEaseInfluence, accuracy: 1e-12); XCTAssertEqual(before.y2, 1)
        XCTAssertEqual(before.y1, before.x1, accuracy: 1e-12, "the first key's own side stays linear")
        XCTAssertEqual(after.x1, KeyframeEase.easyEaseInfluence, accuracy: 1e-12); XCTAssertEqual(after.y1, 0)
        XCTAssertEqual(e.outgoing(ref(120)), .linear, "the last key's outgoing (no segment) is untouched")
        XCTAssertEqual(e.undoStack.count, undo + 1)
    }

    func testEasyEaseInAndOutOnTheEnds() throws {
        let e = try make()
        XCTAssertFalse(e.easyEase([ref(0)], out: false, in: true), "the first key has no incoming segment")
        XCTAssertFalse(e.easyEase([ref(120)], out: true, in: false), "the last key has no outgoing segment")
        XCTAssertTrue(e.easyEase([ref(0), ref(60), ref(120)], out: true, in: true))
        let p = KeyframeEase.easyEase(.linear, out: true, in: true)
        XCTAssertEqual(outs(e), [p, p, .linear], "a selected neighbour's two sides meet on one segment")
    }

    func testEasyEaseKeepsAHold() throws {
        let e = try make()
        XCTAssertTrue(e.setOutgoing([(ref(0), .hold)]))
        XCTAssertTrue(e.easyEase([ref(0), ref(60)], out: true, in: true))
        XCTAssertEqual(e.outgoing(ref(0)), .hold)
    }

    func testSaveAndDeleteEasingPresets() throws {
        let e = try make()
        let curve = NativeInterpolation.cubicBezier(.init(x1: 0.2, y1: 0, x2: 0, y2: 1))
        let undo = e.undoStack.count
        let id = try XCTUnwrap(e.saveEasingPreset(name: "  Snappy ", outgoing: curve))
        XCTAssertEqual(e.easingPresets, [NativeEasingPreset(id: id, name: "Snappy", outgoing: curve)])
        XCTAssertEqual(e.undoStack.count, undo + 1)
        let second = try XCTUnwrap(e.saveEasingPreset(name: "Snappy", outgoing: .hold))
        XCTAssertNotEqual(second, id, "every preset gets its own id")
        XCTAssertNil(e.saveEasingPreset(name: "   ", outgoing: curve), "a blank name is refused")
        XCTAssertNil(e.saveEasingPreset(name: "x", outgoing: .cubicBezier(.init(x1: 3, y1: 0, x2: 1, y2: 1))), "the engine's x range holds")
        XCTAssertTrue(e.deleteEasingPreset(id: id))
        XCTAssertEqual(e.easingPresets.map(\.id), [second])
        XCTAssertFalse(e.deleteEasingPreset(id: "missing"))
        e.undo(); e.undo(); e.undo()
        XCTAssertEqual(e.easingPresets, [])
        XCTAssertNil(e.document.easingPresets, "undo leaves no empty key behind")
    }

    func testPresetNamesAreCutToTheLimit() throws {
        let e = try make()
        _ = try XCTUnwrap(e.saveEasingPreset(name: String(repeating: "n", count: 200), outgoing: .linear))
        XCTAssertEqual(e.easingPresets.first?.name.count, NATIVE_EASING_PRESET_NAME_LIMIT)
    }
}
