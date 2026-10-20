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
import Foundation
import MpvfxCanvas
import MpvfxShared
import OneTakeKeyframes
import MpvfxTimeline
import MpvfxPanels
@testable import MpvfxPlayer
@testable import MpvfxRuntime

/// Inspector keyframe controls: every property the renderer animates has the stopwatch and ‹ ◆ › on its row, the
/// stopwatch starts and stops animation as one undo step, keyed volume has its own easing editor, and the keyframe
/// menu's Edit Easing opens the group whose easing rows edit the keys.
extension InspectorRenderAuditTests {
    /// Row key → the parameter its keyframe controls animate (Position and Size are one control for both fields).
    static let keyframedRows: [(key: String, parameterId: String)] = [
        ("x", TimelineEditor.positionId), ("w", TimelineEditor.widthId), ("rotation", TimelineEditor.rotationId),
        ("scale", TimelineEditor.scaleId), ("opacity", TimelineEditor.opacityId), ("depth", NativeTransform3D.zId),
        ("tiltX", NativeTransform3D.rotationXId), ("tiltY", NativeTransform3D.rotationYId),
        ("perspective", NativeTransform3D.perspectiveId), ("volume", TimelineEditor.volumeId),
    ]

    func keyframeControl(_ key: String, file: StaticString = #filePath, line: UInt = #line) -> InspectorRow.Keyframe? {
        switch find(key, file: file, line: line) {
        case .number(let n)?: return n.keyframe
        case .slider(let s)?: return s.keyframe
        default: return nil
        }
    }
    var animated: Set<String> {
        Set(editor.clip("V")?.clip.parameterTracks.filter { !$0.keyframes.isEmpty }.map(\.parameterId) ?? [])
    }

    func testEveryAnimatableInspectorPropertyCanBeKeyframed() {
        inspector.transform3DOpen = true
        for row in Self.keyframedRows {
            guard let kf = keyframeControl(row.key) else { XCTFail("\(row.key) has no keyframe controls"); continue }
            XCTAssertEqual(kf.state, .none, row.key)
            kf.stopwatch()
        }
        let expected = Set(Self.keyframedRows.map(\.parameterId) + [TimelineEditor.heightId])
        XCTAssertEqual(animated, expected, "each stopwatch animates its property (Size: width and height)")
        for pid in expected { XCTAssertNotNil(exportAnimatableValueTypes(pid), "\(pid) is keyframed in the inspector but export refuses it") }
        XCTAssertFalse(exportRender().frame.isEmpty, "the fully keyed clip exports")
        for row in Self.keyframedRows { XCTAssertEqual(keyframeControl(row.key)?.state, .onKey, row.key) }
    }

