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

public enum NativeGridLayout: String, CaseIterable, Sendable {
    case sideBySide, stacked, threeUp, grid2x2, largeLeft, pictureInPicture
}
public enum NativeGridCorner: String, CaseIterable, Sendable { case topLeft, topRight, bottomLeft, bottomRight }

public struct NativeGridOptions: Equatable, Sendable {
    public var gutter: Double, margin: Double, pipWidthFraction: Double
    public var corner: NativeGridCorner
    public var fit: NativeMediaFit
    public init(gutter: Double = 0, margin: Double = 0, pipWidthFraction: Double = 0.3,
                corner: NativeGridCorner = .bottomRight, fit: NativeMediaFit = .fit) {
        self.gutter = gutter; self.margin = margin; self.pipWidthFraction = pipWidthFraction
        self.corner = corner; self.fit = fit
    }
}

public enum NativeGridFailure: Error, Equatable {
    case invalidGeometry, emptySelection, tooManyLayers(selected: Int, cells: Int)
    case duplicateClip(String), unavailableClip(String), lockedTrack(String), nonVisualClip(String), invalidFrame
    case rejected(String)
}

/// Composition-pixel cells in selection order (row-major for 2x2, background then inset for PiP).
/// Reject impossible dimensions rather than silently clamping a gutter, margin or inset size.
public func nativeGridCells(_ layout: NativeGridLayout, width: Double, height: Double,
                            options o: NativeGridOptions = .init()) throws -> [NativeClipLayoutBox] {
    guard width.isFinite, height.isFinite, width > 0, height > 0,
          o.gutter.isFinite, o.margin.isFinite, o.gutter >= 0, o.margin >= 0,
          o.pipWidthFraction.isFinite, o.pipWidthFraction > 0, o.pipWidthFraction < 1 else {
        throw NativeGridFailure.invalidGeometry
    }
    let w = width - 2 * o.margin, h = height - 2 * o.margin, g = o.gutter, m = o.margin
    guard w > 0, h > 0 else { throw NativeGridFailure.invalidGeometry }
    func box(_ x: Double, _ y: Double, _ a: Double, _ b: Double) -> NativeClipLayoutBox {
        .init(left: m + x, top: m + y, width: a, height: b)
    }
    let cells: [NativeClipLayoutBox]
    switch layout {
    case .sideBySide, .threeUp:
        let n = layout == .threeUp ? 3 : 2
        let a = (w - Double(n - 1) * g) / Double(n)
        cells = (0..<n).map { box(Double($0) * (a + g), 0, a, h) }
    case .stacked:
        let b = (h - g) / 2
        cells = [box(0, 0, w, b), box(0, b + g, w, b)]
    case .grid2x2:
        let a = (w - g) / 2, b = (h - g) / 2
        cells = [box(0, 0, a, b), box(a + g, 0, a, b), box(0, b + g, a, b), box(a + g, b + g, a, b)]
    case .largeLeft:
        let a = (w - g) * 2 / 3, b = (h - g) / 2, small = (w - g) / 3
        cells = [box(0, 0, a, h), box(a + g, 0, small, b), box(a + g, b + g, small, b)]
    case .pictureInPicture:
        let a = width * o.pipWidthFraction, b = a * (height / width)
        guard a <= w, b <= h else { throw NativeGridFailure.invalidGeometry }
        let right = o.corner == .topRight || o.corner == .bottomRight
        let bottom = o.corner == .bottomLeft || o.corner == .bottomRight
        cells = [box(0, 0, w, h), box(right ? w - a : 0, bottom ? h - b : 0, a, b)]
    }
    guard cells.allSatisfy({ $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 }) else {
        throw NativeGridFailure.invalidGeometry
    }
    return cells
}

