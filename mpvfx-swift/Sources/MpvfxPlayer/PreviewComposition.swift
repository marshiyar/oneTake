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
import MpvfxTheme
import MpvfxTimeline
import MpvfxShared
import MpvfxColor

/// One visual clip evaluated at one composition time: what the preview draws for it.
///
/// Geometry follows the export renderer (TimelineRenderer.swift): the clip's box is `layout.left/top +
/// transform.position`, sized `layout.width/height` (default: the fit of the media's natural size, else the
/// whole canvas); the media is fitted inside the box keeping its aspect (contain, nativeMediaRect), then scaled and rotated about the box centre, at `opacity`.
/// `crop` insets the untransformed box (canvas px) and travels with the box's scale and rotation.
public struct PreviewLayer: Equatable, Sendable {
    public enum Kind: Sendable, Equatable { case video, image, text }
    public var clipId: String
    /// Absolute media path.
    public var source: String
    public var kind: Kind
    /// Timeline seconds the clip covers, [start, end).
    public var start: Double, end: Double
    /// Source seconds shown at `start`.
    public var sourceIn: Double
    /// Source seconds per timeline second.
    public var rate: Double
    /// Timeline frames the clip covers, [startFrame, endFrame).
    public var startFrame: Int, endFrame: Int
    public var box: CanvasRect
    public var scaleX: Double, scaleY: Double
    /// Degrees, clockwise, about the box centre (includes auto-rotate along the motion path).
    public var rotation: Double
    public var opacity: Double
    public var crop: CropInsets
    /// Part of `rotation` that comes from auto-rotate along the motion path (not from transform.rotation).
    public var motionRotation = 0.0
    /// The clip's color grade and stylize effects, applied to its frames when they are drawn (nil: none active).
    public var grade: ColorGradeRenderer?
    /// Fill, stroke and shadows (the inspector's Style section), drawn with the box (nil: none).
    public var style: NativeClipStyle?
    /// A text layer's words and typography (kind .text): laid out in the box instead of a decoded picture.
    public var text: NativeClipText?
    /// Depth, tilt and lens (the inspector's 3D transform), applied about the box centre after scale and rotation.
    public var transform3D = NativeTransform3D.identity

    public init(clipId: String, source: String, kind: Kind, start: Double, end: Double, sourceIn: Double, rate: Double = 1,
                startFrame: Int = 0, endFrame: Int = Int.max, box: CanvasRect, scaleX: Double = 1, scaleY: Double = 1,
                rotation: Double = 0, opacity: Double = 1, crop: CropInsets = .zero) {
        self.clipId = clipId; self.source = source; self.kind = kind; self.start = start; self.end = end
        self.sourceIn = sourceIn; self.rate = rate > 0 ? rate : 1; self.startFrame = startFrame; self.endFrame = endFrame
        self.box = box; self.scaleX = scaleX; self.scaleY = scaleY; self.rotation = rotation; self.opacity = opacity; self.crop = crop
    }

    /// Source seconds shown at timeline `time`.
    public func sourceTime(at time: Double) -> Double { sourceIn + (time - start) * rate }

    /// Nothing would reach the screen (zero area, zero scale, fully transparent, or cropped away).
    public var isVisible: Bool {
        opacity > 0 && box.width > 0 && box.height > 0 && abs(scaleX) >= 1e-6 && abs(scaleY) >= 1e-6 &&
            crop.left + crop.right < box.width && crop.top + crop.bottom < box.height
    }

    /// The box with the crop applied, in untransformed canvas px.
    public var visibleBox: CanvasRect {
        CanvasRect(x: box.x + crop.left, y: box.y + crop.top,
                   width: max(0, box.width - crop.left - crop.right), height: max(0, box.height - crop.top - crop.bottom))
    }

    /// Identity of the decoded picture stream: frames from one lane are interchangeable across draws.
    /// The grade is not part of it: lanes cache raw decoded frames and the grade is applied when drawing, so a grade
    /// edit never restarts a decoder.
    public var laneKey: String { "\(clipId)|\(source)|\(sourceIn)|\(rate)|\(startFrame)" }
}

