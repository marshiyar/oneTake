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
import MpvfxCanvas
import MpvfxTimeline
import MpvfxShared

/// Maps document transform parameters <-> stage rects. transform.position is a px offset of the element
/// from its laid-out box (a plain translation), layout.width/height size the box, transform.rotation rotates it.
public enum StageGeometry {
    public static func baseRect(kind: TimelineClipKind, canvas: CanvasSize) -> CanvasRect {
        // Without the clip (no layout origin or natural size known) video and image clips fill the canvas box.
        kind == .element
            ? CanvasRect(x: canvas.width * 0.35, y: canvas.height * 0.35, width: canvas.width * 0.3, height: canvas.height * 0.3)
            : CanvasRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
    }

    /// The base a clip's transform.position offsets: media clips sit at layout.left/top (their natural default box when
    /// untouched: fitTimelineAssetGeometry), so the stage frame is the box preview and export draw.
    public static func baseRect(editor: TimelineEditor, clipId: String, kind: TimelineClipKind, time: Double) -> CanvasRect {
        let canvas = CanvasSize(editor.document.canvas.width, editor.document.canvas.height)
        guard kind == .video || kind == .image else { return baseRect(kind: kind, canvas: canvas) }
        let o = editor.layoutOrigin(clipId: clipId, time: time)
        return CanvasRect(x: o.x, y: o.y, width: canvas.width, height: canvas.height)
    }

    /// The clip's stage rect at `time` (composition px, before scale and rotation).
    public static func rect(editor: TimelineEditor, clipId: String, kind: TimelineClipKind, time: Double) -> CanvasRect {
        rect(base: baseRect(editor: editor, clipId: clipId, kind: kind, time: time), editor.transform(clipId: clipId, time: time))
    }

    public static func rect(base: CanvasRect, _ t: ClipTransform) -> CanvasRect {
        CanvasRect(x: base.x + (t.x ?? 0), y: base.y + (t.y ?? 0), width: t.width ?? base.width, height: t.height ?? base.height)
    }

    /// transform.scale when it is uniform (a number, or a vec2 with equal axes) and not 1, so the stage chrome sits
    /// on the scaled picture (PreviewComposition scales the box about its centre); nil otherwise.
    public static func uniformScale(editor: TimelineEditor, clipId: String, time: Double) -> Double? {
        for axis in ["transform.scaleX", "transform.scaleY"] where editor.parameterValue(clipId: clipId, parameterId: axis, time: time) != nil {
            return nil   // per-axis scale: no uniform box
        }
        let k: Double
        switch editor.parameterValue(clipId: clipId, parameterId: "transform.scale", time: time) {
        case .number(let v)?: k = v
        case .vec2(let v)? where v.x == v.y: k = v.x
        default: return nil
        }
        return k == 1 || !k.isFinite ? nil : k
    }

    /// Only fields that changed between `start` and `end` are written.
    public static func transform(base: CanvasRect, start: StageElement, end: StageElement) -> ClipTransform {
        var t = ClipTransform()
        if end.rect.x != start.rect.x || end.rect.y != start.rect.y { t.x = end.rect.x - base.x; t.y = end.rect.y - base.y }
        if end.rect.width != start.rect.width { t.width = end.rect.width }
        if end.rect.height != start.rect.height { t.height = end.rect.height }
        if end.rotation != start.rotation { t.rotation = end.rotation }
        return t
    }
}
