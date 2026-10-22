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
/// whole canvas); the media is placed in the box by the clip's fit (nativeMediaRect: contain by default, cover clipped
/// to the box, or stretched onto it), then scaled and rotated about the box centre, at `opacity`.
/// `crop` insets the untransformed box (canvas px) and travels with the box's scale and rotation.
public struct PreviewLayer: Equatable, Sendable {
    /// `offline`: a video or image clip whose media file is missing, drawn as a slate naming the file, never decoded.
    public enum Kind: Sendable, Equatable { case video, image, text, generator, offline }
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
    /// Optional clip-local nonlinear map; export and preview share this exact layer path.
    public var speedRamp: NativeSpeedRamp?
    /// Timeline frames the clip covers, [startFrame, endFrame).
    public var startFrame: Int, endFrame: Int
    public var box: CanvasRect
    public var scaleX: Double, scaleY: Double
    /// Degrees, clockwise, about the box centre (includes auto-rotate along the motion path).
    public var rotation: Double
    public var opacity: Double
    /// The clip's fade gain at this frame (`NativeClipFade`), already in `opacity`; a live opacity override is
    /// multiplied by it too (`PreviewCompositor.applyStage`).
    public var fadeGain = 1.0
    /// True when only the clip's fade hides the layer at this frame (a fade-in's first frame): it is not drawn, but
    /// its decoder is kept ready for the frames that follow (`needsDecoder`).
    public var hiddenByFade = false
    /// How the layer combines with the ones under it (`clip.style.blend`).
    public var blend = NativeBlendMode.normal
    public var crop: CropInsets
    /// Part of `rotation` that comes from auto-rotate along the motion path (not from transform.rotation).
    public var motionRotation = 0.0
    /// The clip's color grade and stylize effects, applied to its frames when they are drawn (nil: none active).
    public var grade: ColorGradeRenderer?
    /// Fill, stroke and shadows (the inspector's Style section), drawn with the box (nil: none).
    public var style: NativeClipStyle?
    /// A text layer's words and typography (kind .text): laid out in the box instead of a decoded picture.
    public var generator: NativeFill?
    public var isProcedural: Bool { kind == .text || kind == .generator }
    public var text: NativeClipText?
    /// Depth, tilt and lens (the inspector's 3D transform), applied about the box centre after scale and rotation.
    public var transform3D = NativeTransform3D.identity
    /// A dip transition's colour laid over the picture (nil: none), and how much of it (0…1).
    public var transitionColor: CanvasColor?
    public var transitionColorAmount = 0.0
    public var spatialTransition: PreviewSpatialTransition?
    /// Source seconds of the one frame a held clip shows for its whole length (`clip.holdSourceFrame`); nil plays the source.
    public var holdSourceTime: Double?
    /// Supported masks evaluated at this timeline time.
    public var masks: [NativeClipMask] = []
    /// File name of an offline layer's missing media (kind .offline), shown on its slate.
    public var offlineFileName: String?
    /// How the picture fills the box (`clip.fit`; nil: Fit, contain).
    public var fit: NativeMediaFit?
    /// The media's natural width over height when known: sizes the decode so a Fill or Stretch picture, larger than
    /// the box on one axis, is decoded at the size it is drawn rather than scaled up from a contained frame.
    public var mediaAspect: Double?
    /// What fills the frame behind a picture that does not cover it (colour, gradient or blurred copy); nil: nothing.
    public var fill: PreviewFill?
    /// Set on the layer of an image fill: where the picture it sits behind lands, left uncovered by this layer.
    public var fillCutout: PreviewFillCutout?

    public init(clipId: String, source: String, kind: Kind, start: Double, end: Double, sourceIn: Double, rate: Double = 1,
                startFrame: Int = 0, endFrame: Int = Int.max, box: CanvasRect, scaleX: Double = 1, scaleY: Double = 1,
                rotation: Double = 0, opacity: Double = 1, crop: CropInsets = .zero) {
        self.clipId = clipId; self.source = source; self.kind = kind; self.start = start; self.end = end
        self.sourceIn = sourceIn; self.rate = rate > 0 ? rate : 1; self.startFrame = startFrame; self.endFrame = endFrame
        self.box = box; self.scaleX = scaleX; self.scaleY = scaleY; self.rotation = rotation; self.opacity = opacity; self.crop = crop
    }