/// The visual clips of a document and their per-time evaluation (static values, then keyframe tracks).
public struct PreviewComposition {
    public struct Entry {
        public var clip: NativeProjectClip
        public var kind: PreviewLayer.Kind
        public var path: String
        /// Compositing order key: layout.zIndex, else the track's display row (the top row draws on top).
        public var layer: Double
        /// The clip's active grade, built once per document.
        public var grade: ColorGradeRenderer? = nil
    }

    public let canvas: CanvasSize
    public let background: CanvasColor
    public let fps: Double
    /// Visual clips with a readable media file, bottom-most first.
    public let entries: [Entry]
    public let engine: KeyframeEngine?

    /// `naturalSize`: the media's natural pixel size (default: the size cached on the asset). A clip with no size
    /// of its own takes the default box for it (nativeClipNaturalLayout), as export does.
    public init(document: NativeProjectDocument, projectDir: URL?, engine: KeyframeEngine?,
                naturalSize: (NativeProjectAsset) -> NativeMediaNaturalSize? = { $0.naturalSize },
                sizePending: (NativeProjectAsset) -> Bool = { _ in false },
                fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        canvas = CanvasSize(document.canvas.width, document.canvas.height)
        background = CanvasColor(hex: document.canvas.background) ?? CanvasColor(ThemeTokens.stageScrim)
        let rate = document.frameRate.denominator != 0 ? document.frameRate.numerator / document.frameRate.denominator : 30
        fps = rate > 0 && rate.isFinite ? rate : 30
        self.engine = engine
        let assets = Dictionary(document.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ordered: [(Entry, Int)] = []
        var n = 0
        let trackLayers = nativeTrackStackingLayers(document.sequence.tracks)
        for (index, track) in document.sequence.tracks.enumerated() {
            for clip in track.clips {
                guard !Self.isHidden(track: track, clip: clip) else { n += 1; continue }
                n += 1
                if let asset = assets[clip.assetId], asset.kind == .element, clip.text != nil {
                    // A text layer: no media, drawn from its words (NativeTextRendering), as export rasterizes it.
                    var layer = trackLayers[index]
                    if case .number(let z)? = clip.staticParameters?["layout.zIndex"] { layer = z }
                    ordered.append((Entry(clip: clip, kind: .text, path: "text:\(clip.id)", layer: layer), n))
                    continue
                }
                guard let asset = assets[clip.assetId], asset.kind == .video || asset.kind == .image,
                      let src = asset.source, !src.isEmpty else { continue }
                let path = src.hasPrefix("/") ? src : (projectDir ?? URL(fileURLWithPath: ".")).appendingPathComponent(src).path
                guard fileExists(path) else { continue }
                // Its box is not known yet (natural size still probing): not drawn rather than drawn full frame.
                guard !sizePending(asset) else { continue }
                var layer = trackLayers[index]
                if case .number(let z)? = clip.staticParameters?["layout.zIndex"] { layer = z }
                let grade = ColorGradeRenderer.forClip(ColorGradeParams.clipGrade(clip), clipId: clip.id, projectDir: projectDir?.path)
                let clip = nativeClipWithNaturalLayout(clip, natural: naturalSize(asset),
                                                       canvasWidth: document.canvas.width, canvasHeight: document.canvas.height)
                ordered.append((Entry(clip: clip, kind: asset.kind == .image ? .image : .video, path: path, layer: layer, grade: grade), n))
            }
        }
        entries = ordered.sorted { a, b in
            if a.0.layer != b.0.layer { return a.0.layer < b.0.layer }
            if a.0.clip.startFrame != b.0.clip.startFrame { return a.0.clip.startFrame < b.0.clip.startFrame }
            if a.0.clip.id != b.0.clip.id { return a.0.clip.id < b.0.clip.id }
            return a.1 < b.1
        }.map(\.0)
    }

    /// Hidden tracks and hidden clips (the timeline eye toggle) are left out of the picture, as export leaves them out.
    static func isHidden(track: NativeProjectTrack, clip: NativeProjectClip) -> Bool { track.hidden == true || clip.hidden == true }

    /// Timeline frame shown at `time` (a frame is shown from its start time until the next).
    public func frameIndex(at time: Double) -> Int { Int((time * fps + 1e-6).rounded(.down)) }

    /// Layers covering `time`, bottom first. Invisible layers are kept (callers skip them) so order stays stable.
    public func layers(at time: Double) -> [PreviewLayer] {
        let f = Double(frameIndex(at: time))
        return entries.compactMap { e in
            guard e.clip.startFrame <= f, f < e.clip.startFrame + e.clip.durationFrames else { return nil }
            return layer(e, at: time)
        }
    }

    /// Clips that start within (time, time + horizon], for pre-rolling their decoders during playback.
    public func upcoming(after time: Double, within horizon: Double) -> [PreviewLayer] {
        let f = Double(frameIndex(at: time))
        return entries.compactMap { e in
            let start = e.clip.startFrame / fps
            guard e.clip.startFrame > f, start <= time + horizon else { return nil }
            return layer(e, at: start)
        }
    }

    /// Clips that end within [time - horizon, time) (playing backward, the next ones to come on screen).
    public func upcomingReverse(before time: Double, within horizon: Double) -> [PreviewLayer] {
        let f = Double(frameIndex(at: time))
        return entries.compactMap { e in
            let endFrame = e.clip.startFrame + e.clip.durationFrames
            guard endFrame <= f, endFrame / fps >= time - horizon, e.clip.durationFrames > 0 else { return nil }
            return layer(e, at: (endFrame - 1) / fps)
        }
    }

    public func layer(_ e: Entry, at time: Double) -> PreviewLayer {
        let c = e.clip
        let local = max(0, min(c.durationFrames - 1, Double(frameIndex(at: time)) - c.startFrame))
        var values: [String: NativeParameterValue] = [:]
        if let s = c.staticParameters { for k in s.keys { if let v = s[k] { values[k] = v } } }
        var autoRotate = 0.0
        for track in c.parameterTracks where !track.keyframes.isEmpty {
            guard let v = try? evaluateNativeParameterTrack(track, projectFrame: local, engine: engine) else { continue }
            values[track.parameterId] = v
            if track.parameterId == "transform.position", track.autoRotate == true,
               let eng = engine ?? (try? keyframeEngine()),
               let a = try? eng.tangentAngle(KeyframeTrack(track), frame: local), a.isFinite {
                autoRotate = a * 180 / .pi
            }
        }
        func num(_ k: String) -> Double? { if case .number(let v)? = values[k] { return v }; return nil }
        func vec(_ k: String) -> Vec2Value? { if case .vec2(let v)? = values[k] { return v }; return nil }

        var px = vec("transform.position")?.x ?? 0, py = vec("transform.position")?.y ?? 0
        if let x = num("transform.position.x") { px = x }
        if let y = num("transform.position.y") { py = y }
        var sx = 1.0, sy = 1.0
        if let s = num("transform.scale") { sx = s; sy = s } else if let s = vec("transform.scale") { sx = s.x; sy = s.y }
        if let x = num("transform.scaleX") { sx = x }
        if let y = num("transform.scaleY") { sy = y }
        let opacity = max(0, min(1, num("transform.opacity") ?? num("visual.opacity") ?? num("visual.autoAlpha") ?? 1))
        let box = CanvasRect(x: (num("layout.left") ?? 0) + px, y: (num("layout.top") ?? 0) + py,
                             width: max(0, num("layout.width") ?? canvas.width), height: max(0, num("layout.height") ?? canvas.height))
        let crop = c.crop.map { CropInsets(top: max(0, $0.top), right: max(0, $0.right), bottom: max(0, $0.bottom), left: max(0, $0.left)) } ?? .zero
        let rate = c.playbackRate.map { $0.denominator != 0 && $0.numerator > 0 ? $0.numerator / $0.denominator : 1 } ?? 1
        let sourceIn = sourceFrameValue(NativeSourcePosition(sourceInFrame: c.sourceInFrame, sourceInFraction: c.sourceInFraction)) / fps
        var out = PreviewLayer(clipId: c.id, source: e.path, kind: e.kind, start: c.startFrame / fps,
                            end: (c.startFrame + c.durationFrames) / fps, sourceIn: sourceIn, rate: rate,
                            startFrame: Int(c.startFrame.rounded()), endFrame: Int((c.startFrame + c.durationFrames).rounded()),
                            box: box, scaleX: sx, scaleY: sy,
                            rotation: (num("transform.rotation") ?? 0) + autoRotate, opacity: opacity, crop: crop)
        out.motionRotation = autoRotate
        out.grade = e.grade
        out.style = (c.style?.isEmpty ?? true) ? nil : c.style
        out.text = e.kind == .text ? c.text : nil
        out.transform3D = NativeTransform3D(rotationX: num(NativeTransform3D.rotationXId) ?? 0, rotationY: num(NativeTransform3D.rotationYId) ?? 0,
                                            z: num(NativeTransform3D.zId) ?? 0, perspective: num(NativeTransform3D.perspectiveId) ?? 0)
        return out
    }
}

/// Draws composited layers onto a CanvasContext. Pure geometry; no decoding.
public enum PreviewPainter {
    /// Largest rect with the image's aspect inside `box`, centred (contain fit).
    public static func containRect(imageWidth: Int, imageHeight: Int, in box: CanvasRect) -> CanvasRect {
        guard imageWidth > 0, imageHeight > 0, box.width > 0, box.height > 0 else { return box }
        let s = min(box.width / Double(imageWidth), box.height / Double(imageHeight))
        let w = Double(imageWidth) * s, h = Double(imageHeight) * s
        return CanvasRect(x: box.x + (box.width - w) / 2, y: box.y + (box.height - h) / 2, width: w, height: h)
    }

