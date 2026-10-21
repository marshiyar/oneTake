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
import MpvfxCanvas
import MpvfxShared
import OneTakeKeyframes

/// ⌘K keys every keyframeable property of the selected clips at the playhead, ⇧⌘K only the animated ones, each as
/// one undo step; and every keyed property gets its own lane of its own kind (no 3D key in the Rotation lane).
final class TimelineKeyAllTests: XCTestCase {
    static let cmdK = EditorKey(.char("k"), meta: true), shiftCmdK = EditorKey(.char("K"), shift: true, meta: true)
    static let visualIds = [TimelineEditor.positionId, TimelineEditor.widthId, TimelineEditor.heightId, TimelineEditor.rotationId,
                            TimelineEditor.scaleId, TimelineEditor.opacityId] + NativeTransform3D.parameterIds

    /// Demo document (30 fps): clip:a video 0…180, clip:logo image 15…105, clip:music audio 0…330. Playhead at 2 s.
    func make(select ids: Set<String> = ["clip:a"], at time: Double = 2) throws -> (TimelineController, TimelineEditor) {
        let e = try TimelineEditor(json: TimelineEditor.demoJSON, engine: KeyframeRuntime())
        let c = TimelineController(view: TimelineView(tracks: [], duration: 0), playback: PlaybackState(duration: 0), editor: e)
        c.viewport = CanvasSize(1266, 400)
        c.view.selection = ids
        c.playback.seek(time); c.syncFromPlayback()
        return (c, e)
    }

    func keys(_ e: TimelineEditor, _ clipId: String, _ pid: String) throws -> [NativeKeyframe] {
        try XCTUnwrap(e.clip(clipId)).clip.parameterTracks.first { $0.parameterId == pid }?.keyframes ?? []
    }

    func keyedIds(_ e: TimelineEditor, _ clipId: String, frame: Double) throws -> Set<String> {
        Set(try XCTUnwrap(e.clip(clipId)).clip.parameterTracks.filter { $0.keyframes.contains { $0.frame == frame } }.map(\.parameterId))
    }

    func setStatic(_ e: TimelineEditor, _ clipId: String, _ pid: String, _ v: NativeParameterValue) throws {
        let a = try XCTUnwrap(e.parameterAddress(clipId: clipId, pid))
        XCTAssertTrue(e.applyProperty(.atomic(.setStatic(address: a, value: v))))
    }

    /// ⌘K on clip:a at frame 60 writes one key on `pid` holding `expected`.
    func assertCmdKKeys(_ pid: String, expected: NativeParameterValue, prepare: (TimelineEditor) throws -> Void = { _ in },
                        file: StaticString = #filePath, line: UInt = #line) throws {
        let (c, e) = try make()
        try prepare(e)
        XCTAssertTrue(try keys(e, "clip:a", pid).isEmpty, "no key before", file: file, line: line)
        XCTAssertTrue(c.keyDown(Self.cmdK), file: file, line: line)
        let k = try keys(e, "clip:a", pid)
        XCTAssertEqual(k.map(\.frame), [60], "one key at the playhead frame", file: file, line: line)
        XCTAssertEqual(k.first?.value, expected, file: file, line: line)
    }

    // MARK: One test per keyframeable property

    func testCmdKKeysPosition() throws {
        try assertCmdKKeys(TimelineEditor.positionId, expected: .vec2(Vec2Value(x: 120, y: -40))) { e in
            XCTAssertTrue(e.applyTransform(clipId: "clip:a", time: 2, ClipTransform(x: 120, y: -40)))
        }
    }

    func testCmdKKeysSizeWidthAndHeight() throws {
        try assertCmdKKeys(TimelineEditor.widthId, expected: .number(1920))
        try assertCmdKKeys(TimelineEditor.heightId, expected: .number(1080))
    }

    func testCmdKKeysRotationWhichIsAlsoThe3DRoll() throws {
        try assertCmdKKeys(TimelineEditor.rotationId, expected: .number(30)) { e in
            XCTAssertTrue(e.applyTransform(clipId: "clip:a", time: 2, ClipTransform(rotation: 30)))
        }
    }

    func testCmdKKeysScale() throws {
        try assertCmdKKeys(TimelineEditor.scaleId, expected: .vec2(Vec2Value(x: 1, y: 1)))
        try assertCmdKKeys(TimelineEditor.scaleId, expected: .vec2(Vec2Value(x: 1.5, y: 1.5))) { e in
            try self.setStatic(e, "clip:a", TimelineEditor.scaleId, .vec2(Vec2Value(x: 1.5, y: 1.5)))
        }
    }