    /// Source seconds shown at timeline `time`.
    public func sourceTime(at time: Double) -> Double {
        if let held = holdSourceTime { return held }
        guard let ramp = speedRamp else { return sourceIn + (time - start) * rate }
        // A transition can start the layer earlier than its clip (handle media): the ramp is timed from the clip start.
        let x = (time - (rampStart ?? start)) * timelineFPS
        return sourceIn + (x >= 0 ? ramp.sourcePosition(atClipFrame: x) : x * ramp.speed(atClipFrame: 0)) / timelineFPS
    }
    /// The clip's own start when a transition moved `start` earlier and a speed ramp is timed from the clip start.
    public var rampStart: Double?
    public var timelineFPS = 1.0

    /// One picture for the whole clip (an image, or a held frame): decoded once and kept (the still lane).
    public var isStill: Bool { kind == .image || holdSourceTime != nil }

    /// Nothing would reach the screen (zero area, zero scale, fully transparent, or cropped away).
    public var isVisible: Bool { opacity > 0 && hasArea }

    /// Drawn now, or hidden only by its fade: the compositor decodes and pre-rolls it either way.
    public var needsDecoder: Bool { (opacity > 0 || hiddenByFade) && hasArea }

    var hasArea: Bool {
        box.width > 0 && box.height > 0 && abs(scaleX) >= 1e-6 && abs(scaleY) >= 1e-6 &&
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
    public var laneKey: String {
        let key = "\(clipId)|\(source)|\(sourceIn)|\(rate)|\(startFrame)"
        return holdSourceTime.map { "\(key)|hold:\($0)" } ?? key
    }
}

/// The visual clips of a document and their per-time evaluation (static values, then keyframe tracks).
public struct PreviewComposition {
    public struct Entry {
        public var clip: NativeProjectClip
        public var kind: PreviewLayer.Kind
        public var path: String
        /// Compositing order key: layout.zIndex, else the track's display row (the top row draws on top).
        public var layer: Double
        /// The clip's active grade, built once per document (its static grade when `gradeAnimation` is set).
        public var grade: ColorGradeRenderer? = nil
        /// The cut transitions the clip takes part in (`nativeCutTransitionSpans`): the frames it is drawn before its
        /// start and after its end from its handles, and how it mixes during each transition.
        public var transitions = NativeClipTransitions()
        /// Timeline frames the clip is drawn over, transitions included, [drawStart, drawEnd).
        public var drawStart: Double { clip.startFrame - transitions.lead }
        public var drawEnd: Double { clip.startFrame + clip.durationFrames + transitions.tail }
        /// Set when grade parameters are keyframed (issue #179): the grade is then built per frame from the values
        /// at that frame, through this memo of the last few frames' renderers.
        public var gradeAnimation: PreviewGradeAnimation? = nil
        /// The missing file's name when the clip is offline (kind .offline).
        public var offlineFileName: String? = nil
        /// The media's natural width over height (PreviewLayer.mediaAspect), nil when unknown.
        public var mediaAspect: Double? = nil
        /// The clip's colour, gradient or blurred-copy fill (an image fill is `fillImagePath`).
        public var fill: PreviewFill? = nil
        /// The image fill's file and natural aspect when the asset is on disk.
        public var fillImagePath: String? = nil
        public var fillImageAspect: Double? = nil
    }

    /// Pre-roll horizon, in seconds, for a clip that comes on screen through a transition: both of its decoders run
    /// at once, so the incoming one starts this far ahead and the first frame of the transition is ready.
    public static let transitionPreroll = 1.0

    public let canvas: CanvasSize
    public let background: CanvasColor
    public let fps: Double
    /// Visual clips, bottom-most first: those with a media file on disk, and offline ones (kind .offline).
    public let entries: [Entry]
    /// Assets (video, image and sound) whose media file was missing when the composition was built. Each source is
    /// statted once per build, never per frame; a rebuild after the file comes back clears its mark.
    public let offlineAssetIds: Set<String>
    public let engine: KeyframeEngine?

