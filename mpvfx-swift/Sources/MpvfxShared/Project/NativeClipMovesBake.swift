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
// Convert moves using the same evaluator as preview/export. Sparse keys retain the move's ease; where
// overlapping motion or existing animation cannot be represented by those segments, sample each project frame.
import Foundation

public func bakeNativeClipMoves(_ clip: NativeProjectClip, canvas: NativeCanvas, frameRate: RationalFrameRate,
                                engine: KeyframeEngine) throws -> NativeProjectClip {
    guard let moves = clip.moves, !moves.isEmpty else { return clip }
    guard moves.isReadable else {
        throw NativeKeyframeEvaluationError(message: "These moves are from a newer version and cannot be converted")
    }
    let count = Int(clip.durationFrames)
    guard count > 0 else { return clip }
    let samples = try (0..<count).map { frame in
        try NativeMoveBakeSample(clip, frame: frame, canvas: canvas, engine: engine)
    }
    var result = clip
    for axis in 0..<6 where samples.contains(where: { $0.changed[axis] }) {
        let id = NativeMoveBakeSample.ids[axis]
        let original = clip.parameterTracks.first { $0.parameterId == id }
        var track = original ?? NativeParameterTrack(id: UUID().uuidString, parameterId: id, valueType: .number,
                                                     frameRate: frameRate, keyframes: [])
        var times = Set([0, count - 1])
        if let m = moves.inMove { times.insert(min(count - 1, m.frames)) }
        if let m = moves.outMove { times.insert(max(0, count - 1 - m.frames)) }
        if let m = moves.loop {
            times.formUnion(stride(from: 0, to: count, by: max(1, m.periodFrames / 2)))
        }
        // Retain every existing key time, including keys on the vector/alias tracks left intact beneath the bake.
        for t in clip.parameterTracks {
            times.formUnion(t.keyframes.map { Int($0.frame) }.filter { $0 >= 0 && $0 < count })
        }
        func keys(_ dense: Bool) -> [NativeKeyframe] {
            var frames = times
            if dense { frames.formUnion(0..<count) }
            var keys = original?.keyframes.filter { $0.frame < 0 || $0.frame >= Double(count) } ?? []
            for frame in frames.sorted() {
                var key = original?.keyframes.first { $0.frame == Double(frame) }
                    ?? NativeKeyframe(id: UUID().uuidString, frame: Double(frame), value: .number(0), outgoing: .linear)
                key.value = .number(samples[frame].values[axis])
                key.outgoing = dense ? .linear : nativeMoveBakeEase(moves, frame: frame, count: count)
                key.outgoingPath = nil
                keys.append(key)
            }
            return keys.sorted { $0.frame < $1.frame }
        }
        track.keyframes = keys(false)
        var matches = true
        for frame in 0..<count {
            guard case .number(let value) = try evaluateNativeParameterTrack(track, projectFrame: Double(frame), engine: engine),
                  abs(value - samples[frame].values[axis]) <= 1e-9 else { matches = false; break }
        }
        if !matches { track.keyframes = keys(true) }
        if let i = result.parameterTracks.firstIndex(where: { $0.parameterId == id }) { result.parameterTracks[i] = track }
        else { result.parameterTracks.append(track) }
    }
    result.moves = nil
    return result
}

private func nativeMoveBakeEase(_ moves: NativeClipMoves, frame: Int, count: Int) -> NativeInterpolation {
    if let m = moves.inMove, frame < m.frames { return m.resolvedEase(.in) }
    if let m = moves.outMove, frame >= count - 1 - m.frames { return m.resolvedEase(.out) }
    return moves.loop?.resolvedEase ?? .linear
}

private struct NativeMoveBakeSample {
    static let ids = ["transform.position.x", "transform.position.y", "transform.scaleX", "transform.scaleY",
                      "transform.rotation", "transform.opacity"]
    var values: [Double]
    var changed: [Bool]

    init(_ clip: NativeProjectClip, frame: Int, canvas: NativeCanvas, engine: KeyframeEngine) throws {
        var parameters: [String: NativeParameterValue] = [:]
        if let statics = clip.staticParameters { for id in statics.keys { parameters[id] = statics[id] } }
        for t in clip.parameterTracks where !t.keyframes.isEmpty {
            parameters[t.parameterId] = try evaluateNativeParameterTrack(t, projectFrame: Double(frame), engine: engine)
        }
        func number(_ id: String) -> Double? {
            if case .number(let value)? = parameters[id] { return value }; return nil
        }
        func vector(_ id: String) -> Vec2Value? {
            if case .vec2(let value)? = parameters[id] { return value }; return nil
        }
        let p = vector("transform.position"), s = vector("transform.scale"), uniform = number("transform.scale")
        let o = try nativeClipMoveOffsets(clip, clipFrame: frame, canvas: canvas, engine: engine)
        let opacity = max(0, min(1, number("transform.opacity") ?? number("visual.opacity") ?? number("visual.autoAlpha") ?? 1))
        values = [(number(Self.ids[0]) ?? p?.x ?? 0) + o.dx,
                  (number(Self.ids[1]) ?? p?.y ?? 0) + o.dy,
                  (number(Self.ids[2]) ?? uniform ?? s?.x ?? 1) * o.scale,
                  (number(Self.ids[3]) ?? uniform ?? s?.y ?? 1) * o.scale,
                  (number(Self.ids[4]) ?? 0) + o.rotation, opacity * o.opacity]
        changed = [o.dx != 0, o.dy != 0, o.scale != 1, o.scale != 1, o.rotation != 0, o.opacity != 1]
    }
}
