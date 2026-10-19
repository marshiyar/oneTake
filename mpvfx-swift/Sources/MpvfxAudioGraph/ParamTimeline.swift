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

/// The Web Audio `AudioParam` automation timeline, for the event kinds the FX
/// scheduler emits (`setValueAtTime`, `linearRampToValueAtTime`,
/// `setValueCurveAtTime`). Values are evaluated at sample-frame times
/// `frame / sampleRate`, the way an OfflineAudioContext renders them.
public final class ParamTimeline {
    enum Event {
        case set(time: Double, value: Float)
        case ramp(time: Double, value: Float)
        case curve(time: Double, duration: Double, values: [Float])
        var time: Double { switch self { case let .set(t, _), let .ramp(t, _): return t; case let .curve(t, _, _): return t } }
    }

    /// `.value`: the intrinsic value used before the first event.
    public var value: Float
    private(set) var events: [Event] = []
    let sampleRate: Double
    // Forward-only cursor for frame-ordered evaluation.
    private var cursor = 0
    private var cursorPrevTime: Double? = nil
    private var cursorPrevValue: Float = 0

    public init(_ value: Float, sampleRate: Double) { self.value = value; self.sampleRate = sampleRate }

    public var hasEvents: Bool { !events.isEmpty }

    public func cancelScheduledValues(_ from: Double) {
        events.removeAll { $0.time >= from }
        resetCursor()
    }
    public func setValueAtTime(_ v: Float, _ t: Double) { insert(.set(time: t, value: v)) }
    public func linearRampToValueAtTime(_ v: Float, _ t: Double) { insert(.ramp(time: t, value: v)) }
    /// Throws when the curve would overlap another curve, as the browser does.
    public func setValueCurveAtTime(_ values: [Float], _ t: Double, _ d: Double) throws {
        for e in events {
            if case let .curve(ct, cd, _) = e, t < ct + cd && ct < t + d { throw CurveOverlap() }
            if t < e.time && e.time < t + d { throw CurveOverlap() }
        }
        insert(.curve(time: t, duration: d, values: values))
    }
    struct CurveOverlap: Error {}

    private func insert(_ e: Event) {
        // Same-time events keep insertion order; a later event of the same type at
        // the same time replaces the earlier (spec "replace" rule).
        var i = events.count
        while i > 0 && events[i - 1].time > e.time { i -= 1 }
        if i > 0, events[i - 1].time == e.time, sameKind(events[i - 1], e) { events[i - 1] = e } else { events.insert(e, at: i) }
        resetCursor()
    }
    private func sameKind(_ a: Event, _ b: Event) -> Bool {
        switch (a, b) { case (.set, .set), (.ramp, .ramp), (.curve, .curve): return true; default: return false }
    }
    private func resetCursor() { cursor = 0; cursorPrevTime = nil; cursorPrevValue = value }

    /// Value at time `t`. Calls must be non-decreasing in `t` between resets for the cursor to be valid.
    public func valueAt(_ t: Double) -> Float {
        if events.isEmpty { return value }
        if cursor == 0 && cursorPrevTime == nil { cursorPrevValue = value }
        // Advance past every event that has fully completed by `t`.
        while cursor < events.count {
            switch events[cursor] {
            case let .set(time, v):
                guard t >= time else { return held() }
                cursorPrevTime = time; cursorPrevValue = v; cursor += 1
            case let .ramp(time, v):
                guard t >= time else {
                    guard let t0 = cursorPrevTime else { return held() }
                    let v0 = Double(cursorPrevValue)
                    return Float(v0 + (Double(v) - v0) * (t - t0) / (time - t0))
                }
                cursorPrevTime = time; cursorPrevValue = v; cursor += 1
            case let .curve(time, duration, values):
                guard t >= time else { return held() }
                let end = time + duration
                guard t >= end else {
                    let n = values.count
                    let virtualIndex = Double(n - 1) / duration * (t - time)
                    let k = Int(virtualIndex)
                    if k >= n - 1 { return values[n - 1] }
                    let a = Double(values[k]), b = Double(values[k + 1])
                    return Float(a + (b - a) * (virtualIndex - Double(k)))
                }
                cursorPrevTime = end; cursorPrevValue = values.last ?? cursorPrevValue; cursor += 1
            }
        }
        return held()
    }
    private func held() -> Float { cursorPrevValue }