    func testCmdKKeysOpacity() throws {
        try assertCmdKKeys(TimelineEditor.opacityId, expected: .number(1))
        try assertCmdKKeys(TimelineEditor.opacityId, expected: .number(0.25)) { e in try self.setStatic(e, "clip:a", TimelineEditor.opacityId, .number(0.25)) }
    }

    func testCmdKKeysDepth() throws {
        try assertCmdKKeys(NativeTransform3D.zId, expected: .number(0))
    }

    func testCmdKKeysTiltX() throws {
        try assertCmdKKeys(NativeTransform3D.rotationXId, expected: .number(12)) { e in
            try self.setStatic(e, "clip:a", NativeTransform3D.rotationXId, .number(12))
        }
    }

    func testCmdKKeysTiltY() throws {
        try assertCmdKKeys(NativeTransform3D.rotationYId, expected: .number(-8)) { e in
            try self.setStatic(e, "clip:a", NativeTransform3D.rotationYId, .number(-8))
        }
    }

    func testCmdKKeysPerspective() throws {
        try assertCmdKKeys(NativeTransform3D.perspectiveId, expected: .number(1080)) { e in
            try self.setStatic(e, "clip:a", NativeTransform3D.perspectiveId, .number(1080))
        }
    }

    func testCmdKKeysVolumeOnAClipWithSound() throws {
        try assertCmdKKeys(TimelineEditor.volumeId, expected: .number(0.5)) { e in XCTAssertTrue(e.setClipVolume(clipId: "clip:a", 0.5)) }
    }

    // MARK: The command

