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
// Camera moves (issue #307): a clip effect `{ effectId: "camera-moves", parameters: { v, shake?, punch?, push?, allowEdges? } }`
// that shakes, punches in and pushes the layer as a pure function of the clip frame and the seed.
import Foundation

public enum NativeCameraMoves {
    public static let effectId = "camera-moves"
    public static let currentVersion = 1
    /// Shake frequency limit in Hz: the highest component is under twice the set frequency, which stays below Nyquist at 24 fps.
    public static let maxShakeFrequency = 5.0
}

public struct NativeCameraShake: Equatable, Sendable {
    /// Peak offset in canvas px (0 = exactly no motion).
    public var amount = 8.0
    /// The set frequency in Hz; no component is faster than twice this.
    public var frequency = 2.0
    /// Peak rotation in degrees.
    public var rotation = 0.0
    public var seed = 0
    public init(amount: Double = 8, frequency: Double = 2, rotation: Double = 0, seed: Int = 0) {
        self.amount = amount; self.frequency = frequency; self.rotation = rotation; self.seed = seed
    }
}

public struct NativeCameraPunch: Equatable, Sendable {
    /// Scale reached at each trigger (1.0 to 1.5); it eases back to 1 over `lengthFrames`.
    public var scale = 1.2
    public var lengthFrames = 6
    public var ease: NativeInterpolation? = nil
    /// Clip-relative trigger frames.
    public var at: [Int] = []
    /// A trigger every N frames from the clip start.
    public var everyFrames: Int? = nil
    public init(scale: Double = 1.2, lengthFrames: Int = 6, ease: NativeInterpolation? = nil, at: [Int] = [], everyFrames: Int? = nil) {
        self.scale = scale; self.lengthFrames = lengthFrames; self.ease = ease; self.at = at; self.everyFrames = everyFrames
    }
    public var resolvedEase: NativeInterpolation { ease ?? NativeMoveEase.easeOut }
}

public struct NativeCameraPush: Equatable, Sendable {
    public var startScale = 1.0
    public var endScale = 1.1
    public var ease: NativeInterpolation? = nil
    /// The way the picture drifts while it pushes.
    public var direction: NativeMoveDirection = .right
    /// Total drift over the clip, percent of the canvas side (0 = none).
    public var drift = 0.0
    public init(startScale: Double = 1, endScale: Double = 1.1, ease: NativeInterpolation? = nil, direction: NativeMoveDirection = .right, drift: Double = 0) {
        self.startScale = startScale; self.endScale = endScale; self.ease = ease; self.direction = direction; self.drift = drift
    }
    public var resolvedEase: NativeInterpolation { ease ?? .linear }
}

/// The parameters of one camera-moves effect as stored: unknown versions stay in the document and are not drawn.
public struct NativeCameraMovesParameters: Equatable, Sendable {
    public var stored: NativeJSONObject
    public init(_ stored: NativeJSONObject) { self.stored = stored }
    public init?(_ effect: NativeClipEffect) {
        guard effect.effectId == NativeCameraMoves.effectId, let p = effect.parameters else { return nil }
        stored = p
    }

    static func versionIsCurrent(_ v: NativeJSONValue?) -> Bool { v?["v"]?.numberValue == Double(NativeCameraMoves.currentVersion) }
    public var isCurrentVersion: Bool { Self.versionIsCurrent(.object(stored)) }
    /// Every stored section can be drawn: current version throughout.
    public var isReadable: Bool {
        isCurrentVersion && ["shake", "punch", "push"].allSatisfy { stored[$0] == nil || Self.versionIsCurrent(stored[$0]) }
    }
    public var allowEdges: Bool { stored["allowEdges"]?.boolValue ?? false }

    private func section(_ key: String) -> NativeJSONValue? { isCurrentVersion && Self.versionIsCurrent(stored[key]) ? stored[key] : nil }

