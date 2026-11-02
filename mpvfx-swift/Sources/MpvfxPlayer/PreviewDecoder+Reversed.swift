// A reversed clip's decode lane: its timeline frames run through its source backwards, so each chunk of timeline frames
// is read forward from one stream start (the lowest source time) and stored from its last timeline frame down.
import Foundation
import MpvfxCanvas
import OneTakeMedia

extension PreviewDecodeLane {
    /// Timeline frames per reversed chunk (bounded further by the frame cache's capacity).
    static let reversedChunk = 24

    /// Decodes at most one frame toward the request for a reversed clip (`layer.reverseFrames` set). The window is the
    /// playhead's frame plus `ahead` after it (playing forward) or `behind` before it (shuttling backwards); a missing
    /// frame starts a chunk of up to `reversedChunk` frames (running past the window, so a sliding window does not
    /// start a one-frame chunk every frame) that is read forward through the source and stored from its
    /// highest timeline frame down. Returns false when nothing is missing.
    func stepReversedClip(want w: Int, ahead a: Int, behind b: Int, size boxSize: PreviewDecodeSize) -> Bool {
        let sz = mediaAspect.map { boxSize.containing(aspect: $0) } ?? boxSize
        let room = max(0, (frameCapacity(want: w, size: sz) - 1) / 2)
        let lo = max(layer.startFrame, w - min(b, room)), hi = min(layer.endFrame - 1, w + min(a, room))
        guard let missing = reversedMissing(want: w, low: lo, high: hi, backward: b > 0, size: sz) else { return false }
        let open = stream != nil && streamSize.map { $0.serves(sz) } == true && reverseNext >= reverseFloor
            && missing >= reverseFloor && missing <= reverseNext
        if !open {
            let chunk = max(1, min(Self.reversedChunk, room + 1))
            var floor = missing, top = missing
            if b > 0 {
                while floor - 1 >= layer.startFrame && top - floor + 1 < chunk && floor - 1 > reverseDeadBelow && !cache.contains(lane: key, frame: floor - 1) { floor -= 1 }
            } else {
                while top + 1 < layer.endFrame && top - floor + 1 < chunk && !cache.contains(lane: key, frame: top + 1) { top += 1 }
            }
            guard startReversedChunk(floor: floor, top: top, size: sz) else { return false }
        }
        guard let s = stream else { return false }
        return decodeReversedFrame(s)
    }

    /// The first frame of the window the cache lacks, nearest the playhead first in the playing direction; else `w` when
    /// its cached picture is a visibly different size than wanted. Frames the media has no source for are skipped.
    func reversedMissing(want w: Int, low: Int, high: Int, backward: Bool, size sz: PreviewDecodeSize) -> Int? {
        let order = backward
            ? Array(stride(from: w, through: low, by: -1)) + Array(stride(from: w + 1, through: max(w + 1, high), by: 1))
            : Array(stride(from: w, through: high, by: 1)) + Array(stride(from: w - 1, through: min(w - 1, low), by: -1))
        for f in order where f >= low && f <= high && f > reverseDeadBelow && !cache.contains(lane: key, frame: f) { return f }
        return w > reverseDeadBelow ? resizedFrame(w, size: sz) : nil
    }

    /// Opens a stream at the source time of timeline frame `top`, the lowest source time of the chunk [floor, top].
    func startReversedChunk(floor: Int, top: Int, size sz: PreviewDecodeSize) -> Bool {
        closeStream()
        guard let reader = openReader() else { reverseDeadBelow = max(reverseDeadBelow, top); return false }
        let seconds = layer.sourceTime(at: Double(top) / fps)
        let frames = MediaFrameStream.Frames(from: max(0, seconds), fps: fps, width: sz.width, height: sz.height)
        stream = MediaFrameStream(reader: reader, frames: frames.playing(at: layer.rate))
        streamSize = sz; reverseNext = top; reverseFloor = floor; restarts += 1
        return true
    }

    /// Decodes the open chunk's next frame (timeline frame `reverseNext`) and stores it; the chunk ends at its floor.
    func decodeReversedFrame(_ s: MediaFrameStream) -> Bool {
        let idx = reverseNext
        guard let next = reservedNext(s) else {
            // The source ends before this frame: it and every lower timeline frame (later in the source) have no picture.
            reverseDeadBelow = max(reverseDeadBelow, idx); closeStream(); giveUpIfNothingDecoded(); return true
        }
        reverseNext -= 1
        if mediaAspect == nil { mediaAspect = Self.opaqueAspect(next.image) }
        framesDecoded += 1
        cache.store(next.image, lane: key, frame: idx, reserved: next.reserved)
        delivered(idx)
        if reverseNext < reverseFloor { closeStream() }
        return true
    }
}
