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
import Foundation
import MpvfxCanvas
import MpvfxShared

/// Deterministic CPU coverage rasterizer shared by live preview and export.
public enum MaskCoverageRasterizer {
    public static func coverage(width: Int, height: Int, masks: [NativeClipMask]) -> [Double] {
        guard width > 0, height > 0 else { return [] }
        let supported = masks.filter(\.isSupported)
        guard !supported.isEmpty else { return [Double](repeating: 1, count: width * height) }
        var result = [Double](repeating: 0, count: width * height)
        var hasMask = false
        for mask in supported {
            let next = shape(width: width, height: height, mask: mask)
            let mode = hasMask ? mask.resolvedMode : "add"
            for i in result.indices {
                switch mode {
                case "subtract": result[i] *= 1 - next[i]
                case "intersect": result[i] *= next[i]
                default: result[i] = 1 - (1 - result[i]) * (1 - next[i])
                }
            }
            hasMask = true
        }
        return result
    }

    public static func applying(_ masks: [NativeClipMask], to image: CanvasImage) -> CanvasImage {
        let c = coverage(width: image.width, height: image.height, masks: masks)
        guard !c.isEmpty else { return image }
        var rgba = image.rgba
        for i in c.indices { rgba[i * 4 + 3] = UInt8((Double(rgba[i * 4 + 3]) * c[i]).rounded().clamped(to: 0...255)) }
        return CanvasImage(width: image.width, height: image.height, rgba: rgba)
    }

    /// Applies layer-local coverage to a picture contained within that layer. `picture` and the layer dimensions
    /// are expressed in the same device-pixel coordinate space, so feather remains measured in rendered pixels.
    public static func applying(_ masks: [NativeClipMask], to image: CanvasImage, layerWidth: Int, layerHeight: Int,
                                picture: CanvasRect) -> CanvasImage {
        let c = coverage(width: layerWidth, height: layerHeight, masks: masks)
        guard !c.isEmpty, picture.width > 0, picture.height > 0 else { return image }
        var rgba = image.rgba
        for y in 0..<image.height { for x in 0..<image.width {
            let layerX = Int((picture.x + (Double(x) + 0.5) * picture.width / Double(image.width)).rounded(.down))
            let layerY = Int((picture.y + (Double(y) + 0.5) * picture.height / Double(image.height)).rounded(.down))
            let coverage = (0..<layerWidth).contains(layerX) && (0..<layerHeight).contains(layerY)
                ? c[layerY * layerWidth + layerX] : 0
            let alpha = y * image.width * 4 + x * 4 + 3
            rgba[alpha] = UInt8((Double(rgba[alpha]) * coverage).rounded().clamped(to: 0...255))
        }}
        return CanvasImage(width: image.width, height: image.height, rgba: rgba)
    }

    private static func shape(width w: Int, height h: Int, mask m: NativeClipMask) -> [Double] {
        let cx = (m.x ?? 0.5) * Double(w), cy = (m.y ?? 0.5) * Double(h)
        let mw = (m.width ?? 1) * Double(w), mh = (m.height ?? 1) * Double(h)
        let expansion = m.expansion ?? 0, feather = m.feather ?? 0, opacity = m.opacity ?? 1
        let a = (m.angle ?? 0) * .pi / 180, ca = cos(a), sa = sin(a)
        var out = [Double](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
            let rx = dx * ca + dy * sa, ry = -dx * sa + dy * ca
            let distance: Double
            switch m.kind {
            case "ellipse":
                let ax = max(0.0001, mw / 2 + expansion), ay = max(0.0001, mh / 2 + expansion)
                distance = (1 - sqrt((rx / ax) * (rx / ax) + (ry / ay) * (ry / ay))) * min(ax, ay)
            case "linear": distance = expansion - rx
            case "band": distance = mw / 2 + expansion - abs(rx)
            default:
                let qx = mw / 2 + expansion - abs(rx), qy = mh / 2 + expansion - abs(ry)
                distance = min(qx, qy)
            }
            out[y * w + x] = distance >= 0 ? 1 : 0
        }}
        if feather > 0 { out = gaussianBlur(out, width: w, height: h, sigma: feather / 2) }
        for i in out.indices {
            var value = out[i] * opacity
            if m.invert == true { value = 1 - value }
            out[i] = value.clamped(to: 0...1)
        }
        return out
    }

    /// A normalized, separable Gaussian. Samples beyond the layer edge repeat the edge coverage.
    private static func gaussianBlur(_ input: [Double], width: Int, height: Int, sigma: Double) -> [Double] {
        let radius = max(1, Int((sigma * 3).rounded(.up)))
        var kernel = [Double](), sum = 0.0
        for x in -radius...radius { let v = exp(-Double(x * x) / (2 * sigma * sigma)); kernel.append(v); sum += v }
        kernel = kernel.map { $0 / sum }
        var horizontal = [Double](repeating: 0, count: input.count), output = horizontal
        for y in 0..<height { for x in 0..<width {
            for k in -radius...radius { horizontal[y * width + x] += input[y * width + min(max(x + k, 0), width - 1)] * kernel[k + radius] }
        }}
        for y in 0..<height { for x in 0..<width {
            for k in -radius...radius { output[y * width + x] += horizontal[min(max(y + k, 0), height - 1) * width + x] * kernel[k + radius] }
        }}
        return output
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
