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

/// Timeline zoom and getTimelineFitPps.
public enum TimelineZoomMode: String, Codable, Equatable, Sendable { case fit, manual }

public enum TimelineZoom {
    /// Fit is the zoom-out limit; its end margin leaves room to extend the last clip.
    public static let minPercent = 100.0
    static let maxFrameWidthPx = 48.0
    public static let previewFPS = 30.0            // STUDIO_PREVIEW_FPS
    static let zoomOutFactor = 0.5, zoomInFactor = 2.0, pinchSensitivity = 0.014
    /// The shortest span fit shows, so an empty or one-frame sequence still gets a readable ruler.
    public static let minFitSpan = 5.0

    /// JS Math.round (round half up).
    static func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

    /// Room after the sequence end, in seconds: 5% of the end, at least 1 s, so the end marker and the last clip's
    /// trim handle are never at the viewport edge.
    public static func endMargin(_ end: Double) -> Double {
        max(1, (end.isFinite && end > 0 ? end : 0) * 0.05)
    }
    /// The time span the timeline lays out: the sequence end plus its margin (at least `minFitSpan`). Fit shows all
    /// of it, the ruler stops at its end and horizontal scrolling stops there.
    public static func span(duration: Double) -> Double {
        let end = duration.isFinite && duration > 0 ? duration : 0
        return max(end + endMargin(end), minFitSpan)
    }

    public static func fitPixelsPerSecond(viewportWidth: Double, duration: Double, contentOrigin: Double) -> Double {
        guard viewportWidth.isFinite, viewportWidth > contentOrigin else { return 100 }
        return (viewportWidth - contentOrigin - 2) / span(duration: duration)
    }

    /// Where a zoom from a button, key or the slider is anchored: the playhead while it is in the visible lanes, else
    /// the middle of them, so the part of the sequence being edited stays on screen.
    public static func anchorX(playheadX: Double, contentLeft: Double, viewportWidth: Double) -> Double {
        guard playheadX.isFinite else { return (contentLeft + viewportWidth) / 2 }
        return playheadX >= contentLeft && playheadX <= viewportWidth ? playheadX : (contentLeft + viewportWidth) / 2
    }
    public static func maxPercent(fit: Double) -> Double {
        guard fit.isFinite, fit > 0 else { return 100 }
        return max(100, jsRound(previewFPS * maxFrameWidthPx / fit * 100))
    }
    /// The zoom percent within the limits; `rounded` (the buttons, slider and pinch) also snaps it to a whole percent,
    /// while an absolute scale (`TimelineController.setZoom(pixelsPerSecond:)`) keeps its exact ratio.
    public static func clamp(_ percent: Double, fit: Double, rounded: Bool = true) -> Double {
        guard percent.isFinite else { return 100 }
        return max(minPercent, min(maxPercent(fit: fit), rounded ? jsRound(percent) : percent))
    }
    public static func percent(_ mode: TimelineZoomMode, manual: Double, fit: Double) -> Double {
        mode == .fit ? 100 : clamp(manual, fit: fit, rounded: false)   // stored values were clamped on the way in
    }
    public static func pixelsPerSecond(fit: Double, mode: TimelineZoomMode, manual: Double) -> Double {
        guard fit.isFinite, fit > 0 else { return 100 }
        return mode == .fit ? fit : fit * (percent(mode, manual: manual, fit: fit) / 100)
    }
    public static func next(_ dirIn: Bool, mode: TimelineZoomMode, manual: Double, fit: Double) -> Double {
        let c = percent(mode, manual: manual, fit: fit)
        return clamp(c * (dirIn ? zoomInFactor : zoomOutFactor), fit: fit)
    }
    /// timelineZoomPercentToSlider: log scale from minPercent to maxPercent onto 0...100.
    public static func slider(percent: Double, fit: Double) -> Double {
        let lo = log(minPercent), hi = log(maxPercent(fit: fit))
        guard hi > lo else { return 0 }
        return (log(clamp(percent, fit: fit)) - lo) / (hi - lo) * 100
    }
    /// timelineSliderToZoomPercent (inverse of slider(percent:fit:)).
    public static func percent(slider: Double, fit: Double) -> Double {
        let lo = log(minPercent), hi = log(maxPercent(fit: fit))
        let v = max(0, min(100, slider.isFinite ? slider : 0))
        return clamp(exp(lo + v / 100 * (hi - lo)), fit: fit)
    }
    public static func pinch(deltaY: Double, mode: TimelineZoomMode, manual: Double, fit: Double) -> Double {
        let c = percent(mode, manual: manual, fit: fit)
        guard deltaY.isFinite, deltaY != 0 else { return c }
        return clamp(c * exp(-deltaY * pinchSensitivity), fit: fit)
    }
}

/// Timeline snapping.
public enum TimelineSnapType: Int, Sendable { case playhead = 0, clipEdge = 1, beat = 2 }   // raw value = priority
public struct TimelineSnapTarget: Equatable, Sendable { public var time: Double; public var type: TimelineSnapType }

public enum TimelineSnapping {
    public static let snapPx = 8.0

    public static func targets(clips: [(key: String, start: Double, duration: Double)], playhead: Double?,
                               beats: [Double], excluding: Set<String> = []) -> [TimelineSnapTarget] {
        var byTime: [Double: TimelineSnapTarget] = [:]
        func add(_ t: Double, _ type: TimelineSnapType) {
            guard t.isFinite, t >= 0 else { return }
            let r = TimelineZoom.jsRound(t * 1000) / 1000
            if let e = byTime[r], e.type.rawValue <= type.rawValue { return }
            byTime[r] = TimelineSnapTarget(time: type == .beat ? t : r, type: type)
        }
        for b in beats { add(b, .beat) }
        for c in clips where !excluding.contains(c.key) { add(c.start, .clipEdge); add(c.start + c.duration, .clipEdge) }
        if let playhead { add(playhead, .playhead) }
        return byTime.values.sorted { $0.time < $1.time }
    }

    public static func snap(_ time: Double, _ targets: [TimelineSnapTarget], thresholdSecs: Double) -> (time: Double, target: TimelineSnapTarget?) {
        var best: TimelineSnapTarget?; var bestDist = thresholdSecs
        for t in targets {
            let d = abs(t.time - time)
            if d < bestDist || (d == bestDist && best != nil && t.type.rawValue < best!.type.rawValue) { bestDist = d; best = t }
        }
        return best.map { ($0.time, $0) } ?? (time, nil)
    }

    /// snapMoveToTargets: nearest edge snaps, duration fixed, clamped to [0, timelineDuration - duration].
    public static func snapMove(start: Double, duration: Double, _ targets: [TimelineSnapTarget], pps: Double,
                                timelineDuration: Double) -> (start: Double, snap: TimelineSnapTarget?) {
        if targets.isEmpty { return (start, nil) }
        let th = snapPx / max(pps, 1)
        let s = snap(start, targets, thresholdSecs: th), e = snap(start + duration, targets, thresholdSecs: th)
        var candidate = start; var target: TimelineSnapTarget?
        if let st = s.target, e.target == nil || abs(s.time - start) <= abs(e.time - (start + duration)) {
            candidate = s.time; target = st
        } else if let et = e.target { candidate = e.time - duration; target = et }
        let rounded = TimelineZoom.jsRound(candidate * 1000) / 1000
        let clamped = max(0, min(max(0, timelineDuration - duration), rounded))
        if target != nil && abs(clamped - rounded) > 1e-6 { target = nil }
        return (clamped, target)
    }
}
