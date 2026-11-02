import Foundation
import MpvfxCanvas
import MpvfxColor

/// Adjustment layers (issue #326): a layer with no picture whose grade and effects apply to the composite painted
/// below it. Preview (`PreviewCompositor.draw`) and export (`ExportFramePainter.paint`) both call this one function,
/// so they grade the same pixels the same way.
extension PreviewPainter {
    /// Grades the part of `canvas` inside `frame` (the project canvas, in canvas pixels) with the layer's grade at
    /// `time`, then mixes the graded picture over the original by the layer's opacity (0.5 gives the midpoint). A
    /// layer with no active grade changes nothing. The pad around the frame is left as it is.
    static func applyAdjustment(_ layer: PreviewLayer, on canvas: RasterCanvas, frame: CanvasRect,
                                grader: PreviewGrader, time: Double) {
        guard layer.isVisible, let grade = layer.grade, grade.isActive else { return }
        let w = canvas.surface.width, h = canvas.surface.height
        let x0 = max(0, Int(frame.x.rounded())), y0 = max(0, Int(frame.y.rounded()))
        let x1 = min(w, Int((frame.x + frame.width).rounded())), y1 = min(h, Int((frame.y + frame.height).rounded()))
        guard x1 > x0, y1 > y0 else { return }
        let below = canvas.image().rgba
        let cw = x1 - x0, ch = y1 - y0
        var region = [UInt8](repeating: 0, count: cw * ch * 4)
        for y in 0..<ch {
            let src = ((y0 + y) * w + x0) * 4
            region.replaceSubrange(y * cw * 4..<(y + 1) * cw * 4, with: below[src..<src + cw * 4])
        }
        let graded = grader.gradeNow(CanvasImage(width: cw, height: ch, rgba: region), grade: grade, time: time).rgba
        let k = Float(max(0, min(1, layer.opacity)))
        var out = below
        for y in 0..<ch {
            let row = y * cw * 4, dst = ((y0 + y) * w + x0) * 4
            for i in 0..<(cw * 4) {
                let from = Float(out[dst + i]), to = Float(graded[row + i])
                out[dst + i] = k >= 1 ? graded[row + i] : UInt8(max(0, min(255, (from + (to - from) * k).rounded())))
            }
        }
        // `clear` ignores the transform and clip and starts the state stack afresh: nothing is open while layers are drawn.
        canvas.clear(.transparent)
        canvas.drawImage(CanvasImage(width: w, height: h, rgba: out), in: CanvasRect(x: 0, y: 0, width: Double(w), height: Double(h)))
    }
}
