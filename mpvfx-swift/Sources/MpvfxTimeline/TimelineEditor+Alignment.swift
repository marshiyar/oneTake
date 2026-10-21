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

public enum TimelineAlignment: String, CaseIterable, Sendable {
    case left, centre, right, top, middle, bottom
}
public enum TimelineAlignmentReference: String, Sendable { case frame, selection }
public enum TimelineDistribution: String, Sendable { case horizontal, vertical }

public extension TimelineEditor {
    /// The transformed layout box at the playhead, in composition pixels. Crop, per-axis scale, 3D projection,
    /// path auto-rotation and layer moves use the same primitives and value precedence as the shared painter.
    func alignmentBounds(clipId: String, time: Double) -> CanvasRect? {
        guard time.isFinite, let (_, c) = clip(clipId),
              let asset = document.assets.first(where: { $0.id == c.assetId }),
              asset.kind == .video || asset.kind == .image || asset.kind == .element else { return nil }
        func number(_ id: String, _ fallback: Double) -> Double {
            if case .number(let n)? = parameterValue(clipId: clipId, parameterId: id, time: time) { return n }
            return fallback
        }
        let position = arrangementPosition(clipId, time: time)
        let origin = layoutOrigin(clipId: clipId, time: time)
        let width = number(Self.widthId, document.canvas.width), height = number(Self.heightId, document.canvas.height)
        var sx = 1.0, sy = 1.0
        switch parameterValue(clipId: clipId, parameterId: Self.scaleId, time: time) {
        case .number(let n)?: sx = n; sy = n
        case .vec2(let v)?: sx = v.x; sy = v.y
        default: break
        }
        sx = number("transform.scaleX", sx); sy = number("transform.scaleY", sy)
        var rotation = number(Self.rotationId, 0)
        if let track = c.parameterTracks.first(where: { $0.parameterId == Self.positionId && $0.autoRotate == true }),
           let eng = engine ?? (try? keyframeEngine()), let frame = localFrame(clipId: clipId, time: time),
           let angle = try? eng.tangentAngle(KeyframeTrack(track), frame: frame), angle.isFinite {
            rotation += angle * 180 / .pi
        }
        let frame = Int(localFrame(clipId: clipId, time: time) ?? 0)
        let move = (try? nativeClipMoveOffsets(c, clipFrame: frame, canvas: document.canvas, engine: engine)) ?? .identity
        let projection = NativeTransform3D(rotationX: number(NativeTransform3D.rotationXId, 0),
            rotationY: number(NativeTransform3D.rotationYId, 0), z: number(NativeTransform3D.zId, 0),
            perspective: number(NativeTransform3D.perspectiveId, 0))
        let cx = origin.x + position.x + width / 2 + move.dx
        let cy = origin.y + position.y + height / 2 + move.dy
        let crop = c.crop
        let left = max(0, crop?.left ?? 0), right = width - max(0, crop?.right ?? 0)
        let top = max(0, crop?.top ?? 0), bottom = height - max(0, crop?.bottom ?? 0)
        guard width > 0, height > 0, right > left, bottom > top else { return nil }
        let points = [(left, top), (right, top), (right, bottom), (left, bottom)].map { x, y in
            let p = projection.project(x - width / 2, y - height / 2,
                                       scaleX: sx * move.scale, scaleY: sy * move.scale, rotation: rotation + move.rotation)
            return CanvasPoint(cx + p.x, cy + p.y)
        }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let x = xs.min(), let x1 = xs.max(), let y = ys.min(), let y1 = ys.max(), x1 > x, y1 > y else { return nil }
        return CanvasRect(x: x, y: y, width: x1 - x, height: y1 - y)
    }

    /// All selected clips must be visual, present and unlocked; an invalid selection never causes a partial edit.
    func canArrangeClips(_ ids: Set<String>, time: Double) -> Bool {
        arrangementBoxes(ids, time: time) != nil
    }

    @discardableResult
    func alignClips(_ ids: Set<String>, to alignment: TimelineAlignment,
                    relativeTo reference: TimelineAlignmentReference = .frame, time: Double) -> Bool {
        guard let boxes = arrangementBoxes(ids, time: time) else { return false }
        let target = reference == .frame
            ? CanvasRect(x: 0, y: 0, width: document.canvas.width, height: document.canvas.height)
            : arrangementUnion(boxes.map(\.box))
        let moves = boxes.map { item -> (String, Double, Double) in
            let b = item.box
            switch alignment {
            case .left: return (item.id, target.x - b.x, 0)
            case .centre: return (item.id, (target.x + target.width / 2) - (b.x + b.width / 2), 0)
            case .right: return (item.id, target.maxX - b.maxX, 0)
            case .top: return (item.id, 0, target.y - b.y)
            case .middle: return (item.id, 0, (target.y + target.height / 2) - (b.y + b.height / 2))
            case .bottom: return (item.id, 0, target.maxY - b.maxY)
            }
        }
        return applyArrangement(moves, time: time, label: "Align clips")
    }

