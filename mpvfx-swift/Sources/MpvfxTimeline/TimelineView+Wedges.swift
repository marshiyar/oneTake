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
// The In and Out wedges (issue #274): a triangle at each end of a clip that has that move, as long as the move, in the
// accent, with a tick on its inner edge. Dragging the tick sets the length a frame at a time; a badge reads it out, and
// letting go commits one undo step (TimelineController+Wedges.swift).
import Foundation
import MpvfxCanvas
import MpvfxShared
import MpvfxTheme

/// A wedge being dragged: its clip and end, and the length it would set.
public struct TimelineWedgeDrag: Equatable, Sendable {
    public var clipId: String
    public var edge: NativeMoveEdge
    public var frames: Int
    public var seconds: Double
}

extension TimelineView {
    static let wedgeHeight = 14.0, wedgeGrab = 6.0

    /// The move's length in seconds as drawn: the drag's while it is being dragged.
    func wedgeSeconds(_ clip: TimelineClipModel, _ edge: NativeMoveEdge) -> Double {
        if let drag = wedgeDrag, drag.clipId == clip.id, drag.edge == edge { return drag.seconds }
        return edge == .in ? clip.moveInSeconds : clip.moveOutSeconds
    }

    /// The tick on the wedge's inner edge, where a press grabs it; nil when the clip has no such move.
    func wedgeHandle(track i: Int, _ clip: TimelineClipModel, _ edge: NativeMoveEdge) -> CanvasRect? {
        let seconds = wedgeSeconds(clip, edge)
        guard seconds > 0 else { return nil }
        let r = clipRect(track: i, clip, preview: false)
        let w = min(seconds * pixelsPerSecond, r.width)
        let x = edge == .in ? r.x + w : r.maxX - w
        return CanvasRect(x: x - Self.wedgeGrab, y: r.y, width: 2 * Self.wedgeGrab, height: min(Self.wedgeHeight, r.height / 2))
    }

    func drawMoveWedges(_ c: CanvasContext, clip: TimelineClipModel, _ r: CanvasRect) {
        for edge in [NativeMoveEdge.in, .out] {
            let seconds = wedgeSeconds(clip, edge)
            guard seconds > 0 else { continue }
            let dragging = wedgeDrag?.clipId == clip.id && wedgeDrag?.edge == edge
            let w = min(seconds * pixelsPerSecond, r.width), h = min(Self.wedgeHeight, r.height / 2)
            let edgeX = edge == .in ? r.x : r.maxX, innerX = edge == .in ? r.x + w : r.maxX - w
            var p = CanvasPath()
            p.move(to: CanvasPoint(edgeX, r.y)); p.line(to: CanvasPoint(innerX, r.y)); p.line(to: CanvasPoint(edgeX, r.y + h)); p.close()
            c.fill(p, theme.accent.withAlpha(dragging ? 0.85 : 0.55))
            c.fillRect(CanvasRect(x: innerX - 1, y: r.y, width: 2, height: h), theme.accent)
        }
    }

    /// "In 15 f · 0.50 s" over the clip being dragged.
    func drawWedgeBadge(_ c: CanvasContext) {
        guard let drag = wedgeDrag, let row = tracks.firstIndex(where: { $0.clips.contains { $0.id == drag.clipId } }),
              let clip = tracks[row].clips.first(where: { $0.id == drag.clipId }) else { return }
        let text = "\(drag.edge == .in ? "In" : "Out") \(drag.frames) f · " + String(format: "%.2f s", drag.seconds)
        drawSlipBadge(c, text, in: clipRect(track: row, clip))
    }
}