    /// Where a layer's picture lands, in composition px: nativeMediaRect (contain, or the whole box when the box is
    /// already the picture's aspect to within rounding), so the picture's edges are the selection box's edges.
    public static func mediaRect(imageWidth: Int, imageHeight: Int, in box: CanvasRect) -> CanvasRect {
        let r = nativeMediaRect(imageWidth: Double(imageWidth), imageHeight: Double(imageHeight),
                                box: NativeClipLayoutBox(left: box.x, top: box.y, width: box.width, height: box.height))
        return CanvasRect(x: r.left, y: r.top, width: r.width, height: r.height)
    }

    /// Composition px -> view px for a frame rect showing the whole canvas at `scale`.
    public static func toView(_ r: CanvasRect, frame: CanvasRect, scale s: Double) -> CanvasRect {
        CanvasRect(x: frame.x + r.x * s, y: frame.y + r.y * s, width: r.width * s, height: r.height * s)
    }

    /// Device pixels the layer's box covers on screen (the decode target before rounding).
    public static func screenPixels(_ layer: PreviewLayer, viewScale: Double, backingScale: Double) -> (width: Double, height: Double) {
        let k = viewScale * max(backingScale, 1)
        return (layer.box.width * abs(layer.scaleX) * k, layer.box.height * abs(layer.scaleY) * k)
    }