/// Produce one validated snapshot for one undo step; input remains unchanged on every refusal.
/// Existing animated geometry gets a key at the playhead, while unanimated geometry stays static.
public func planNativeGridLayout(_ document: NativeProjectDocument, clipIds: [String], layout: NativeGridLayout,
                                 frame: Double, options: NativeGridOptions = .init(),
                                 engine: KeyframeEngine? = nil) throws -> NativeProjectDocument {
    let cells = try nativeGridCells(layout, width: document.canvas.width, height: document.canvas.height, options: options)
    guard !clipIds.isEmpty else { throw NativeGridFailure.emptySelection }
    guard clipIds.count <= cells.count else { throw NativeGridFailure.tooManyLayers(selected: clipIds.count, cells: cells.count) }
    guard frame.isFinite, frame >= 0, frame.rounded(.down) == frame else { throw NativeGridFailure.invalidFrame }
    var seen = Set<String>(), next = document
    var commands: [NativeProjectAtomicPropertyCommand] = []
    for (id, cell) in zip(clipIds, cells) {
        guard seen.insert(id).inserted else { throw NativeGridFailure.duplicateClip(id) }
        let matches = document.sequence.tracks.enumerated().flatMap { t, track in
            track.clips.enumerated().filter { $0.element.id == id }.map { (t, $0.offset) }
        }
        guard matches.count == 1, let (t, i) = matches.first else { throw NativeGridFailure.unavailableClip(id) }
        let track = document.sequence.tracks[t], original = track.clips[i]
        guard track.locked != true else { throw NativeGridFailure.lockedTrack(track.id) }
        guard let asset = document.assets.first(where: { $0.id == original.assetId }), asset.kind != .audio else {
            throw NativeGridFailure.nonVisualClip(id)
        }
        guard frame >= original.startFrame, frame < original.startFrame + original.durationFrames else {
            throw NativeGridFailure.invalidFrame
        }
        var clip = original, values: [(String, NativeParameterValue)] = [
            ("layout.left", .number(cell.left)), ("layout.top", .number(cell.top)),
            ("layout.width", .number(cell.width)), ("layout.height", .number(cell.height)),
            ("transform.position", .vec2(.init(x: 0, y: 0))), ("transform.rotation", .number(0))]
        // Only reset optional transform overrides that the clip actually carries; preserve unrelated fields.
        for pid in ["transform.position.x", "transform.position.y", "transform.scale", "transform.scaleX", "transform.scaleY"] + NativeTransform3D.parameterIds {
            let animated = original.parameterTracks.first { $0.parameterId == pid && !$0.keyframes.isEmpty }
            guard animated != nil || original.staticParameters?[pid] != nil else { continue }
            let scale = pid.hasPrefix("transform.scale")
            let vecScale = pid == "transform.scale" && (animated?.valueType == .vec2 || {
                if case .vec2? = original.staticParameters?[pid] { return true }; return false
            }())
            values.append((pid, vecScale ? .vec2(.init(x: 1, y: 1)) : .number(scale ? 1 : 0)))
        }
        var statics = clip.staticParameters ?? [:]
        for (pid, value) in values {
            if let animated = original.parameterTracks.first(where: { $0.parameterId == pid && !$0.keyframes.isEmpty }) {
                let address = NativeProjectParameterAddress(sequenceId: document.sequence.id, trackId: track.id, clipId: id, parameterId: pid)
                commands.append(.keyframe(.upsert(address: address, valueType: animated.valueType,
                    frame: frame - original.startFrame, value: value, baselineValue: statics[pid] ?? value)))
            } else { statics[pid] = value }
        }
        clip.staticParameters = statics; clip.crop = nil; clip.cropPivotSegments = nil; clip.fit = options.fit
        for k in clip.parameterTracks.indices where clip.parameterTracks[k].parameterId == "transform.position" {
            clip.parameterTracks[k].autoRotate = false
        }
        next.sequence.tracks[t].clips[i] = clip
    }
    if !commands.isEmpty {
        switch try applyNativeProjectPropertyCommand(next, .batch(commands), engine: engine) {
        case .success(let updated): next = updated
        case .failure(_, let failure): throw NativeGridFailure.rejected(failure.message)
        }
    }
    return try parseNativeProjectDocument(next, engine: engine)
}
