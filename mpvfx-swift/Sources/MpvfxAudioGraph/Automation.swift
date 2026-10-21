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

// Audio automation lanes: parsing, ordering and evaluation of FX parameter automation.

public struct AutomationPoint: Equatable, Sendable {
    public var t: Double
    public var v: Double
    public var curve: Double?
    public var viaX: Double?
    public var viaY: Double?
    /// Which automatic tool wrote the point (nil: drawn by hand); a tool re-runs over its own points only.
    public var origin: String?
    public init(t: Double, v: Double, curve: Double? = nil, viaX: Double? = nil, viaY: Double? = nil, origin: String? = nil) {
        self.t = t; self.v = v; self.curve = curve; self.viaX = viaX; self.viaY = viaY; self.origin = origin
    }
}

public struct AutomationLane: Equatable, Sendable {
    public var target: String
    public var points: [AutomationPoint]
    public init(target: String, points: [AutomationPoint]) { self.target = target; self.points = points }
}

public struct Automation: Equatable, Sendable {
    public var version = 1
    public var lanes: [AutomationLane]
    public init(lanes: [AutomationLane] = []) { self.lanes = lanes }
}

public enum AutomationTarget: Equatable, Sendable {
    case volume
    case fx(nodeId: String, param: String)
    case preset(presetId: String)
}

public struct AutomationRange: Equatable, Sendable {
    public var min: Double
    public var max: Double
    public var step: Double
    public var unit: String
    public var label: String
    public var scale: FxScale
    public var defaultValue: Double
}

public struct AudioAutomationError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

public enum AudioAutomation {
    public static let attribute = "data-automation"
    public static let version = 1
    public static let maxPoints = 512
    public static let volumeTarget = "volume"
    /// MAX_AUDIO_GAIN: +12 dB.
    public static let maxAudioGain = pow(10.0, 12.0 / 20.0)
    public static let presetRange = AutomationRange(min: 0, max: 1, step: 0.01, unit: "", label: "Amount", scale: .linear, defaultValue: 1)
    public static let volumeRange = AutomationRange(min: 0, max: maxAudioGain, step: 0.01, unit: "", label: "Volume", scale: .linear, defaultValue: 1)

    public static func parseTarget(_ target: String) -> AutomationTarget? {
        if target == volumeTarget { return .volume }
        let parts = target.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 3 && parts[0] == "fx" && parts[1] == "preset" {
            return parts[2].isEmpty ? nil : .preset(presetId: parts[2])
        }
        guard parts.count == 3, parts[0] == "fx", !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        return .fx(nodeId: parts[1], param: parts[2])
    }

    public static func fxTarget(_ nodeId: String, _ param: String) -> String { "fx.\(nodeId).\(param)" }
    public static func presetTarget(_ presetId: String) -> String { "fx.preset.\(presetId)" }

    public static func resolveRange(_ target: String, _ chain: FxChain?) -> AutomationRange? {
        guard let parsed = parseTarget(target) else { return nil }
        switch parsed {
        case .volume: return volumeRange
        case let .preset(presetId):
            guard chain?.nodes.contains(where: { $0.fromPreset == presetId }) == true else { return nil }
            var r = presetRange
            r.label = "\(presetId) · Amount"
            return r
        case let .fx(nodeId, param):
            guard let node = chain?.nodes.first(where: { $0.id == nodeId }), let def = AudioFx.definition(node.type),
                  let p = def.params.first(where: { $0.key == param }),
                  case let .number(_, label, unit, mn, mx, step, d, scale, _) = p else { return nil }
            return AutomationRange(min: mn, max: mx, step: step, unit: unit, label: "\(def.label) · \(label)",
                                   scale: scale == .log && mn > 0 ? .log : .linear, defaultValue: d)
        }
    }

    // MARK: cleaning

    static func numberOrNull(_ raw: JSONValue?) -> Double? {
        switch raw {
        case let .number(n)?: return n.isFinite ? n : nil
        case let .string(s)? where !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            let n = jsStringToNumber(s); return n.isFinite ? n : nil
        default: return nil
        }
    }

    static func clampCurve(_ v: JSONValue?) -> Double {
        guard let n = numberOrNull(v), n != 0 else { return 0 }
        return min(1, max(-1, n))
    }

    static func clampVia(_ x: Double?, _ y: Double?) -> (x: Double, y: Double)? {
        guard let x, let y, x.isFinite, y.isFinite else { return nil }
        let inside = { (n: Double) in min(0.999, max(0.001, n)) }
        let cx = inside(x), cy = inside(y)
        if abs(cx - cy) < 1e-6 { return nil }
        return (cx, cy)
    }

    public static func steadyViaPoint(_ viaX: Double?, _ viaY: Double?) -> (viaX: Double, viaY: Double)? {
        clampVia(viaX, viaY).map { ($0.x, $0.y) }
    }