    public var shake: NativeCameraShake? {
        guard let j = section("shake") else { return nil }
        let d = NativeCameraShake()
        return NativeCameraShake(amount: j["amount"]?.numberValue ?? d.amount, frequency: j["frequency"]?.numberValue ?? d.frequency,
                                 rotation: j["rotation"]?.numberValue ?? d.rotation, seed: nativeMoveInteger(j["seed"]) ?? d.seed)
    }
    public var punch: NativeCameraPunch? {
        guard let j = section("punch") else { return nil }
        let d = NativeCameraPunch()
        return NativeCameraPunch(scale: j["scale"]?.numberValue ?? d.scale, lengthFrames: nativeMoveInteger(j["lengthFrames"]) ?? d.lengthFrames,
                                 ease: j["ease"].flatMap(nativeMoveInterpolation),
                                 at: (j["at"]?.arrayValue ?? []).compactMap { nativeMoveInteger($0) }, everyFrames: nativeMoveInteger(j["everyFrames"]))
    }
    public var push: NativeCameraPush? {
        guard let j = section("push") else { return nil }
        let d = NativeCameraPush()
        return NativeCameraPush(startScale: j["startScale"]?.numberValue ?? d.startScale, endScale: j["endScale"]?.numberValue ?? d.endScale,
                                ease: j["ease"].flatMap(nativeMoveInterpolation),
                                direction: j["direction"]?.stringValue.flatMap(NativeMoveDirection.init(rawValue:)) ?? d.direction,
                                drift: j["drift"]?.numberValue ?? d.drift)
    }
}

public extension NativeProjectClip {
    /// The first enabled camera-moves effect the build can draw.
    var cameraMoves: NativeCameraMovesParameters? {
        for e in effects where e.enabled { if let p = NativeCameraMovesParameters(e), p.isReadable { return p } }
        return nil
    }
}

public extension NativeProjectDocument {
    /// Enabled camera-moves effects kept but not drawn: a version from a newer editor.
    var unreadableCameraMovesCount: Int {
        sequence.tracks.flatMap(\.clips).flatMap(\.effects).filter { e in
            e.enabled && (NativeCameraMovesParameters(e).map { !$0.isReadable } ?? false)
        }.count
    }

    /// The one notice shown on open when some camera moves cannot be drawn.
    var unreadableCameraMovesNotice: String? {
        let n = unreadableCameraMovesCount
        guard n > 0 else { return nil }
        return n == 1
            ? "1 camera move from a newer version of the editor is kept in the project but not drawn in preview or export."
            : "\(n) camera moves from a newer version of the editor are kept in the project but not drawn in preview or export."
    }
}

// MARK: Evaluation

/// SplitMix64: integer-only, the same stream on every platform.
struct NativeSplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// 0 up to (not including) 1, from the top 53 bits.
    mutating func unit() -> Double { Double(next() >> 11) / 9_007_199_254_740_992 }
}

extension NativeCameraShake {
    /// Three seeded sines per channel (x, y, rotation); each is at 0.5 to 1.6 times the set frequency, so the offsets are
    /// band-limited below twice `frequency`. Weights sum to 1, so each channel stays within -1 ... 1 (times its amount).
    static let weights = [0.5, 0.3, 0.2]
    static let baseRatios = [0.6, 1.0, 1.5]

    /// (x, y, rotation), each within -1 ... 1, at `seconds`.
    func unitSample(atSeconds seconds: Double) -> (Double, Double, Double) {
        var rng = NativeSplitMix64(state: UInt64(truncatingIfNeeded: seed) &* 0xD1B5_4A32_D192_ED03 &+ 0x2545_F491_4F6C_DD1D)
        var out = [0.0, 0.0, 0.0]
        for channel in 0..<3 {
            for i in 0..<3 {
                let ratio = Self.baseRatios[i] + (rng.unit() - 0.5) * 0.2
                let phase = rng.unit() * 2 * Double.pi
                out[channel] += Self.weights[i] * sin(2 * Double.pi * frequency * ratio * seconds + phase)
            }
        }
        return (out[0], out[1], out[2])
    }

