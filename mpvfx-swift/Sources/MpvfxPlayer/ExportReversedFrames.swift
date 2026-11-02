// Export frames of a reversed clip: its timeline frames run through the source backwards, so the exporter reads a short
// chunk of the source forward in one stream and serves the chunk's frames last to first, instead of seeking per frame.
import Foundation
import MpvfxCanvas
import MpvfxShared
import OneTakeMedia

/// A chunk of decoded frames of one reversed layer at one output size. `frames[k]` is the picture at source time
/// `topTime - k * step`, so asking for consecutive timeline frames walks the array from the front.
struct ReversedFrameBuffer {
    /// Most frames one chunk holds (a few seconds of GOP at most).
    static let maxFrames = 32

    var topTime: Double, step: Double, width: Int, height: Int
    var frames: [CanvasImage]

    /// Frames one chunk may hold: a quarter of the preview frame budget (`MemoryBudget.previewFrames`) per layer, at
    /// least one, at most `maxFrames`.
    static func capacity(width: Int, height: Int, budget: Int = MemoryBudget.previewFrames()) -> Int {
        max(1, min(maxFrames, budget / 4 / max(1, width * height * 4)))
    }

    /// The picture at source time `t` when this chunk holds it at this size.
    func image(at t: Double, width w: Int, height h: Int) -> CanvasImage? {
        guard w == width, h == height, step > 0, !frames.isEmpty else { return nil }
        let k = Int(((topTime - t) / step).rounded())
        guard k >= 0, k < frames.count, abs(topTime - Double(k) * step - t) < step / 4 else { return nil }
        return frames[k]
    }

    /// Decodes the chunk that ends at source time `t` (the highest source time of the chunk) with one forward stream.
    /// `lowest` is the lowest source time of the clip (its in point): the chunk never reads below it. `step` is source seconds
    /// between timeline frames (rate / fps). nil when the engine returns no frame.
    static func fill(reader: VideoFrameReader, endingAt t: Double, notBefore lowest: Double, step: Double, fps: Double, rate: Double,
                     width: Int, height: Int, capacity: Int) -> ReversedFrameBuffer? {
        guard step > 0 else { return nil }
        let count = max(1, min(capacity, Int(((t - lowest) / step + 1e-6).rounded(.down)) + 1))
        let start = max(0, t - Double(count - 1) * step)
        let stream = MediaFrameStream(reader: reader, frames: MediaFrameStream.Frames(from: start, fps: fps, width: width, height: height).playing(at: rate))
        var forward: [CanvasImage] = []
        forward.reserveCapacity(count)
        for _ in 0..<count {
            guard let next = withAutoreleasePool({ stream.next() }) else { break }
            forward.append(next)
        }
        guard !forward.isEmpty else { return nil }
        return ReversedFrameBuffer(topTime: start + Double(forward.count - 1) * step, step: step, width: width, height: height,
                                   frames: forward.reversed())
    }
}