    /// Draws one layer: scale then rotate about the box centre, clip to the cropped box, contain-fit the image.
    public static func draw(_ layer: PreviewLayer, image: CanvasImage, on c: CanvasContext, frame: CanvasRect, scale s: Double) {
        draw(layer, image: Optional(image), on: c, frame: frame, scale: s)
    }

    /// Draws a text layer (kind .text): its words laid out in the box with the layer's transform, crop and style.
    public static func drawText(_ layer: PreviewLayer, on c: CanvasContext, frame: CanvasRect, scale s: Double) {
        guard layer.text != nil else { return }
        draw(layer, image: nil, on: c, frame: frame, scale: s)
    }

    static func draw(_ layer: PreviewLayer, image: CanvasImage?, on c: CanvasContext, frame: CanvasRect, scale s: Double) {
        guard layer.isVisible else { return }
        let box = toView(layer.box, frame: frame, scale: s)
        let cx = box.x + box.width / 2, cy = box.y + box.height / 2
        let t3 = layer.transform3D
        guard t3.isIdentity else {
            draw3D(layer, t3, box: box, frame: frame, scale: s, on: c) { drawContent(layer, image: image, on: c, frame: frame, scale: s, axisAligned: false) }
            return
        }
        c.withState {
            c.translate(cx, cy)
            if layer.rotation != 0 { c.rotate(layer.rotation * .pi / 180) }
            if layer.scaleX != 1 || layer.scaleY != 1 { c.scale(layer.scaleX, layer.scaleY) }
            c.translate(-cx, -cy)
            // Square crop mask; with no rotation or scale its edges sit on device pixels, like the stage outline.
            drawContent(layer, image: image, on: c, frame: frame, scale: s,
                        axisAligned: layer.rotation == 0 && layer.scaleX == 1 && layer.scaleY == 1)
        }
    }

