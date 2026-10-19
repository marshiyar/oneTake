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

/// Preview zoom and pan. Fit (100 %) is the floor; zoom scales the
/// fitted frame about the stage centre and pan offsets it, clamped so the frame never leaves the stage needlessly.
public struct PreviewZoom: Equatable, Sendable {
    public static let minPercent = 100.0, maxPercent = 400.0
    static let sensitivity = 0.007, maxDelta = 10.0
    public var percent = 100.0, panX = 0.0, panY = 0.0
    public init(percent: Double = 100, panX: Double = 0, panY: Double = 0) { self.percent = percent; self.panX = panX; self.panY = panY }
    public static let fit = PreviewZoom()

    public var isAtFit: Bool { abs(percent - 100) < 0.5 && abs(panX) < 0.1 && abs(panY) < 0.1 }
    public var scale: Double { Self.clamp(percent) / 100 }
    /// "Fit" or "250%", as the zoom HUD and reset button read.
    public var label: String { isAtFit ? "Fit" : "\(Int((percent).rounded()))%" }

    public static func clamp(_ p: Double) -> Double { p.isFinite ? min(maxPercent, max(minPercent, p)) : 100 }

    public static func wheelPercent(deltaY: Double, current: Double) -> Double {
        guard deltaY.isFinite else { return clamp(current) }
        let d = abs(deltaY) > maxDelta ? maxDelta * (deltaY < 0 ? -1 : 1) : deltaY
        return clamp(clamp(current) * exp(-d * sensitivity))
    }
    public static func stepPercent(zoomIn: Bool, current: Double) -> Double { clamp(clamp(current) * (zoomIn ? 1.25 : 0.8)) }

    public static func clampPan(x: Double, y: Double, percent: Double, viewport: CanvasSize, content: CanvasSize) -> (Double, Double) {
        let s = clamp(percent) / 100
        let mx = max(0, (content.width * s - viewport.width) / 2), my = max(0, (content.height * s - viewport.height) / 2)
        return (mx == 0 ? 0 : min(mx, max(-mx, x)), my == 0 ? 0 : min(my, max(-my, y)))
    }

    /// Ctrl/⌘ + wheel: zoom keeping the point under the cursor (offset from the viewport centre) fixed.
    public func wheelZoom(deltaY: Double, cursor: CanvasPoint?, viewport: CanvasSize, content: CanvasSize) -> PreviewZoom {
        let old = Self.clamp(percent), next = Self.wheelPercent(deltaY: deltaY, current: old)
        var x = panX, y = panY
        if let c = cursor { let r = next / old; x = c.x * (1 - r) + x * r; y = c.y * (1 - r) + y * r }
        let (cx, cy) = Self.clampPan(x: x, y: y, percent: next, viewport: viewport, content: content)
        return PreviewZoom(percent: next, panX: cx, panY: cy)
    }
    /// Plain wheel over the stage pans the zoomed frame.
    public func wheelPan(dx: Double, dy: Double, viewport: CanvasSize, content: CanvasSize) -> PreviewZoom {
        let (x, y) = Self.clampPan(x: panX - dx, y: panY - dy, percent: percent, viewport: viewport, content: content)
        return PreviewZoom(percent: Self.clamp(percent), panX: x, panY: y)
    }
    /// Zoom in/out by one step about the centre.
    public func stepped(zoomIn: Bool, viewport: CanvasSize, content: CanvasSize) -> PreviewZoom {
        let next = Self.stepPercent(zoomIn: zoomIn, current: percent)
        let (x, y) = Self.clampPan(x: panX, y: panY, percent: next, viewport: viewport, content: content)
        return PreviewZoom(percent: next, panX: x, panY: y)
    }
}