    /// a-rate values for `count` frames starting at context frame `frame`.
    public func fill(frame: Int, count: Int, into out: inout [Float]) {
        if events.isEmpty { for i in 0..<count { out[i] = value }; return }
        for i in 0..<count { out[i] = valueAt(Double(frame + i) / sampleRate) }
    }
}

/// One AudioParam an automation lane writes, with the knob-to-param unit mapping.
public struct ParamTarget {
    public let param: ParamTimeline
    public let map: ((Double) -> Double)?
}

/// FX automation: lanes become AudioParam events.
public enum FxAutomationScheduler {
    static let curvePointsPerSec = 100.0
    static let minCurvePoints = 8
    static let maxCurvePoints = 4096

    public struct Timing: Sendable { public var scheduledAt: Double; public var elapsed: Double; public var rate: Double
        public init(scheduledAt: Double = 0, elapsed: Double = 0, rate: Double = 1) { self.scheduledAt = scheduledAt; self.elapsed = elapsed; self.rate = rate } }

    public enum Op: Equatable {
        case set(time: Double, value: Float)
        case ramp(time: Double, value: Float)
        case curve(time: Double, duration: Double, values: [Float])
    }

    static func isStraight(_ p: AutomationPoint, _ scale: FxScale, _ hasMap: Bool) -> Bool {
        let bent = (p.curve.map { $0 != 0 } ?? false) || (p.viaX != nil && p.viaY != nil)
        return !bent && scale == .linear && !hasMap
    }

    static func curvePointCount(_ duration: Double) -> Int {
        min(maxCurvePoints, max(minCurvePoints, Int((duration * curvePointsPerSec).rounded(.up))))
    }

    public static func planOps(_ lane: AutomationLane, _ scale: FxScale, _ timing: Timing, _ map: ((Double) -> Double)?) -> [Op] {
        let apply = map ?? { $0 }
        let toCtx = { (t: Double) in timing.scheduledAt + (t - timing.elapsed) / timing.rate }
        var ops: [Op] = []
        if lane.points.count >= 2 {
            for i in 0..<(lane.points.count - 1) {
                let a = lane.points[i], b = lane.points[i + 1]
                let toTime = toCtx(b.t)
                if toTime <= timing.scheduledAt { continue }
                let fromTime = max(timing.scheduledAt, toCtx(a.t))
                let duration = toTime - fromTime
                if duration <= 0 { continue }
                if isStraight(a, scale, map != nil) { ops.append(.ramp(time: toTime, value: Float(apply(b.v)))); continue }
                let count = curvePointCount(duration)
                let raw = AudioAutomation.sampleCurve(lane, max(a.t, timing.elapsed), b.t, count, scale)
                ops.append(.curve(time: fromTime, duration: duration, values: raw.map { Float(apply(Double($0))) }))
            }
        }
        if case let .curve(t, _, _)? = ops.first, t <= timing.scheduledAt {} else {
            ops.insert(.set(time: timing.scheduledAt, value: Float(apply(AudioAutomation.sampleLane(lane, timing.elapsed, scale)))), at: 0)
        }
        return ops
    }

    static func emit(_ param: ParamTimeline, _ ops: [Op]) {
        for op in ops {
            switch op {
            case let .set(t, v): param.setValueAtTime(v, t)
            case let .ramp(t, v): param.linearRampToValueAtTime(v, t)
            case let .curve(t, d, values):
                do { try param.setValueCurveAtTime(values, t, d) } catch { param.linearRampToValueAtTime(values.last ?? 0, t + d) }
            }
        }
    }

    public static func scheduleLane(_ targets: [ParamTarget], _ lane: AutomationLane, _ scale: FxScale, _ timing: Timing) {
        if lane.points.isEmpty { return }
        for target in targets {
            target.param.cancelScheduledValues(0)
            if AudioAutomation.isConstantLane(lane) {
                target.param.setValueAtTime(Float((target.map ?? { $0 })(lane.points[0].v)), timing.scheduledAt)
                continue
            }
            emit(target.param, planOps(lane, scale, timing, target.map))
        }
    }
}