    /// The layer's shadows, crop, fill, picture or text and stroke, in its untransformed (view px) box: the caller
    /// has set the transform.
    static func drawContent(_ layer: PreviewLayer, image: CanvasImage?, on c: CanvasContext, frame: CanvasRect, scale s: Double,
                            axisAligned: Bool) {
        let box = toView(layer.box, frame: frame, scale: s)
        let visible = toView(layer.visibleBox, frame: frame, scale: s)
        do {
            if let style = layer.style { drawShadows(style, visible: visible, scale: s, opacity: layer.opacity, on: c) }
            if !layer.crop.isZero { c.clip(axisAligned ? PlayerView.pixelAligned(visible, scale: c.deviceScale) : visible) }
            if let fill = layer.style?.fill.flatMap(CanvasColor.init(hex:)), fill.a > 0 {
                var p = CanvasPath(); p.addRect(box); c.fill(p, fill.withAlpha(fill.a * layer.opacity))
            }
            if let image {
                let picture = toView(mediaRect(imageWidth: image.width, imageHeight: image.height, in: layer.box), frame: frame, scale: s)
                c.drawImage(image, in: picture, opacity: layer.opacity)
            } else if let text = layer.text {
                TextLayout.draw(NativeTextRendering.block(text, scale: s), in: box, on: c, opacity: layer.opacity)
            }
            if let style = layer.style, style.visibleStrokeWidth > 0, let color = CanvasColor(hex: style.resolvedStrokeColor) {
                // Inside the box edge, like export's drawbox.
                let w = min(style.visibleStrokeWidth * s, min(box.width, box.height) / 2)
                var p = CanvasPath(); p.addRect(box.insetBy(w / 2))
                c.stroke(p, color.withAlpha(color.a * layer.opacity), StrokeStyle(width: w))
            }
        }
    }

    /// Mesh cells per side for a lens-projected layer: each cell is two triangles drawn with their own affine map.
    static let meshCells = 8

