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
// The colour key as the Colour key panel and the stage eyedropper use it (issue #300): the matte a key makes of a frame,
// for the preview's Matte view, and the colour under the pointer. The matte is the same chroma distance and smoothstep
// as GradeShader's key (`GradeShader.swift`, the CPU reference every GPU kernel is held to), so the view shows what the
// key will do to the picture, and the average is taken from the ungraded source pixels the shader sees.
import Foundation

public enum ColorKeyMatte {
    /// The matte, 0 (keyed out) to 1 (kept), of a pixel with straight RGB `r`, `g`, `b` in 0…1.
    public static func matte(r: Double, g: Double, b: Double, key: ColorGradeParams.ColorKey) -> Double {
        func chroma(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double) {
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            return ((b - y) / 1.8556, (r - y) / 1.5748)
        }
        let p = chroma(r, g, b), k = chroma(key.color.x, key.color.y, key.color.z)
        let distance = ((p.0 - k.0) * (p.0 - k.0) + (p.1 - k.1) * (p.1 - k.1)).squareRoot()
        let width = max(key.smoothness, 0.000001)
        let t = min(1, max(0, (distance - key.similarity) / width))
        return t * t * (3 - 2 * t)
    }

    /// The matte of an 8-bit straight RGBA frame as an opaque greyscale frame: white where the picture is kept, black
    /// where it is keyed out (the source alpha scales it, so transparent pixels read black too).
    public static func image(rgba: [UInt8], width: Int, height: Int, key: ColorGradeParams.ColorKey) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let o = i * 4
            let m = matte(r: Double(rgba[o]) / 255, g: Double(rgba[o + 1]) / 255, b: Double(rgba[o + 2]) / 255, key: key)
            let v = UInt8((m * Double(rgba[o + 3]) / 255 * 255).rounded())
            out[o] = v; out[o + 1] = v; out[o + 2] = v
        }
        return out
    }

    /// The alpha-weighted mean RGB (0…1) of the (2·radius+1)² patch centred on pixel (x, y) of an 8-bit straight RGBA
    /// frame; the patch is cut at the frame's edges. Nil when every pixel in it is transparent or the frame is empty.
    public static func average(rgba: [UInt8], width: Int, height: Int, x: Int, y: Int, radius: Int = 2) -> SIMD3<Double>? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        let x0 = max(0, x - radius), x1 = min(width - 1, x + radius), y0 = max(0, y - radius), y1 = min(height - 1, y + radius)
        guard x0 <= x1, y0 <= y1 else { return nil }
        var sum = SIMD3<Double>(0, 0, 0), weight = 0.0
        for py in y0...y1 {
            for px in x0...x1 {
                let o = (py * width + px) * 4, a = Double(rgba[o + 3]) / 255
                guard a > 0 else { continue }
                sum += SIMD3(Double(rgba[o]), Double(rgba[o + 1]), Double(rgba[o + 2])) / 255 * a
                weight += a
            }
        }
        return weight > 0 ? sum / weight : nil
    }
}