    /// A raw point as the attribute carries it (any JSON), or an already-typed point.
    public enum RawPoint: Sendable {
        case json(JSONValue)
        case point(AutomationPoint)
        var t: JSONValue? { switch self { case let .json(j): return j["t"]; case let .point(p): return .number(p.t) } }
        var v: JSONValue? { switch self { case let .json(j): return j["v"]; case let .point(p): return .number(p.v) } }
        var curve: JSONValue? { switch self { case let .json(j): return j["curve"]; case let .point(p): return p.curve.map { .number($0) } } }
        var viaX: JSONValue? { switch self { case let .json(j): return j["viaX"]; case let .point(p): return p.viaX.map { .number($0) } } }
        var viaY: JSONValue? { switch self { case let .json(j): return j["viaY"]; case let .point(p): return p.viaY.map { .number($0) } } }
        var origin: String? {
            switch self {
            case let .json(j): if case let .string(o)? = j["origin"], !o.isEmpty { return o }; return nil
            case let .point(p): return p.origin?.isEmpty == false ? p.origin : nil
            }
        }
    }

    static func cleanPoint(_ p: RawPoint, _ range: AutomationRange?) -> AutomationPoint? {
        guard let t = numberOrNull(p.t), let v = numberOrNull(p.v) else { return nil }
        let clamped = range.map { min($0.max, max($0.min, v)) } ?? v
        let curve = clampCurve(p.curve)
        let via = clampVia(numberOrNull(p.viaX), numberOrNull(p.viaY))
        return AutomationPoint(t: max(0, t), v: clamped, curve: curve != 0 ? curve : nil, viaX: via?.x, viaY: via?.y, origin: p.origin)
    }

    static func normalizePoints(_ points: [RawPoint], _ range: AutomationRange?) -> [AutomationPoint] {
        // Array.prototype.sort is stable, as is this.
        let clean = points.compactMap { cleanPoint($0, range) }.enumerated().sorted { a, b in
            a.element.t != b.element.t ? a.element.t < b.element.t : a.offset < b.offset
        }.map(\.element)
        var out: [AutomationPoint] = []
        for p in clean {
            if let last = out.last, last.t == p.t { out[out.count - 1] = p } else { out.append(p) }
        }
        return Array(out.prefix(maxPoints))
    }

    public static func normalize(_ automation: Automation) -> Automation {
        Automation(lanes: automation.lanes.compactMap { lane in
            guard parseTarget(lane.target) != nil else { return nil }
            let pts = normalizePoints(lane.points.map { .point($0) }, lane.target == volumeTarget ? volumeRange : nil)
            return pts.isEmpty ? nil : AutomationLane(target: lane.target, points: pts)
        })
    }

    public static func resolve(_ automation: Automation, _ chain: FxChain?) -> Automation {
        Automation(lanes: automation.lanes.compactMap { lane in
            guard let range = resolveRange(lane.target, chain) else { return nil }
            let pts = normalizePoints(lane.points.map { .point($0) }, range)
            return pts.isEmpty ? nil : AutomationLane(target: lane.target, points: pts)
        })
    }

    /// `parseAutomation`.
    public static func parse(_ json: String) throws -> Automation {
        let raw: JSONValue
        do { raw = try parseJSON(json) } catch { throw AudioAutomationError(message: "Automation is not valid JSON: \(error)") }
        guard raw.isObject else { throw AudioAutomationError(message: "Automation must be a JSON object.") }
        guard raw["version"] == .number(Double(version)) else {
            throw AudioAutomationError(message: "Unsupported automation version: \(jsDisplay(raw["version"]))")
        }
        guard case let .array(items)? = raw["lanes"] else { throw AudioAutomationError(message: "Automation is missing a `lanes` array.") }
        var lanes: [(String, [RawPoint])] = []
        for (i, l) in items.enumerated() {
            guard l.isObject else { throw AudioAutomationError(message: "Lane \(i) is not an object.") }
            guard case let .string(target)? = l["target"], parseTarget(target) != nil else {
                throw AudioAutomationError(message: "Lane \(i) has an unreadable target: \(jsDisplay(l["target"]))")
            }
            guard case let .array(points)? = l["points"] else { throw AudioAutomationError(message: "Lane \(i) is missing a `points` array.") }
            lanes.append((target, points.map { .json($0) }))
        }
        return Automation(lanes: lanes.compactMap { target, points in
            let pts = normalizePoints(points, target == volumeTarget ? volumeRange : nil)
            return pts.isEmpty ? nil : AutomationLane(target: target, points: pts)
        })
    }

