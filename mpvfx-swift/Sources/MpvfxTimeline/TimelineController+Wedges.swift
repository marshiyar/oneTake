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
// Dragging a move wedge (issue #274): a press on the tick of an In or Out wedge grabs it, moving sets the length to the
// whole frames between the pointer and that end of the clip (at least one frame, and short enough for the other move to
// fit), and letting go commits it as one undo step. Nothing is written while it is dragged.
import Foundation
import MpvfxShared

extension TimelineController {
    func wedgePointerDown(x: Double, y: Double) -> Bool {
        guard editor != nil, x >= TimelineLayout.contentOrigin else { return false }
        for (row, track) in view.tracks.enumerated() where !track.locked {
            for clip in track.clips {
                for edge in [NativeMoveEdge.in, .out] {
                    guard let grab = view.wedgeHandle(track: row, clip, edge), grab.contains(x: x, y: y) else { continue }
                    let frames = Int((view.wedgeSeconds(clip, edge) * playback.fps).rounded())
                    view.wedgeDrag = TimelineWedgeDrag(clipId: clip.id, edge: edge, frames: frames, seconds: Double(frames) / playback.fps)
                    view.selection = [clip.id]
                    return true
                }
            }
        }
        return false
    }

    func wedgeMove(x: Double) {
        guard var drag = view.wedgeDrag, let (_, clip) = clip(drag.clipId) else { return }
        let fps = max(playback.fps, 1)
        let time = view.time(forX: x)
        let seconds = drag.edge == .in ? time - clip.start : clip.end - time
        let total = Int((clip.duration * fps).rounded())
        let other = Int(((drag.edge == .in ? clip.moveOutSeconds : clip.moveInSeconds) * fps).rounded())
        drag.frames = max(1, min(max(1, total - other), Int((seconds * fps).rounded())))
        drag.seconds = Double(drag.frames) / fps
        view.wedgeDrag = drag
        needsDisplay?()
    }

    func wedgeUp() {
        guard let drag = view.wedgeDrag else { return }
        view.wedgeDrag = nil
        defer { needsDisplay?() }
        guard let editor, var move = editor.clipMoves(clipId: drag.clipId)?.edgeMove(drag.edge), move.frames != drag.frames else { return }
        move.frames = drag.frames
        editor.setEdgeMove(clipIds: [drag.clipId], drag.edge, move)
    }
}
