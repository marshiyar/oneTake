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
import OneTakeMedia
import MpvfxShared

/// Paints export frames: the preview's own composition (`PreviewComposition.layers(at:)`), grading
/// (`PreviewGrader.gradeNow`) and painter (`PreviewPainter`) on the engine's raster canvas at the output size.
/// The project canvas is fitted into the output and centred; the margin is `pad` (black, or clear for alpha exports).
public final class ExportFramePainter {
    /// Supplies the decoded, ungraded picture of a layer at a source time, at about `width` × `height` pixels.
    public typealias FrameProvider = (_ layer: PreviewLayer, _ sourceTime: Double, _ width: Int, _ height: Int) -> CanvasImage?

    public let composition: PreviewComposition
    public let width: Int, height: Int
    public let pad: CanvasColor
    private let canvas: RasterCanvas
    private let grader: PreviewGrader
    /// false paints the pad, then the background over it, even where the background covers the whole output (the
    /// reference the one-pass background is checked against).
    var singlePassBackground = true

    public init(composition: PreviewComposition, width: Int, height: Int, pad: CanvasColor) throws {
        self.composition = composition; self.width = width; self.height = height; self.pad = pad
        canvas = try RasterCanvas(width: width, height: height)
        grader = PreviewGrader(pressure: nil)
    }

    /// Where the project canvas lands in the output: contained and centred (`scale` output px per canvas px).
    public var frame: (rect: CanvasRect, scale: Double) {
        let cw = max(composition.canvas.width, 1), ch = max(composition.canvas.height, 1)
        let s = min(Double(width) / cw, Double(height) / ch)
        let w = cw * s, h = ch * s
        return (CanvasRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h), s)
    }

    /// The project canvas lands on the whole output, edge to edge in whole pixels (no pad shows).
    func fillsTheOutput(_ rect: CanvasRect) -> Bool {
        rect.x == 0 && rect.y == 0 && rect.width == Double(width) && rect.height == Double(height)
    }

    /// The layers visible at `time`, with the output pixel size each one is drawn at (what to decode).
    public func layers(at time: Double) -> [(layer: PreviewLayer, width: Int, height: Int)] {
        Self.layers(composition, at: time, scale: frame.scale)
    }

    /// The layers of `composition` visible at `time`, with the pixel size each one is drawn at when the project canvas
    /// is painted at `scale` output pixels per canvas pixel.
    public static func layers(_ composition: PreviewComposition, at time: Double,
                              scale s: Double) -> [(layer: PreviewLayer, width: Int, height: Int)] {
        // Offline layers are never exported: startExport refuses missing media before it renders.
        composition.layers(at: time).filter { $0.isVisible && $0.kind != .offline }.map { layer in
            // The stage's decode size rule (whole even pixels, rounded up): a scaled layer decodes to the same
            // picture as in preview, so its letterbox bars, if any, are the same too. No cap: exports above 4K keep
            // full resolution.
            let size = PreviewDecodeSize.fitting(PreviewPainter.screenPixels(layer, viewScale: s, backingScale: 1), maxSide: Int.max)
            return (layer, size.width, size.height)
        }
    }

    /// One output frame as straight-alpha RGBA8 (`width` × `height` × 4 bytes); throws the first drawing failure.
    public func paint(time: Double, frames: FrameProvider) throws -> CanvasImage {
        try paint(layers(at: time), time: time, frames: frames)
    }

    /// `paint(time:frames:)` with the layers already resolved by `layers(at:)`: a caller can resolve them on one
    /// thread and paint on another (the program scopes, `ProgramScopeRenderer`), and both paint the same pixels.
    public func paint(_ layers: [(layer: PreviewLayer, width: Int, height: Int)], time: Double,
                      frames: FrameProvider) throws -> CanvasImage {
        let (rect, s) = frame
        if singlePassBackground && fillsTheOutput(rect) && composition.background.a >= 1 {
            // The opaque background covers every pixel the pad would: one pass instead of two over the frame (about
            // 13 of 115 ms per 1080p frame, issue #98), with the same bytes (ExportFramePainterTests).
            canvas.clear(composition.background)
        } else {
            canvas.clear(pad)
            canvas.fillRect(rect, composition.background)
        }
        let frameIndex = composition.frameIndex(at: time)
        for (layer, w, h) in layers {
            if layer.kind == .text {
                PreviewPainter.drawText(layer, on: canvas, frame: rect, scale: s)
                continue
            }
            guard var image = frames(layer, layer.sourceTime(at: time), w, h) else { continue }
            // Grades animate on the timeline frame, as in the preview (PreviewCompositor.shownImage).
            if let g = layer.grade, g.isActive {
                image = grader.gradeNow(image, grade: g, time: Double(frameIndex) / composition.fps)
            }
            PreviewPainter.draw(layer, image: image, on: canvas, frame: rect, scale: s)
        }
        if let e = canvas.drawError { throw e }
        return canvas.image()
    }
}