    /// Equal edge-to-edge gaps, keeping the first and last boxes in centre order anchored.
    /// Negative gaps are allowed when boxes overlap; equal centres use clip IDs as a stable tie-breaker.
    @discardableResult
    func distributeClips(_ ids: Set<String>, along axis: TimelineDistribution, time: Double) -> Bool {
        guard var boxes = arrangementBoxes(ids, time: time), boxes.count >= 3 else { return false }
        let horizontal = axis == .horizontal
        boxes.sort { a, b in
            let av = horizontal ? (a.box.x + a.box.width / 2) : (a.box.y + a.box.height / 2), bv = horizontal ? (b.box.x + b.box.width / 2) : (b.box.y + b.box.height / 2)
            return av == bv ? a.id < b.id : av < bv
        }
        let first = boxes[0].box, last = boxes[boxes.count - 1].box
        let extent = horizontal ? last.maxX - first.x : last.maxY - first.y
        let occupied = boxes.reduce(0.0) { $0 + (horizontal ? $1.box.width : $1.box.height) }
        let gap = (extent - occupied) / Double(boxes.count - 1)
        var cursor = horizontal ? first.x : first.y
        var moves: [(String, Double, Double)] = []
        for item in boxes {
            let delta = cursor - (horizontal ? item.box.x : item.box.y)
            moves.append((item.id, horizontal ? delta : 0, horizontal ? 0 : delta))
            cursor += (horizontal ? item.box.width : item.box.height) + gap
        }
        return applyArrangement(moves, time: time, label: "Distribute clips")
    }
}

private extension TimelineEditor {
    func arrangementBoxes(_ ids: Set<String>, time: Double) -> [(id: String, box: CanvasRect)]? {
        guard !ids.isEmpty, time.isFinite else { return nil }
        var boxes: [(String, CanvasRect)] = []
        for id in ids.sorted() {
            guard !isClipLocked(id), let box = alignmentBounds(clipId: id, time: time) else { return nil }
            boxes.append((id, box))
        }
        return boxes
    }

    func arrangementUnion(_ boxes: [CanvasRect]) -> CanvasRect {
        let x = boxes.map(\.x).min() ?? 0, y = boxes.map(\.y).min() ?? 0
        return CanvasRect(x: x, y: y, width: (boxes.map(\.maxX).max() ?? x) - x,
                          height: (boxes.map(\.maxY).max() ?? y) - y)
    }

    func arrangementPosition(_ id: String, time: Double) -> Vec2Value {
        var p = Vec2Value(x: 0, y: 0)
        if case .vec2(let v)? = parameterValue(clipId: id, parameterId: Self.positionId, time: time) { p = v }
        if case .number(let x)? = parameterValue(clipId: id, parameterId: POSITION_X_PARAMETER_ID, time: time) { p.x = x }
        if case .number(let y)? = parameterValue(clipId: id, parameterId: POSITION_Y_PARAMETER_ID, time: time) { p.y = y }
        return p
    }

    func applyArrangement(_ moves: [(String, Double, Double)], time: Double, label: String) -> Bool {
        var commands: [NativeProjectAtomicPropertyCommand] = []
        for (id, dx, dy) in moves where abs(dx) > 1e-9 || abs(dy) > 1e-9 {
            guard let (track, c) = clip(id), let frame = localFrame(clipId: id, time: time) else { return false }
            let current = arrangementPosition(id, time: time), next = Vec2Value(x: current.x + dx, y: current.y + dy)
            func put(_ pid: String, _ type: NativeValueType, _ value: NativeParameterValue, _ baseline: NativeParameterValue) {
                let address = NativeProjectParameterAddress(sequenceId: sequenceId, trackId: track.id, clipId: id, parameterId: pid)
                if c.parameterTracks.contains(where: { $0.parameterId == pid && !$0.keyframes.isEmpty }) {
                    commands.append(.keyframe(.upsert(address: address, valueType: type, frame: frame, value: value,
                        baselineValue: c.staticParameters?[pid] ?? baseline)))
                } else { commands.append(.setStatic(address: address, value: value)) }
            }
            put(Self.positionId, .vec2, .vec2(next), .vec2(current))
            for (pid, value, baseline) in [(POSITION_X_PARAMETER_ID, next.x, current.x), (POSITION_Y_PARAMETER_ID, next.y, current.y)]
            where parameterValue(clipId: id, parameterId: pid, time: time) != nil {
                put(pid, .number, .number(value), .number(baseline))
            }
        }
        guard !commands.isEmpty else { return false }
        return withHistory(label) { applyProperty(.batch(commands)) }
    }
}