    func testCmdKKeysEveryPropertyOfTheSelectedClipsAsOneUndoStep() throws {
        let (c, e) = try make(select: ["clip:a", "clip:music"])
        let before = e.document, undo = e.undoStack.count
        XCTAssertTrue(c.keyDown(Self.cmdK))
        XCTAssertEqual(try keyedIds(e, "clip:a", frame: 60), Set(Self.visualIds + [TimelineEditor.volumeId]))
        XCTAssertEqual(try keyedIds(e, "clip:music", frame: 60), [TimelineEditor.volumeId], "an audio clip keys its volume only")
        XCTAssertEqual(e.undoStack.count, undo + 1, "both clips, every property: one undo step")
        XCTAssertEqual(e.undoLabel, "Add keyframes")
        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.document.sequence, before.sequence)
    }

    func testCmdKOnAnImageKeysTheVisualPropertiesAndNoVolume() throws {
        let (c, e) = try make(select: ["clip:logo"])
        XCTAssertTrue(c.keyDown(Self.cmdK))
        XCTAssertEqual(try keyedIds(e, "clip:logo", frame: 45), Set(Self.visualIds))
    }

    func testCmdKLeavesAKeyAlreadyAtThePlayheadAndAddsNothingTwice() throws {
        let (c, e) = try make()
        XCTAssertTrue(e.applyTransform(clipId: "clip:a", time: 2, ClipTransform(x: 5, y: 5)))
        XCTAssertTrue(e.togglePositionKeyframe(clipId: "clip:a", time: 2))
        XCTAssertTrue(e.applyTransform(clipId: "clip:a", time: 2, ClipTransform(x: 9, y: 9)))
        XCTAssertTrue(c.keyDown(Self.cmdK))
        XCTAssertEqual(try keys(e, "clip:a", TimelineEditor.positionId).map(\.value), [.vec2(Vec2Value(x: 9, y: 9))], "the existing key is kept")
        let undo = e.undoStack.count
        XCTAssertTrue(c.keyDown(Self.cmdK), "handled, so K does not reach playback")
        XCTAssertEqual(e.undoStack.count, undo, "everything is keyed already: no empty undo step")
    }

    func testShiftCmdKKeysOnlyTheAnimatedProperties() throws {
        let (c, e) = try make()
        XCTAssertTrue(e.togglePositionKeyframe(clipId: "clip:a", time: 0))
        XCTAssertTrue(c.keyDown(Self.shiftCmdK))
        XCTAssertEqual(try keyedIds(e, "clip:a", frame: 60), [TimelineEditor.positionId])
        XCTAssertEqual(e.undoLabel, "Key animated properties")
    }

    func testCmdKKeysTheScalarPositionTracksWhenTheyCarryTheAnimation() throws {
        let (c, e) = try make()
        for pid in [POSITION_X_PARAMETER_ID, POSITION_Y_PARAMETER_ID] {
            let a = try XCTUnwrap(e.parameterAddress(clipId: "clip:a", pid))
            XCTAssertTrue(e.applyProperty(.atomic(.keyframe(.upsert(address: a, valueType: .number, frame: 0, value: .number(10), baselineValue: .number(10))))))
        }
        XCTAssertTrue(c.keyDown(Self.cmdK))
        let keyed = try keyedIds(e, "clip:a", frame: 60)
        XCTAssertTrue(keyed.isSuperset(of: [POSITION_X_PARAMETER_ID, POSITION_Y_PARAMETER_ID]))
        XCTAssertFalse(keyed.contains(TimelineEditor.positionId), "no competing vec2 track beside the scalar ones")
    }

    func testCmdKSkipsLockedClipsAndNeedsASelection() throws {
        let (c, e) = try make(select: [])
        XCTAssertFalse(c.keyDown(Self.cmdK), "nothing selected: not handled")
        c.view.selection = ["clip:a"]
        XCTAssertTrue(e.setTrackLocked("track:v1", true))
        let undo = e.undoStack.count
        XCTAssertTrue(c.keyDown(Self.cmdK))
        XCTAssertEqual(e.undoStack.count, undo)
        XCTAssertTrue(try keyedIds(e, "clip:a", frame: 60).isEmpty)
    }

    // MARK: Lanes and kinds

    func testEveryKeyedPropertyGetsItsOwnLaneOfItsKind() throws {
        let (c, _) = try make()
        XCTAssertTrue(c.keyDown(Self.cmdK))
        let lanes = c.view.tracks[1].clips[0].lanes
        XCTAssertEqual(Set(lanes.map(\.label)), ["Position", "Size", "Rotation", "Scale", "Opacity", "Depth", "Tilt X", "Tilt Y", "Perspective", "Volume"])
        XCTAssertEqual(lanes.first { $0.label == "Tilt X" }?.kind, .threeD, "tilt is its own 3D lane, not folded into Rotation")
        XCTAssertEqual(lanes.first { $0.label == "Rotation" }?.keyframes, [2])
        XCTAssertEqual(lanes.first { $0.label == "Volume" }?.kind, .audio)
    }

    func testCatalogMapsEveryInspectorPropertyToAGroupAndKind() {
        let expected: [(String, String, String, TimelineKeyframeKind)] = [
            (TimelineEditor.positionId, "position", "Position", .transform), (POSITION_X_PARAMETER_ID, "position", "Position", .transform),
            (POSITION_Y_PARAMETER_ID, "position", "Position", .transform), (TimelineEditor.widthId, "size", "Size", .transform),
            (TimelineEditor.heightId, "size", "Size", .transform), (TimelineEditor.rotationId, "rotation", "Rotation", .transform),
            (TimelineEditor.scaleId, "scale", "Scale", .transform), ("transform.scaleX", "scale", "Scale", .transform),
            (TimelineEditor.opacityId, "opacity", "Opacity", .opacity), (NativeTransform3D.zId, "depth", "Depth", .threeD),
            (NativeTransform3D.rotationXId, "tiltX", "Tilt X", .threeD), (NativeTransform3D.rotationYId, "tiltY", "Tilt Y", .threeD),
            (NativeTransform3D.perspectiveId, "perspective", "Perspective", .threeD), (TimelineEditor.volumeId, "audio", "Volume", .audio),
            ("grade.adjust.exposure", "grade.adjust.exposure", "Exposure", .color), ("effect.blur.radius", "effect.blur.radius", "Radius", .effect),
            ("grade.intensity", "grade.intensity", "Grade Amount", .color), ("grade.wheels.shadows.hue", "grade.wheels.shadows.hue", "Shadows Hue", .color),
            ("grade.effects.chromaticAberration", "grade.effects.chromaticAberration", "Chromatic Aberration", .effect),
        ]
        for (pid, group, label, kind) in expected {
            XCTAssertEqual(TimelineKeyframeCatalog.property(pid), TimelineKeyframeProperty(group: group, label: label, kind: kind), pid)
            XCTAssertEqual(TimelineKeyframeCatalog.kind(ofGroup: group), kind, group)
        }
    }
}