    /// The shake at `seconds` of the clip: exactly identity when `amount` and `rotation` are 0.
    public func offsets(atSeconds seconds: Double) -> NativeMoveOffsets {
        guard amount != 0 || rotation != 0 else { return .identity }
        let s = unitSample(atSeconds: seconds)
        return NativeMoveOffsets(dx: amount * s.0, dy: amount * s.1, rotation: rotation * s.2)
    }
}

extension NativeCameraPunch {
    /// The latest trigger at or before `f`, nil before the first.
    func lastTrigger(atOrBefore f: Int) -> Int? {
        var best = at.filter { $0 >= 0 && $0 <= f }.max()
        if let n = everyFrames, n > 0, f >= 0 { best = max(best ?? 0, (f / n) * n) }
        return best
    }

    public func scale(clipFrame f: Int, engine: KeyframeEngine) throws -> Double {
        guard let t = lastTrigger(atOrBefore: f), f - t < lengthFrames else { return 1 }
        let e = try nativeMoveEasedProgress(resolvedEase, frame: f - t, span: lengthFrames, engine: engine)
        return 1 + (scale - 1) * (1 - e)
    }
}

extension NativeCameraPush {
    public func offsets(clipFrame f: Int, duration: Int, canvas: NativeCanvas, engine: KeyframeEngine) throws -> NativeMoveOffsets {
        let span = max(1, duration - 1)
        let e = try nativeMoveEasedProgress(resolvedEase, frame: max(0, min(span, f)), span: span, engine: engine)
        var o = NativeMoveOffsets(scale: startScale + (endScale - startScale) * e)
        let d = drift / 100 * e
        switch direction {
        case .left: o.dx = -d * canvas.width
        case .right: o.dx = d * canvas.width
        case .up: o.dy = -d * canvas.height
        case .down: o.dy = d * canvas.height
        }
        return o
    }
}

extension NativeCameraMovesParameters {
    /// The constant scale that keeps a `width` x `height` layer's edges off the picture at every frame: the shake's
    /// largest offset and rotation, the push's drift and any push below 1 (conservative: later zoom is not credited).
    /// 1 with "Allow edges", or when nothing can reveal an edge.
    public func coverScale(width: Double, height: Double, canvas: NativeCanvas) -> Double {
        guard !allowEdges, width > 0, height > 0 else { return 1 }
        let shake = self.shake, push = self.push
        let theta = abs(shake?.rotation ?? 0) * Double.pi / 180
        let drift = (push?.drift ?? 0) / 100
        let ax = abs(shake?.amount ?? 0) + drift * canvas.width, ay = abs(shake?.amount ?? 0) + drift * canvas.height
        let c = cos(theta), s = sin(theta)
        let needX = c + height / width * s + 2 * ax * (c + s) / width
        let needY = c + width / height * s + 2 * ay * (c + s) / height
        let low = min(1, push?.startScale ?? 1, push?.endScale ?? 1)
        return max(1, needX, needY) / max(low, 1e-6)
    }

    /// What the effect adds to a layer of `width` x `height` at `clipFrame` of a `duration`-frame clip at `fps`.
    public func offsets(clipFrame f: Int, duration: Int, fps: Double, canvas: NativeCanvas, width: Double, height: Double,
                        engine: KeyframeEngine) throws -> NativeMoveOffsets {
        var out = NativeMoveOffsets.identity
        if let shake { out = out.combined(with: shake.offsets(atSeconds: Double(f) / fps)) }
        if let punch { out = out.combined(with: NativeMoveOffsets(scale: try punch.scale(clipFrame: f, engine: engine))) }
        if let push { out = out.combined(with: try push.offsets(clipFrame: f, duration: duration, canvas: canvas, engine: engine)) }
        let cover = coverScale(width: width, height: height, canvas: canvas)
        return cover == 1 ? out : out.combined(with: NativeMoveOffsets(scale: cover))
    }
}
