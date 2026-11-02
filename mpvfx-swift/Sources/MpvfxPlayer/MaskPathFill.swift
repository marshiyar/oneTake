import Foundation
import MpvfxShared

/// Scanline fill of a free-form mask path at pixel centres, feeding the same feather/opacity/invert stage as
/// the shape masks. Fill rule: `nonzero` by default (a self-crossing outline fills every region it winds around),
/// `evenodd` leaves regions enclosed an even number of times empty. A path that fails validation fills nothing.
enum MaskPathFill {
    static func binary(width w: Int, height h: Int, path: NativeMaskPath) -> [Double] {
        var out = [Double](repeating: 0, count: w * h)
        guard (try? path.validate()) != nil else { return out }
        let poly = path.flattened().map { (x: $0.x * Double(w), y: $0.y * Double(h)) }
        let evenOdd = path.resolvedFillRule == "evenodd"
        for y in 0..<h {
            let yc = Double(y) + 0.5
            var crossings: [(x: Double, dir: Int)] = []
            for i in poly.indices {
                let a = poly[i], b = poly[(i + 1) % poly.count]
                // Half-open rule so a vertex exactly on the scanline is counted once.
                if (a.y <= yc && b.y > yc) || (b.y <= yc && a.y > yc) {
                    crossings.append((a.x + (yc - a.y) / (b.y - a.y) * (b.x - a.x), b.y > a.y ? 1 : -1))
                }
            }
            crossings.sort { $0.x < $1.x }
            var winding = 0
            for i in 0..<max(crossings.count - 1, 0) {
                winding += crossings[i].dir
                let inside = evenOdd ? (i % 2 == 0) : winding != 0
                guard inside else { continue }
                let lo = max(Int((crossings[i].x - 0.5).rounded(.up)), 0)
                let hi = min(Int((crossings[i + 1].x - 0.5).rounded(.up)) - 1, w - 1)
                if lo <= hi { for x in lo...hi { out[y * w + x] = 1 } }
            }
        }
        return out
    }
}