    /// `naturalSize`: the media's natural pixel size (default: the size cached on the asset). A clip with no size
    /// of its own takes the default box for it (nativeClipNaturalLayout), as export does.
    public init(document: NativeProjectDocument, projectDir: URL?, engine: KeyframeEngine?,
                naturalSize: @escaping (NativeProjectAsset) -> NativeMediaNaturalSize? = { $0.naturalSize },
                sizePending: @escaping (NativeProjectAsset) -> Bool = { _ in false },
                fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        canvas = CanvasSize(document.canvas.width, document.canvas.height)
        background = CanvasColor(hex: document.canvas.background) ?? CanvasColor(ThemeTokens.stageScrim)
        let rate = document.frameRate.denominator != 0 ? document.frameRate.numerator / document.frameRate.denominator : 30
        fps = rate > 0 && rate.isFinite ? rate : 30
        self.engine = engine
        let assets = Dictionary(document.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ordered: [(Entry, Int)] = []
        var n = 0
        var media = MediaEntries(document: document, projectDir: projectDir, naturalSize: naturalSize, sizePending: sizePending,
                                 fileExists: fileExists)
        let trackLayers = nativeTrackStackingLayers(document.sequence.tracks)
        for (index, track) in document.sequence.tracks.enumerated() {
            for clip in track.clips {
                n += 1
                guard !Self.isLeftOut(track: track, clip: clip), let asset = assets[clip.assetId] else { continue }
                let layer = Self.stackingLayer(clip, track: trackLayers[index])
                if asset.kind == .element, clip.generator?.isGenerator == true, clip.text == nil {
                    ordered.append((Entry(clip: clip, kind: .generator, path: "generator:\(clip.id)", layer: layer), n))
                } else if asset.kind == .element, clip.text != nil {
                    // A text layer: no media, drawn from its words (NativeTextRendering), as export rasterizes it.
                    ordered.append((Entry(clip: clip, kind: .text, path: "text:\(clip.id)", layer: layer), n))
                } else if var entry = media.entry(clip, asset: asset, layer: layer) {
                    if entry.kind != .offline { entry.gradeAnimation = PreviewGradeAnimation.forClip(entry.clip, projectDir: projectDir?.path) }
                    if entry.kind == .video || entry.kind == .image { media.attachFill(&entry, document: document, assets: assets) }
                    ordered.append((entry, n))
                }
            }
        }
        let spans = nativeCutTransitionSpans(document)
        for i in ordered.indices { ordered[i].0.transitions = spans[ordered[i].0.clip.id] ?? NativeClipTransitions() }
        offlineAssetIds = media.offline
        entries = ordered.sorted { a, b in
            if a.0.layer != b.0.layer { return a.0.layer < b.0.layer }
            if a.0.clip.startFrame != b.0.clip.startFrame { return a.0.clip.startFrame < b.0.clip.startFrame }
            if a.0.clip.id != b.0.clip.id { return a.0.clip.id < b.0.clip.id }
            return a.1 < b.1
        }.map(\.0)
    }

    /// Compositing order key: layout.zIndex, else the track's display row.
    static func stackingLayer(_ clip: NativeProjectClip, track: Double) -> Double {
        if case .number(let z)? = clip.staticParameters?["layout.zIndex"] { return z }
        return track
    }

    /// Builds the entry of a video or image clip, statting each media file once per composition: a clip whose file is
    /// missing becomes an offline entry and its asset (sound-only ones too) is recorded in `offline`.
    struct MediaEntries {
        let document: NativeProjectDocument
        let projectDir: URL?
        let naturalSize: (NativeProjectAsset) -> NativeMediaNaturalSize?
        let sizePending: (NativeProjectAsset) -> Bool
        let fileExists: (String) -> Bool
        var exists: [String: Bool] = [:]
        var offline = Set<String>()

        init(document: NativeProjectDocument, projectDir: URL?, naturalSize: @escaping (NativeProjectAsset) -> NativeMediaNaturalSize?,
             sizePending: @escaping (NativeProjectAsset) -> Bool, fileExists: @escaping (String) -> Bool) {
            self.document = document; self.projectDir = projectDir; self.naturalSize = naturalSize
            self.sizePending = sizePending; self.fileExists = fileExists
        }

        /// Stats `asset`'s media file (once per path) and records the asset when it is missing. Returns the resolved
        /// path and whether the file is there; nil for assets with no media file (elements, text).
        mutating func check(_ asset: NativeProjectAsset) -> (path: String, present: Bool)? {
            guard asset.kind == .video || asset.kind == .image || asset.kind == .audio, let src = asset.source, !src.isEmpty else { return nil }
            // An absolute source (`/…`, or `C:\…` on Windows) is used as is; anything else is relative to the project.
            let path = HostPath.isAbsolute(src) ? src : (projectDir ?? URL(fileURLWithPath: ".")).appendingPathComponent(src).path
            let present = exists[path] ?? fileExists(path)
            exists[path] = present
            if !present { offline.insert(asset.id) }
            return (path, present)
        }

        /// The fill of `entry`'s clip (its own, else the project's). An image fill's file is checked like any media:
        /// a missing one marks the asset offline and draws nothing.
        mutating func attachFill(_ entry: inout Entry, document: NativeProjectDocument, assets: [String: NativeProjectAsset]) {
            guard let fill = PreviewComposition.resolvedFill(entry.clip, document: document), fill.isSupported else { return }
            if fill.kind == "image" {
                guard let asset = fill.assetId.flatMap({ assets[$0] }), asset.kind == .image, let found = check(asset), found.present else { return }
                entry.fillImagePath = found.path
                entry.fillImageAspect = naturalSize(asset).flatMap(\.aspect)
            } else {
                entry.fill = PreviewFill(fill)
            }
        }

        /// The entry of a video or image clip; sound-only clips are checked (so they are marked offline) but not drawn.
        mutating func entry(_ clip: NativeProjectClip, asset: NativeProjectAsset, layer: Double) -> Entry? {
            guard let found = check(asset), asset.kind != .audio, let src = asset.source else { return nil }
            let path = found.path
            guard found.present else {
                // Missing media: a slate in the clip's box (the known natural size, else the default box).
                return Entry(clip: laidOut(clip, asset), kind: .offline, path: path, layer: layer,
                             offlineFileName: URL(fileURLWithPath: src).lastPathComponent)
            }
            // Its box is not known yet (natural size still probing): not drawn rather than drawn full frame.
            guard !sizePending(asset) else { return nil }
            let grade = ColorGradeRenderer.forClip(ColorGradeParams.clipGrade(clip), clipId: clip.id, projectDir: projectDir?.path)
            return Entry(clip: laidOut(clip, asset), kind: asset.kind == .image ? .image : .video, path: path, layer: layer, grade: grade,
                         mediaAspect: naturalSize(asset).flatMap(\.aspect))
        }

        private func laidOut(_ clip: NativeProjectClip, _ asset: NativeProjectAsset) -> NativeProjectClip {
            nativeClipWithNaturalLayout(clip, natural: naturalSize(asset), canvasWidth: document.canvas.width, canvasHeight: document.canvas.height)
        }
    }

    /// Assets whose media file is missing, as a composition of `document` built now would report them, without building
    /// one: what a session re-checks while the document is unchanged (a file deleted or restored outside the app).
    public static func offlineAssetIds(document: NativeProjectDocument, projectDir: URL?,
                                       fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Set<String> {
        let assets = Dictionary(document.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var media = MediaEntries(document: document, projectDir: projectDir, naturalSize: { _ in nil }, sizePending: { _ in false },
                                 fileExists: fileExists)
        for track in document.sequence.tracks {
            for clip in track.clips where !isLeftOut(track: track, clip: clip) {
                if let asset = assets[clip.assetId] { _ = media.check(asset) }
                if let fill = resolvedFill(clip, document: document), fill.isSupported, fill.kind == "image",
                   let asset = fill.assetId.flatMap({ assets[$0] }), asset.kind == .image { _ = media.check(asset) }
            }
        }
        return media.offline
    }

    /// A clip's own fill, or the project's when it has none or inherits.
    static func resolvedFill(_ clip: NativeProjectClip, document: NativeProjectDocument) -> NativeFill? {
        if let own = clip.fill, own.kind != "inherit" { return own }
        return document.compositionFill
    }

    /// Hidden tracks and hidden clips (the timeline eye toggle) are left out of the picture, as export leaves them out.
    static func isHidden(track: NativeProjectTrack, clip: NativeProjectClip) -> Bool { track.hidden == true || clip.hidden == true }

    /// Clips the composition does not draw: hidden ones, and those whose speed ramp this build cannot play.
    static func isLeftOut(track: NativeProjectTrack, clip: NativeProjectClip) -> Bool {
        isHidden(track: track, clip: clip) || clip.speedRamp?.isSupported == false
            || clip.holdSourceFrame.map { !$0.isCurrentVersion } == true
    }

    /// Timeline frame shown at `time` (a frame is shown from its start time until the next).
    public func frameIndex(at time: Double) -> Int { Int((time * fps + 1e-6).rounded(.down)) }

    /// Layers covering `time`, bottom first. Invisible layers are kept (callers skip them) so order stays stable.
    public func layers(at time: Double) -> [PreviewLayer] {
        let f = Double(frameIndex(at: time))
        return entries.flatMap { e -> [PreviewLayer] in
            guard e.drawStart <= f, f < e.drawEnd else { return [] }
            let l = layer(e, at: time)
            guard let fillLayer = imageFillLayer(e, for: l) else { return [l] }
            return [fillLayer, l]
        }
    }

    /// The layer of an image fill: the picture covers the frame (cover fit) behind the clip, which it leaves
    /// uncovered. It is an ordinary image layer, so preview and export decode and draw it as any other.
    func imageFillLayer(_ e: Entry, for owner: PreviewLayer) -> PreviewLayer? {
        guard let path = e.fillImagePath else { return nil }
        var l = PreviewLayer(clipId: "\(owner.clipId)#fill", source: path, kind: .image, start: owner.start, end: owner.end, sourceIn: 0,
                             startFrame: owner.startFrame, endFrame: owner.endFrame,
                             box: CanvasRect(x: 0, y: 0, width: canvas.width, height: canvas.height), opacity: owner.opacity)
        l.timelineFPS = owner.timelineFPS
        l.fit = .fill
        l.mediaAspect = e.fillImageAspect
        l.fillCutout = PreviewFillCutout(box: owner.box, crop: owner.crop, fit: owner.fit, aspect: owner.mediaAspect, rotation: owner.rotation,
                                         scaleX: owner.scaleX, scaleY: owner.scaleY)
        return l
    }

    /// Clips that start within (time, time + horizon], for pre-rolling their decoders during playback.
    public func upcoming(after time: Double, within horizon: Double) -> [PreviewLayer] {
        let f = Double(frameIndex(at: time))
        return entries.compactMap { e in
            let start = e.drawStart / fps
            let reach = e.transitions.lead > 0 ? max(horizon, Self.transitionPreroll) : horizon
            guard e.drawStart > f, start <= time + reach else { return nil }
            return layer(e, at: start)
        }
    }

    /// Clips that end within [time - horizon, time) (playing backward, the next ones to come on screen).
    public func upcomingReverse(before time: Double, within horizon: Double) -> [PreviewLayer] {
        let f = Double(frameIndex(at: time))
        return entries.compactMap { e in
            let endFrame = e.drawEnd
            guard endFrame <= f, endFrame / fps >= time - horizon, e.clip.durationFrames > 0 else { return nil }
            return layer(e, at: (endFrame - 1) / fps)
        }
    }

    /// Source seconds per timeline second: the clip's playback rate, 1 for a held frame (its rate is not read).
    static func sourceRate(_ c: NativeProjectClip) -> Double {
        guard c.holdSourceFrame == nil, let r = c.playbackRate, r.denominator != 0, r.numerator > 0 else { return 1 }
        return r.numerator / r.denominator
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
        // The clip's fade (#85, #89) multiplies the keyframed opacity; export paints this layer too
        // (ExportFramePainter).
        let keyed = max(0, min(1, num("transform.opacity") ?? num("visual.opacity") ?? num("visual.autoAlpha") ?? 1))
        let fade = c.fadeGain(atFrame: local)
        let opacity = keyed * fade
        let box = CanvasRect(x: (num("layout.left") ?? 0) + px, y: (num("layout.top") ?? 0) + py,
                             width: max(0, num("layout.width") ?? canvas.width), height: max(0, num("layout.height") ?? canvas.height))
        let crop = c.crop.map { CropInsets(top: max(0, $0.top), right: max(0, $0.right), bottom: max(0, $0.bottom), left: max(0, $0.left)) } ?? .zero
        let held = c.holdSourceFrame?.sourceFrame
        let rate = Self.sourceRate(c)
        let sourceIn = sourceFrameValue(NativeSourcePosition(sourceInFrame: c.sourceInFrame, sourceInFraction: c.sourceInFraction)) / fps
        var out = PreviewLayer(clipId: c.id, source: e.path, kind: e.kind, start: c.startFrame / fps,
                            end: (c.startFrame + c.durationFrames) / fps, sourceIn: sourceIn, rate: rate,
                            startFrame: Int(c.startFrame.rounded()), endFrame: Int((c.startFrame + c.durationFrames).rounded()),
                            box: box, scaleX: sx, scaleY: sy,
                            rotation: (num("transform.rotation") ?? 0) + autoRotate, opacity: opacity, crop: crop)
        out.fadeGain = fade
        out.hiddenByFade = fade == 0 && keyed > 0
        out.speedRamp = c.speedRamp?.isSupported == true ? c.speedRamp : nil
        out.timelineFPS = fps
        out.motionRotation = autoRotate
        out.holdSourceTime = held.map { $0 / fps }
        // An animated grade decides on its own (nil there means no active grade at this frame, not "use the static one").
        out.grade = e.gradeAnimation.map { $0.renderer(e.clip, values: values) } ?? e.grade
        out.style = (c.style?.isEmpty ?? true) ? nil : c.style
        out.blend = c.style?.blendMode ?? .normal
        out.generator = e.kind == .generator ? c.generator : nil
        out.text = e.kind == .text ? c.text : nil
        out.offlineFileName = e.offlineFileName
        out.fit = c.fit
        out.mediaAspect = e.mediaAspect
        out.fill = e.fill
        out.masks = (c.masks ?? []).filter(\.isSupported).map { mask in
            var evaluated = mask
            if let v = num("mask.\(mask.id).x") { evaluated.x = v }
            if let v = num("mask.\(mask.id).y") { evaluated.y = v }
            if let v = num("mask.\(mask.id).width") { evaluated.width = v }
            if let v = num("mask.\(mask.id).height") { evaluated.height = v }
            if let v = num("mask.\(mask.id).angle") { evaluated.angle = v }
            if let v = num("mask.\(mask.id).feather") { evaluated.feather = v }
            if let v = num("mask.\(mask.id).expansion") { evaluated.expansion = v }
            if let v = num("mask.\(mask.id).opacity") { evaluated.opacity = v }
            if let v = num("mask.\(mask.id).invert") { evaluated.invert = v >= 0.5 }
            if let v = num("mask.\(mask.id).mode") {
                evaluated.mode = ["add", "subtract", "intersect"][min(max(Int(v.rounded()), 0), 2)]
            }
            return evaluated
        }
        out.transform3D = NativeTransform3D(rotationX: num(NativeTransform3D.rotationXId) ?? 0, rotationY: num(NativeTransform3D.rotationYId) ?? 0,
                                            z: num(NativeTransform3D.zId) ?? 0, perspective: num(NativeTransform3D.perspectiveId) ?? 0)
        applyTransitions(e.transitions, to: &out, atFrame: Double(frameIndex(at: time)))
        // Moves go over the static and keyframed values (before fades, which multiply the result).
        return out.moved(by: moveOffsets(c, local: local))
    }

    /// Widens the layer over its transitions' handle frames (one decode lane covers the whole range) and mixes it
    /// for the transition at `frame`: a dissolve scales the incoming clip's opacity, a dip lays its colour over
    /// either clip.
    func applyTransitions(_ t: NativeClipTransitions, to layer: inout PreviewLayer, atFrame frame: Double) {
        if t.lead > 0 {
            if layer.speedRamp != nil { layer.rampStart = layer.start } else { layer.sourceIn -= t.lead * layer.rate / fps }
            layer.start -= t.lead / fps; layer.startFrame -= Int(t.lead)
        }
        if t.tail > 0 { layer.end += t.tail / fps; layer.endFrame += Int(t.tail) }
        let mix: NativeTransitionMix, span: NativeCutTransitionSpan
        if let s = t.incoming, frame >= s.startFrame, frame < s.endFrame { span = s; mix = s.incomingMix(atFrame: frame) }
        else if let s = t.outgoing, frame >= s.startFrame, frame < s.endFrame { span = s; mix = s.outgoingMix(atFrame: frame) }
        else { return }
        if span.kind == .wipe || span.kind == .push {
            layer.spatialTransition = .init(kind: span.kind, direction: span.direction, softness: span.softness,
                                            progress: span.progress(atFrame: frame), incoming: span.toClipId == layer.clipId)
        }
        layer.opacity *= mix.opacity
        if mix.colorAmount > 0 { layer.transitionColor = CanvasColor(hex: span.color); layer.transitionColorAmount = mix.colorAmount }
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

    /// Where a layer's picture lands, in composition px: nativeMediaRect for the clip's `fit` (contain by default, or
    /// the whole box when the box is already the picture's aspect to within rounding, so the picture's edges are the
    /// selection box's edges; cover overflows the box; stretch is the box).
    public static func mediaRect(imageWidth: Int, imageHeight: Int, in box: CanvasRect,
                                 fit: NativeMediaFit? = nil) -> CanvasRect {
        let layout = NativeClipLayoutBox(left: box.x, top: box.y, width: box.width, height: box.height)
        let r = nativeMediaRect(imageWidth: Double(imageWidth), imageHeight: Double(imageHeight), box: layout, fit: fit)
        return CanvasRect(x: r.left, y: r.top, width: r.width, height: r.height)
    }

    /// Composition px -> view px for a frame rect showing the whole canvas at `scale`.
    public static func toView(_ r: CanvasRect, frame: CanvasRect, scale s: Double) -> CanvasRect {
        CanvasRect(x: frame.x + r.x * s, y: frame.y + r.y * s, width: r.width * s, height: r.height * s)
    }

    /// Device pixels the layer's picture covers on screen (the decode target before rounding): the box, or for a
    /// Fill or Stretch layer of known aspect the picture's cover of the box, which is larger than it on one axis.
    public static func screenPixels(_ layer: PreviewLayer, viewScale: Double, backingScale: Double) -> (width: Double, height: Double) {
        let k = viewScale * max(backingScale, 1)
        return coverPixels(layer.box.width * abs(layer.scaleX) * k, layer.box.height * abs(layer.scaleY) * k, layer)
    }

    /// `w` x `h` grown to the smallest size of the media's aspect that covers it, when the layer fills its box.
    /// The decoder fits the picture inside the size it is asked for keeping its aspect, so a Stretch picture is
    /// decoded at its cover too (a box-shaped target would come back letterboxed). The cover is scaled down, aspect
    /// kept, to the engine's picture bound (NATIVE_CANVAS_MAX_SIDE): a 16:9 picture stretched onto a 16384 square
    /// would otherwise ask the export's reader for about 29128 x 16384.
    static func coverPixels(_ w: Double, _ h: Double, _ layer: PreviewLayer) -> (width: Double, height: Double) {
        guard layer.fit?.fillsTheBox == true, let a = layer.mediaAspect, a.isFinite, a > 0, w > 0, h > 0 else {
            return (w, h)
        }
        let cw = max(w, h * a), ch = max(h, w / a)
        let k = min(1, NATIVE_CANVAS_MAX_SIDE / max(cw, ch))
        return (min(NATIVE_CANVAS_MAX_SIDE, cw * k), min(NATIVE_CANVAS_MAX_SIDE, ch * k))
    }

    /// Draws one layer: scale then rotate about the box centre, clip to the cropped box, contain-fit the image.
    public static func draw(_ layer: PreviewLayer, image: CanvasImage, on c: CanvasContext, frame: CanvasRect, scale s: Double) {
        draw(layer, image: Optional(image), on: c, frame: frame, scale: s)
    }

    /// Draws a procedural text or background layer with the shared transform, crop, masks and style.
    public static func drawText(_ layer: PreviewLayer, on c: CanvasContext, frame: CanvasRect, scale s: Double) {
        if let fill = layer.generator.flatMap(PreviewFill.init) {
            let w = max(1, Int((layer.box.width * s * c.deviceScale).rounded())), h = max(1, Int((layer.box.height * s * c.deviceScale).rounded()))
            let image: CanvasImage?
            switch fill.kind {
            case .color(let color): image = CanvasImage(width: 1, height: 1, rgba: [UInt8((color.r * 255).rounded()), UInt8((color.g * 255).rounded()), UInt8((color.b * 255).rounded()), UInt8((color.a * 255).rounded())])
            case .gradient(let angle, let stops): image = CanvasFillPainter.gradientImage(angle: angle, stops: stops, width: w, height: h)
            case .radial(let center, let stops): image = CanvasFillPainter.gradientImage(angle: 0, stops: stops, width: w, height: h, center: center)
            case .blur: image = nil
            }
            if let image { var picture = layer; picture.fit = .stretch; draw(picture, image: image, on: c, frame: frame, scale: s) }
        } else if layer.text != nil { draw(layer, image: nil, on: c, frame: frame, scale: s) }
    }

    static func draw(_ layer: PreviewLayer, image: CanvasImage?, on c: CanvasContext, frame: CanvasRect, scale s: Double) {
        guard layer.isVisible else { return }
        // A blended layer is painted alone, then mixed with the backdrop pixel by pixel: only a raster canvas can be
        // read back, so the preview paints a frame holding a blended layer on one (PreviewCompositor.draw).
        if layer.blend != .normal, let raster = c as? RasterCanvas {
            var plain = layer; plain.blend = .normal
            raster.drawBlended(layer.blend) { drawPlain(plain, image: image, on: $0, frame: frame, scale: s) }
            return
        }
        drawPlain(layer, image: image, on: c, frame: frame, scale: s)
    }

    private static func drawPlain(_ layer: PreviewLayer, image: CanvasImage?, on c: CanvasContext, frame: CanvasRect, scale s: Double) {
        if let transition = layer.spatialTransition {
            var plain = layer; plain.spatialTransition = nil
            drawSpatial(transition, on: c, frame: frame) { canvas, rect, scale in
                drawPlain(plain, image: image, on: canvas, frame: rect, scale: s * scale)
            }
            return
        }
        drawUntransitioned(layer, image: image, on: c, frame: frame, scale: s)
    }

    private static func drawUntransitioned(_ layer: PreviewLayer, image: CanvasImage?, on c: CanvasContext, frame: CanvasRect, scale s: Double) {
        if let cut = layer.fillCutout {
            // An image fill: an ordinary picture layer drawn everywhere but where the clip's own picture lands.
            let quad = CanvasFillPainter.coveredQuad(box: cut.box, crop: cut.crop, fit: cut.fit,
                                                     picture: cut.aspect.map { (Int(($0 * 10_000).rounded()), 10_000) },
                                                     rotation: cut.rotation, scaleX: cut.scaleX, scaleY: cut.scaleY, frame: frame, scale: s)
            if CanvasFillPainter.covers(quad, frame) { return }
            c.withState {
                c.clip(CanvasFillPainter.holePath(canvas: frame, quad: quad))
                drawLayer(layer, image: image, on: c, frame: frame, scale: s)
            }
            return
        }
        if let fill = layer.fill {
            let quad = layer.transform3D.isIdentity
                ? CanvasFillPainter.coveredQuad(box: layer.box, crop: layer.crop, fit: layer.fit, picture: image.map { ($0.width, $0.height) },
                                                rotation: layer.rotation, scaleX: layer.scaleX, scaleY: layer.scaleY, frame: frame, scale: s)
                : []
            CanvasFillPainter.draw(fill, quad: quad, picture: image, opacity: layer.opacity, canvas: frame, scale: s, on: c)
        }
        drawLayer(layer, image: image, on: c, frame: frame, scale: s)
    }

    private static func drawLayer(_ layer: PreviewLayer, image: CanvasImage?, on c: CanvasContext, frame: CanvasRect, scale s: Double) {
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
            var covered = box
            if let image {
                let placed = mediaRect(imageWidth: image.width, imageHeight: image.height,
                                       in: layer.box, fit: layer.fit)
                let picture = toView(placed, frame: frame, scale: s)
                let layerWidth = max(1, Int(box.width.rounded(.up))), layerHeight = max(1, Int(box.height.rounded(.up)))
                let localPicture = CanvasRect(x: picture.x - box.x, y: picture.y - box.y,
                                              width: picture.width, height: picture.height)
                let visibleImage = layer.masks.isEmpty ? image : MaskCoverageRasterizer.applying(
                    layer.masks, to: image, layerWidth: layerWidth, layerHeight: layerHeight, picture: localPicture)
                // Fill overflows the box on one axis: clipped to the box, as object-fit: cover crops it.
                if layer.fit == .fill {
                    c.withState { c.clip(box); c.drawImage(visibleImage, in: picture, opacity: layer.opacity) }
                } else {
                    c.drawImage(visibleImage, in: picture, opacity: layer.opacity)
                }
                covered = picture
            } else if let text = layer.text {
                if layer.masks.isEmpty {
                    if let look = TextLookRenderer.render(text, box: box, scale: s, deviceScale: c.deviceScale) {
                        c.drawImage(look.image, in: look.rect, opacity: layer.opacity)
                    } else {
                        TextLayout.draw(NativeTextRendering.block(text, scale: s), in: box, on: c, opacity: layer.opacity)
                    }
                } else if let image = maskedText(text, masks: layer.masks, box: box, scale: s) {
                    // A masked text layer draws its fill only: the look reaches outside the box the mask is cut from.
                    c.drawImage(image, in: box, opacity: layer.opacity)
                }
            }
            drawTransitionColor(layer, over: covered, on: c)
            if let style = layer.style, style.visibleStrokeWidth > 0, let color = CanvasColor(hex: style.resolvedStrokeColor) {
                // Inside the box edge, like export's drawbox.
                let w = min(style.visibleStrokeWidth * s, min(box.width, box.height) / 2)
                var p = CanvasPath(); p.addRect(box.insetBy(w / 2))
                c.stroke(p, color.withAlpha(color.a * layer.opacity), StrokeStyle(width: w))
            }
        }
    }

    /// A dip transition's colour over the layer's picture (or its box for text), at the dip's amount.
    static func drawTransitionColor(_ layer: PreviewLayer, over rect: CanvasRect, on c: CanvasContext) {
        guard layer.transitionColorAmount > 0, let color = layer.transitionColor else { return }
        var p = CanvasPath(); p.addRect(rect)
        c.fill(p, color.withAlpha(color.a * min(1, layer.transitionColorAmount) * layer.opacity))
    }

    private static func maskedText(_ text: NativeClipText, masks: [NativeClipMask], box: CanvasRect,
                                   scale: Double) -> CanvasImage? {
        let width = max(1, Int(box.width.rounded(.up))), height = max(1, Int(box.height.rounded(.up)))
        guard let canvas = try? RasterCanvas(width: width, height: height) else { return nil }
        canvas.clear(.transparent)
        TextLayout.draw(NativeTextRendering.block(text, scale: scale),
                        in: CanvasRect(x: 0, y: 0, width: box.width, height: box.height), on: canvas, opacity: 1)
        return MaskCoverageRasterizer.applying(masks, to: canvas.image())
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