/// A layer export could not decode: the clip and the engine's reason, shown to the user as the export's failure.
public struct ExportFrameError: Error, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Export's frame renderer (`NativeExportFrames.defaultRenderer`, installed by the app): the preview's composition
/// and painter (`ExportFramePainter`) fed by the media engine. Each visible layer decodes forward through its own
/// `VideoFrameReader` (one per timeline lane, as the preview decodes), opened when the clip comes on screen and
/// closed when it leaves, so memory stays bounded by what one frame shows.
public final class PreviewExportFrames: NativeExportFrameRenderer {
    private struct Lane { let reader: VideoFrameReader; var still: CanvasImage? }

    public let painter: ExportFramePainter
    private var lanes: [String: Lane] = [:]
    private var failure: ExportFrameError?
    /// Pictures asked of the engine so far (a still or a held frame is asked for once per lane).
    public private(set) var framesDecoded = 0

    public init(_ request: NativeExportFrameRequest) throws {
        let composition = PreviewComposition(document: request.document, projectDir: URL(fileURLWithPath: request.projectDir),
                                             engine: request.keyframeEngine)
        let pad = request.transparentPad ? CanvasColor.transparent : CanvasColor.opaqueBlack
        painter = try ExportFramePainter(composition: composition, width: request.width, height: request.height, pad: pad)
    }

    /// What `main.swift` installs as `NativeExportFrames.defaultRenderer`.
    public static let factory: NativeExportFrameRendererFactory = { try PreviewExportFrames($0) }

    public func frame(at time: Double) throws -> [UInt8] {
        failure = nil
        let image = try painter.paint(time: time) { layer, sourceTime, w, h in
            self.decode(layer, sourceTime: sourceTime, width: w, height: h)
        }
        if let failure { throw failure }
        let shown = Set(painter.layers(at: time).map(\.layer.laneKey))
        lanes = lanes.filter { shown.contains($0.key) }
        return image.rgba
    }

    private func decode(_ layer: PreviewLayer, sourceTime: Double, width: Int, height: Int) -> CanvasImage? {
        do {
            var lane = try lanes[layer.laneKey] ?? Lane(reader: VideoFrameReader(path: layer.source), still: nil)
            defer { lanes[layer.laneKey] = lane }
            let still = layer.isStill || lane.reader.info.isStill
            if still, let cached = lane.still, cached.width == width, cached.height == height { return cached }
            // The clip was checked against its media's length before export started; a last-frame rounding overshoot
            // shows the final frame. A held frame is read at its own source time, as the preview's still lane reads it.
            let onePicture = layer.kind == .image || lane.reader.info.isStill
            let t = onePicture ? 0 : max(0, min(sourceTime, lane.reader.info.duration - 1e-6))
            framesDecoded += 1
            let frame = try lane.reader.frame(at: t, width: width, height: height)
            let image = CanvasImage(width: width, height: height, rgba: frame.rgba)
            if still { lane.still = image }
            return image
        } catch {
            if failure == nil { failure = ExportFrameError("Clip \(layer.clipId) could not be decoded: \(error)") }
            return nil
        }
    }
}
