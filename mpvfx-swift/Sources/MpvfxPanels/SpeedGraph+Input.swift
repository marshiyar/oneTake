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
import MpvfxTimeline

/// Pointer and keyboard intents over the speed graph. The host applies them as
/// editor commands; the graph previews them through `apply(_:)`.
public enum SpeedGraphAction: Equatable {
    case addPoint(t: Double, speed: Double)
    case movePoint(index: Int, t: Double, speed: Double)
    case removePoint(index: Int)
    case focusPoint(Int?)
    case setShape(NativeSpeedRampShape)
    case setEase(index: Int, ease: NativeInterpolation)

    /// Compares shapes by raw value so this stays Equatable whatever the
    /// shared shape enum conforms to.
    public static func == (lhs: SpeedGraphAction, rhs: SpeedGraphAction) -> Bool {
        switch (lhs, rhs) {
        case (.addPoint(let a, let b), .addPoint(let c, let d)): return a == c && b == d
        case (.movePoint(let a, let b, let c), .movePoint(let d, let e, let f)): return a == d && b == e && c == f
        case (.removePoint(let a), .removePoint(let b)): return a == b
        case (.focusPoint(let a), .focusPoint(let b)): return a == b
        case (.setShape(let a), .setShape(let b)): return a.rawValue == b.rawValue
        case (.setEase(let a, let b), .setEase(let c, let d)): return a == c && b == d
        default: return false
        }
    }
}

extension SpeedGraph {
    /// Press: a point grabs for a drag, empty graph adds one there.
    public func pointerDown(_ p: CanvasPoint) -> [SpeedGraphAction] {
        if let i = hitPoint(at: p) {
            draggingIndex = i
            draggingPreview = points[i]
            return [.focusPoint(i)]
        }
        let t = clampedFrame(frame(forX: p.x))
        let speed = clampedSpeed(speed(forY: p.y))
        return [.addPoint(t: t, speed: speed)]
    }

    /// Drag: moves the grabbed point live through `draggingPreview`.
    public func pointerMove(_ p: CanvasPoint) -> [SpeedGraphAction] {
        guard let i = draggingIndex, points.indices.contains(i) else { return [] }
        let t = clampedFrame(frame(forX: p.x))
        let speed = clampedSpeed(speed(forY: p.y))
        var preview = points[i]
        preview.t = neighborClampedFrame(t, index: i)
        preview.speed = speed
        draggingPreview = preview
        return []
    }

    /// Release: reports the drag as one move.
    public func pointerUp(_ p: CanvasPoint) -> [SpeedGraphAction] {
        guard let i = draggingIndex, points.indices.contains(i) else {
            draggingIndex = nil
            draggingPreview = nil
            return []
        }
        draggingIndex = nil
        draggingPreview = nil
        let t = neighborClampedFrame(clampedFrame(frame(forX: p.x)), index: i)
        let speed = clampedSpeed(speed(forY: p.y))
        return [.movePoint(index: i, t: t, speed: speed)]
    }

    /// Every pointer action is reachable by keyboard: Enter adds at the
    /// playhead, Tab walks focus, arrows nudge, Delete removes.
    public func keyDown(_ k: EditorKey) -> [SpeedGraphAction] {
        if k.command || k.alt { return [] }
        switch k.code {
        case .tab:
            guard !points.isEmpty else { return [] }
            if let f = focused, points.indices.contains(f) {
                let next = k.shift ? f - 1 : f + 1
                return [.focusPoint(points.indices.contains(next) ? next : nil)]
            }
            return [.focusPoint(k.shift ? points.count - 1 : 0)]
        case .enter:
            return [.addPoint(t: clampedFrame(playheadFrame), speed: clampedSpeed(rampSpeed(atFrame: playheadFrame)))]
        case .left, .right, .up, .down:
            guard let f = focused, points.indices.contains(f) else { return [] }
            let pt = points[f]
            switch k.code {
            case .left:
                let step = Double(k.shift ? 10 : 1)
                return [.movePoint(index: f, t: neighborClampedFrame(clampedFrame(pt.t - step), index: f), speed: pt.speed)]
            case .right:
                let step = Double(k.shift ? 10 : 1)
                return [.movePoint(index: f, t: neighborClampedFrame(clampedFrame(pt.t + step), index: f), speed: pt.speed)]
            case .up:
                let step = k.shift ? 0.5 : 0.05
                return [.movePoint(index: f, t: pt.t, speed: clampedSpeed(pt.speed + step))]
            default:
                let step = k.shift ? 0.5 : 0.05
                return [.movePoint(index: f, t: pt.t, speed: clampedSpeed(pt.speed - step))]
            }
        case .delete, .backspace:
            guard let f = focused, points.indices.contains(f), points.count > 1 else { return [] }
            return [.removePoint(index: f)]
        default:
            return []
        }
    }

    /// A frame kept strictly between the neighbours of `index`.
    func neighborClampedFrame(_ t: Double, index: Int) -> Double {
        let lo = index > 0 ? points[index - 1].t + 1 : 0
        let hi = index < points.count - 1 ? points[index + 1].t - 1 : durationFrames
        guard lo <= hi else { return points[index].t }
        return min(hi, max(lo, t))
    }
}