    /// Draws a layer through its 3D transform. A linear projection (no lens, or an untilted plane) is one affine
    /// map; a tilted plane under a lens is a mesh of triangles, each clipped and drawn with the affine map that
    /// takes it exactly onto its projected corners, so the picture foreshortens as export's projective warp draws it.
    static func draw3D(_ layer: PreviewLayer, _ t3: NativeTransform3D, box: CanvasRect, frame: CanvasRect, scale s: Double,
                       on c: CanvasContext, content: () -> Void) {
        let cx = box.x + box.width / 2, cy = box.y + box.height / 2
        // View px relative to the box centre -> view px on screen.
        func map(_ x: Double, _ y: Double) -> CanvasPoint {
            let p = t3.project((x - cx) / s, (y - cy) / s, scaleX: layer.scaleX, scaleY: layer.scaleY, rotation: layer.rotation)
            return CanvasPoint(cx + p.x * s, cy + p.y * s)
        }
        func affine(_ src: [CanvasPoint], _ dst: [CanvasPoint]) -> (a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double)? {
            let p = src[1].x - src[0].x, q = src[1].y - src[0].y, r = src[2].x - src[0].x, t = src[2].y - src[0].y
            let det = p * t - r * q
            guard abs(det) > 1e-9 else { return nil }
            let dp = dst[1].x - dst[0].x, dq = dst[1].y - dst[0].y, dr = dst[2].x - dst[0].x, dt = dst[2].y - dst[0].y
            // L = D · S⁻¹, S = [[p, r], [q, t]]
            let a = (dp * t - dr * q) / det, cc = (dr * p - dp * r) / det
            let b = (dq * t - dt * q) / det, d = (dt * p - dq * r) / det
            return (a, b, cc, d, dst[0].x - a * src[0].x - cc * src[0].y, dst[0].y - b * src[0].x - d * src[0].y)
        }
        if t3.isAffine {
            let o = [CanvasPoint(cx, cy), CanvasPoint(cx + 100, cy), CanvasPoint(cx, cy + 100)]
            guard let m = affine(o, o.map { map($0.x, $0.y) }) else { return }
            c.withState { c.concat(a: m.a, b: m.b, c: m.c, d: m.d, tx: m.tx, ty: m.ty); content() }
            return
        }
        // The mesh covers the box and any shadow around it.
        var area = box
        for sh in (layer.style?.shadows ?? []) {
            let pad = (abs(sh.x) + abs(sh.y) + max(0, sh.blur) + max(0, sh.spread)) * s
            area = area.insetBy(-pad)
        }
        let n = meshCells
        for j in 0..<n { for i in 0..<n {
            let x0 = area.x + area.width * Double(i) / Double(n), x1 = area.x + area.width * Double(i + 1) / Double(n)
            let y0 = area.y + area.height * Double(j) / Double(n), y1 = area.y + area.height * Double(j + 1) / Double(n)
            for tri in [[CanvasPoint(x0, y0), CanvasPoint(x1, y0), CanvasPoint(x0, y1)],
                        [CanvasPoint(x1, y1), CanvasPoint(x0, y1), CanvasPoint(x1, y0)]] {
                let dst = tri.map { map($0.x, $0.y) }
                guard let m = affine(tri, dst) else { continue }
                // Grow the clip ~0.6 px about the centroid so neighbouring triangles overlap instead of leaving seams.
                let gx = (dst[0].x + dst[1].x + dst[2].x) / 3, gy = (dst[0].y + dst[1].y + dst[2].y) / 3
                var clip = CanvasPath()
                for (k, p) in dst.enumerated() {
                    let dx = p.x - gx, dy = p.y - gy, len = max(1e-6, (dx * dx + dy * dy).squareRoot())
                    let q = CanvasPoint(p.x + dx / len * 0.6, p.y + dy / len * 0.6)
                    if k == 0 { clip.move(to: q) } else { clip.line(to: q) }
                }
                clip.close()
                c.withState {
                    c.clip(clip)
                    c.concat(a: m.a, b: m.b, c: m.c, d: m.d, tx: m.tx, ty: m.ty)
                    content()
                }
            }
        } }
    }

    /// Box shadows of the visible box, in the layer's transformed space (they turn and scale with it), last one
    /// lowest. The blur is drawn as a ramp of nested rects across the blur radius.
    static func drawShadows(_ style: NativeClipStyle, visible: CanvasRect, scale s: Double, opacity: Double, on c: CanvasContext) {
        for sh in (style.shadows ?? []).reversed() {
            guard let color = CanvasColor(hex: sh.color), color.a > 0 else { continue }
            let base = CanvasRect(x: visible.x + sh.x * s, y: visible.y + sh.y * s, width: visible.width, height: visible.height)
                .insetBy(-sh.spread * s)
            let blur = max(0, sh.blur) * s
            let steps = blur < 0.5 ? 1 : 6
            for i in 0..<steps {
                // ring i: from the inner edge (base - blur/2) outward to base + blur/2
                let d = steps == 1 ? 0 : blur * (Double(i) + 0.5) / Double(steps) - blur / 2
                let r = base.insetBy(-d)
                guard r.width > 0, r.height > 0 else { continue }
                var p = CanvasPath(); p.addRect(r)
                c.fill(p, color.withAlpha(color.a * opacity / Double(steps)))
            }
        }
    }
}