    public static func serialize(_ automation: Automation) -> String {
        stringifyJSON(.object([("version", .number(Double(version))), ("lanes", .array(automation.lanes.map { lane in
            .object([("target", .string(lane.target)), ("points", .array(lane.points.map { p in
                var pairs: [(String, JSONValue)] = [("t", .number(p.t)), ("v", .number(p.v))]
                if let c = p.curve, c != 0 { pairs.append(("curve", .number(c))) }
                if let x = p.viaX, let y = p.viaY { pairs.append(("viaX", .number(x))); pairs.append(("viaY", .number(y))) }
                if let o = p.origin, !o.isEmpty { pairs.append(("origin", .string(o))) }
                return .object(pairs)
            }))])
        }))]))
    }

    // MARK: shaping and sampling

    public static func applyCurve(_ x: Double, _ curve: Double?) -> Double {
        guard let curve, curve != 0, !curve.isNaN else { return x }
        return pow(x, pow(2, 2 * curve))
    }

    static func viaConic(_ viaX: Double, _ viaY: Double) -> (cx: Double, cy: Double, w: Double) {
        let dx = viaX - 0.5, dy = viaY - 0.5, edge = 0.999, maxWeight = 1e6
        let needX = dx > 0 ? dx / (edge - viaX) : dx < 0 ? -dx / (viaX - (1 - edge)) : 0
        let needY = dy > 0 ? dy / (edge - viaY) : dy < 0 ? -dy / (viaY - (1 - edge)) : 0
        let w = jsMin(maxWeight, jsMax(1, needX, needY))
        return (viaX + dx / w, viaY + dy / w, w)
    }

    static func shapeVia(_ x: Double, _ viaX: Double, _ viaY: Double) -> Double {
        let (cx, cy, w) = viaConic(viaX, viaY)
        let spread = 2 - 2 * w
        let a = x * spread - 1 + 2 * w * cx
        let b = -x * spread - 2 * w * cx
        let t = conicParam(a, b, x)
        let rest = 1 - t
        let denominator = rest * rest + 2 * w * t * rest + t * t
        if !(denominator > 0) { return x }
        return (2 * w * cy * t * rest + t * t) / denominator
    }

    static func conicParam(_ a: Double, _ b: Double, _ c: Double) -> Double {
        if abs(a) < 1e-12 { return abs(b) < 1e-12 ? c : -c / b }
        let root = (max(0, b * b - 4 * a * c)).squareRoot()
        let first = (-b + root) / (2 * a)
        let second = (-b - root) / (2 * a)
        let onArc = { (t: Double) in t >= -1e-9 && t <= 1 + 1e-9 }
        if onArc(first) { return min(1, max(0, first)) }
        if onArc(second) { return min(1, max(0, second)) }
        return c
    }

    public static func shapeProgress(_ x: Double, _ point: AutomationPoint) -> Double {
        if let via = clampVia(point.viaX, point.viaY) { return shapeVia(min(1, max(0, x)), via.x, via.y) }
        return applyCurve(x, point.curve)
    }

    static func lerpValue(_ a: Double, _ b: Double, _ x: Double, _ scale: FxScale) -> Double {
        if scale == .log && a > 0 && b > 0 { return exp(log(a) + (log(b) - log(a)) * x) }
        return a + (b - a) * x
    }

    public static func sampleLane(_ lane: AutomationLane, _ t: Double, _ scale: FxScale = .linear) -> Double {
        let pts = lane.points
        guard let first = pts.first else { return 0 }
        if t <= first.t { return first.v }
        let last = pts[pts.count - 1]
        if t >= last.t { return last.v }
        var lo = 0, hi = pts.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) >> 1
            if pts[mid].t <= t { lo = mid } else { hi = mid }
        }
        let a = pts[lo], b = pts[hi]
        let span = b.t - a.t
        if span <= 0 { return b.v }
        return lerpValue(a.v, b.v, shapeProgress((t - a.t) / span, a), scale)
    }

    public static func isConstantLane(_ lane: AutomationLane) -> Bool {
        lane.points.count <= 1 || lane.points.allSatisfy { $0.v == lane.points[0].v }
    }

    /// `sampleAutomationCurve` (Float32Array result).
    public static func sampleCurve(_ lane: AutomationLane, _ from: Double, _ to: Double, _ count: Int, _ scale: FxScale = .linear) -> [Float] {
        let n = max(2, count)
        let span = to - from
        return (0..<n).map { Float(sampleLane(lane, from + (span * Double($0)) / Double(n - 1), scale)) }
    }
}

/// `Math.max` / `Math.min` (NaN-propagating).
@inline(__always) func jsMax(_ v: Double...) -> Double { v.contains(where: \.isNaN) ? .nan : v.max()! }
@inline(__always) func jsMin(_ v: Double...) -> Double { v.contains(where: \.isNaN) ? .nan : v.min()! }