    func testStopwatchStartsAndStopsAnimationAsOneUndoStep() {
        guard let start = keyframeControl("x") else { return XCTFail("position has no keyframe controls") }
        let undo = editor.undoStack.count
        start.stopwatch()
        XCTAssertEqual(editor.keyframeFrames(clipId: "V", TimelineEditor.positionId), [0], "a key at the playhead")
        XCTAssertEqual(editor.undoStack.count, undo + 1)
        select("V", time: 2); type("x", "100")
        XCTAssertEqual(editor.keyframeFrames(clipId: "V", TimelineEditor.positionId), [0, 20])
        // Stopped halfway: the keys go and the value there stays.
        select("V", time: 1)
        guard let stop = keyframeControl("x") else { return XCTFail("position has no keyframe controls") }
        XCTAssertEqual(stop.state, .animated)
        let keyed = editor.undoStack.count
        stop.stopwatch()
        XCTAssertFalse(editor.isAnimated(clipId: "V", TimelineEditor.positionId))
        XCTAssertEqual(editor.clip("V")?.clip.staticParameters?[TimelineEditor.positionId], .vec2(Vec2Value(x: 50, y: 0)))
        XCTAssertEqual(editor.undoStack.count, keyed + 1)
        XCTAssertEqual(previewFrame(at: 2.5).images.first?.rect.x ?? 0, 100, accuracy: 1, "the held x 50 canvas px everywhere")
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.keyframeFrames(clipId: "V", TimelineEditor.positionId), [0, 20], "undo brings the keys back")
    }

    func testSizeStopwatchAnimatesWidthAndHeightTogether() {
        guard let kf = keyframeControl("w") else { return XCTFail("size has no keyframe controls") }
        kf.stopwatch()
        XCTAssertEqual(animated, [TimelineEditor.widthId, TimelineEditor.heightId])
        XCTAssertEqual(editor.undoStack.count, 1)
        keyframeControl("w")?.stopwatch()
        XCTAssertEqual(animated, [])
        XCTAssertEqual(editor.undoStack.count, 2)
    }

    func testKeyedVolumeHasAnEasingEditor() {
        select("M")
        guard let kf = keyframeControl("volume") else { return XCTFail("volume has no keyframe controls") }
        kf.stopwatch()
        select("M", time: 2); slide("volume", AudioGainFader.position(gain: 0.5))
        XCTAssertEqual(editor.keyframeFrames(clipId: "M", TimelineEditor.volumeId), [0, 20])
        select("M", time: 1)
        guard case .segmented(let s)? = find("easing") else { return XCTFail("no easing row for keyed volume") }
        XCTAssertEqual(s.options.first { $0.active }?.key, "linear")
        pick("easing", "hold")
        XCTAssertEqual(editor.outgoing(TimelineKeyframeRef(clipId: "M", parameterId: TimelineEditor.volumeId, frame: 0)), .hold)
        XCTAssertEqual(editor.numberValue(clipId: "M", TimelineEditor.volumeId, time: 1) ?? 0, 1, accuracy: 1e-9, "hold keeps the first gain")
    }

    func testShowKeyframeEasingOpensTheGroupThatEditsTheKeys() {
        let volume = TimelineKeyframeRef(clipId: "M", parameterId: TimelineEditor.volumeId, frame: 0)
        XCTAssertTrue(inspector.showKeyframeEasing(clipId: "M", refs: [volume]))
        XCTAssertEqual(inspector.selection, ["M"]); XCTAssertEqual(inspector.openGroupId, "media")
        XCTAssertEqual(inspector.selectedKeyframes, [volume])
        let position = TimelineKeyframeRef(clipId: "V", parameterId: TimelineEditor.positionId, frame: 0)
        XCTAssertTrue(inspector.showKeyframeEasing(clipId: "V", refs: [position]))
        XCTAssertEqual(inspector.selection, ["V"]); XCTAssertEqual(inspector.openGroupId, "layout")
        // A parameter without an easing editor leaves the panel as it was.
        let zIndex = TimelineKeyframeRef(clipId: "M", parameterId: "layout.zIndex", frame: 0)
        XCTAssertFalse(inspector.showKeyframeEasing(clipId: "M", refs: [zIndex]))
        XCTAssertEqual(inspector.selection, ["V"]); XCTAssertEqual(inspector.selectedKeyframes, [position])
    }

    func testStopwatchIsDrawnOnTheRowAndClicks() {
        inspector.openGroupId = "layout"
        let c = AuditCanvas()
        inspector.draw(c, in: CanvasRect(x: 0, y: 0, width: 300, height: 1600))
        guard let watch = inspector.hits.rect(where: { $0 == .stopwatch("rotation") }),
              let diamond = inspector.hits.rect(where: { $0 == .keyframe("rotation") }) else { return XCTFail("rotation has no stopwatch") }
        XCTAssertEqual(watch.y + watch.height / 2, diamond.y + diamond.height / 2, accuracy: 0.5, "on the property's row")
        XCTAssertLessThan(watch.x + watch.width, diamond.x, "before the keyframe navigation")
        let p = CanvasPoint(watch.x + watch.width / 2, watch.y + watch.height / 2)
        _ = inspector.pointerDown(p); inspector.pointerUp(p)
        XCTAssertTrue(editor.isAnimated(clipId: "V", TimelineEditor.rotationId))
    }

    func upsert(_ pid: String, frame: Double, _ value: NativeParameterValue, clip id: String = "V") -> Bool {
        guard let track = editor.clip(id)?.track.id else { return false }
        let type: NativeValueType
        switch value { case .number: type = .number; case .vec2: type = .vec2; case .rgba: type = .rgba }
        let a = NativeProjectParameterAddress(sequenceId: editor.sequenceId, trackId: track, clipId: id, parameterId: pid)
        return editor.applyProperty(.atomic(.keyframe(.upsert(address: a, valueType: type, frame: frame, value: value, baselineValue: value))))
    }

    func testPositionControlsCoverScalarPositionTracks() {
        // Scalar x/y tracks (older and recorded projects), which preview and export read before the vec2 track.
        for (pid, a, b) in [(POSITION_X_PARAMETER_ID, 0.0, 100.0), (POSITION_Y_PARAMETER_ID, 0, 40)] {
            XCTAssertTrue(upsert(pid, frame: 0, .number(a))); XCTAssertTrue(upsert(pid, frame: 20, .number(b)))
        }
        select("V", time: 1)
        guard let kf = keyframeControl("x") else { return XCTFail("position has no keyframe controls") }
        XCTAssertEqual(kf.state, .animated, "scalar position keys read as animated")
        XCTAssertNotNil(kf.prev); XCTAssertNotNil(kf.next)
        kf.stopwatch()
        XCTAssertEqual(animated, [], "the stopwatch drops the scalar tracks too")
        XCTAssertEqual(previewFrame(at: 2.5).images.first?.rect.x ?? 0, 100, accuracy: 1, "the held x 50 canvas px")
        XCTAssertEqual(keyframeControl("x")?.state, InspectorRow.KeyframeState.none)
    }

    func testStoppingRotationDropsCropPivotMarkersOnItsKeys() {
        XCTAssertTrue(upsert(TimelineEditor.rotationId, frame: 0, .number(0))); XCTAssertTrue(upsert(TimelineEditor.rotationId, frame: 20, .number(90)))
        guard let keys = editor.clip("V")?.clip.parameterTracks.first(where: { $0.parameterId == TimelineEditor.rotationId })?.keyframes,
              keys.count == 2 else { return XCTFail("no rotation keys") }
        let json = #"{"startRotationKeyId":"\#(keys[0].id)","endRotationKeyId":"\#(keys[1].id)","offsetFraction":{"x":0.1,"y":0}}"#
        guard let marker = try? JSONDecoder().decode(NativeCropPivotSegment.self, from: Data(json.utf8)) else { return XCTFail("bad marker") }
        XCTAssertTrue(editor.editClip("V") { c in c.cropPivotSegments = [marker]; return true })
        XCTAssertEqual(editor.clip("V")?.clip.cropPivotSegments?.count, 1)
        select("V", time: 1)
        keyframeControl("rotation")?.stopwatch()
        XCTAssertFalse(editor.isAnimated(clipId: "V", TimelineEditor.rotationId))
        XCTAssertEqual(editor.clip("V")?.clip.cropPivotSegments ?? [], [], "no marker left on the removed keys")
    }

    func testShowKeyframeEasingScrollsAnOpenGroupToItsEasingRows() {
        XCTAssertTrue(upsert(TimelineEditor.rotationId, frame: 0, .number(0))); XCTAssertTrue(upsert(TimelineEditor.rotationId, frame: 20, .number(90)))
        inspector.openGroupId = "layout"
        let c = AuditCanvas(), box = CanvasRect(x: 0, y: 0, width: 300, height: 320)
        inspector.draw(c, in: box)
        XCTAssertEqual(inspector.bodyScroll, 0)
        let easing: (InspectorPanel.Hit) -> Bool = { if case .segment("easing", _) = $0 { return true }; return false }
        func easingVisible() -> Bool { inspector.hits.rect(where: easing).map { $0.y >= 0 && $0.maxY <= box.height } ?? false }
        XCTAssertFalse(easingVisible(), "the easing rows start below a short panel")
        XCTAssertTrue(inspector.showKeyframeEasing(clipId: "V", refs: [TimelineKeyframeRef(clipId: "V", parameterId: TimelineEditor.rotationId, frame: 0)]))
        inspector.draw(c, in: box); inspector.draw(c, in: box)
        XCTAssertGreaterThan(inspector.bodyScroll, 0)
        XCTAssertTrue(easingVisible(), "Edit Easing scrolls the already open group to its easing rows")
    }

    func testShowKeyframeEasingSkipsKeysWithoutAnEditor() {
        let zIndex = TimelineKeyframeRef(clipId: "V", parameterId: "layout.zIndex", frame: 0)
        let rotation = TimelineKeyframeRef(clipId: "V", parameterId: TimelineEditor.rotationId, frame: 10)
        XCTAssertTrue(inspector.showKeyframeEasing(clipId: "V", refs: [zIndex, rotation]))
        XCTAssertEqual(inspector.openGroupId, "layout")
    }
}
