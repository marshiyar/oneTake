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
// Renders a native timeline (media + JSON) with the media engine, one output frame at a time:
// - pictures: every frame is painted by the installed NativeExportFrameRenderer, which is the preview's own
//   composition, grade and painter (MpvfxPlayer PreviewExportFrames), so the export is the preview's frame; keyframed
//   transforms, crop, style, 3D, text and grades all come from that one code path;
// - sound: the bus/FX graph live playback uses (MpvfxAudioGraph via DocumentAudioGraph), its stems decoded by the
//   media engine, rendered block by block in step with the frames (ExportAudioMix);
// - encoding: MediaWriter (MP4 = H.264 + FLAC, MOV = PNG + LPCM; the media engine's format table), which writes
//   `<output>.partial` and renames it on finish, so a cancelled or failed render leaves no file under the user's name.
import Foundation
import OneTakeMedia
import MpvfxShared
import MpvfxColor

public struct NativeTimelineRenderInput {
    public var project: NativeProjectDocument
    public var projectDir: String
    public var outputPath: String
    public var format: ExportFormat
    public var outputDimensions: ExportDimensions?
    public var outputFps: Double?
    public var quality: ExportQuality?
    public var cancellation: MediaCancellation?
    public var onProgress: ((Double) -> Void)?
    /// Evaluates keyframed parameters; nil uses the process-wide engine (installDefaultKeyframeEngineAtStartup).
    public var keyframeEngine: KeyframeEngine?
    /// Exports only this part of the sequence (project frames); nil exports all of it.
    public var range: ExportFrameRange?
    /// Paints the frames (nil: NativeExportFrames.defaultRenderer, which the app installs at startup).
    public var frameRenderer: NativeExportFrameRendererFactory?
    /// Collects the seconds spent painting and encoding (the export benchmark); nil collects nothing.
    public var stageTimes: NativeExportStageTimes?
    /// Encodes each frame on its own thread while the next one paints (the default). false paints and encodes in
    /// turn on the calling thread: the reference the overlapped output is checked against (ExportOverlapTests) and
    /// the export benchmark's same-machine baseline (MpvfxPreviewBench export-serial).
    public var encodeAhead = true
    public init(project: NativeProjectDocument, projectDir: String, outputPath: String, format: ExportFormat,
                outputDimensions: ExportDimensions? = nil, outputFps: Double? = nil, quality: ExportQuality? = nil,
                cancellation: MediaCancellation? = nil, onProgress: ((Double) -> Void)? = nil,
                keyframeEngine: KeyframeEngine? = nil, range: ExportFrameRange? = nil) {
        self.project = project; self.projectDir = projectDir; self.outputPath = outputPath; self.format = format
        self.outputDimensions = outputDimensions; self.outputFps = outputFps; self.quality = quality
        self.cancellation = cancellation; self.onProgress = onProgress
        self.keyframeEngine = keyframeEngine; self.range = range
    }
}

/// A half-open span of project frames, [startFrame, endFrame).
public struct ExportFrameRange: Equatable, Sendable {
    public var startFrame: Double, endFrame: Double
    public init(startFrame: Double, endFrame: Double) { self.startFrame = startFrame; self.endFrame = endFrame }
}

/// Media the native renderer cannot handle yet (HDR): export refuses it with this message.
public struct UnsupportedNativeMediaError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// One media file as the export reads it (MediaProbe).
struct NativeMediaInfo {
    let path: String; let video: Bool; let audio: Bool; let duration: Double
    /// Natural picture size (pixel aspect, rotation and EXIF orientation applied): sizes clips with an untouched size.
    var natural: NativeMediaNaturalSize? = nil
    /// The file has a sound track at all (`audio` also needs the engine to decode it, e.g. not Opus or MP3).
    var soundTrack = false
}

private let STATIC_PARAMETERS: Set<String> = EXPORT_VISUAL_PARAMETERS.union(EXPORT_AUDIO_PARAMETERS).union(["layout.zIndex"])

private func canvasDimensions(_ canvas: NativeCanvas) -> ExportDimensions { ExportDimensions(width: canvas.width, height: canvas.height) }

/// Unsupported edits are errors, never silently missing from the finished video.
public func assertNativeTimelineSupported(_ project: NativeProjectDocument) throws {
    guard isValidExportOutputDimensions(canvasDimensions(project.canvas)) else { throw MediaToolError("Invalid native canvas dimensions") }
    guard project.canvas.background.range(of: "^#[0-9a-f]{6}(?:[0-9a-f]{2})?$", options: [.regularExpression, .caseInsensitive]) != nil else {
        throw MediaToolError("Native canvas background must be an RGB or RGBA hex color")
    }
    for track in project.sequence.tracks { for clip in track.clips where !project.isUndrawnClip(clip) {
        try assertClipHasMediaPath(clip, project)
        // The color grade (and its stylize effects) renders through MpvfxColor; other effects are not migrated yet.
        if clip.effects.contains(where: { effect in
            effect.enabled && !exportSupportsEffect(effect) && effect.effectId != ColorGradeParams.colorKeyEffectId
        }) { throw MediaToolError("Clip \(clip.id) has effects that have not been migrated to the native renderer") }
        try assertClipParametersSupported(clip)
        if let crop = clip.crop, ![crop.top, crop.right, crop.bottom, crop.left].allSatisfy({ $0.isFinite }) {
            throw MediaToolError("Invalid crop on clip \(clip.id)")
        }
    } }
}

/// A clip's asset exists and names its media file (text clips have none). The message names the asset as the user
/// knows it, never by its internal id.
private func assertClipHasMediaPath(_ clip: NativeProjectClip, _ project: NativeProjectDocument) throws {
    let asset = project.assets.first(where: { $0.id == clip.assetId })
    if let asset, nativeIsTextClip(clip, project) || !(asset.source ?? "").isEmpty { return }
    throw MediaToolError("Media path is missing for \(asset?.name ?? clip.assetId)")
}

private func assertClipParametersSupported(_ clip: NativeProjectClip) throws {
    for track in clip.parameterTracks where !track.keyframes.isEmpty {
        guard let types = exportAnimatableValueTypes(track.parameterId) else {
            throw MediaToolError("Native renderer does not support animating \(track.parameterId) on clip \(clip.id)")
        }
        guard types.contains(track.valueType), track.keyframes.allSatisfy({ k in
            switch k.value { case .number: return track.valueType == .number; case .vec2: return track.valueType == .vec2; default: return false }
        }) else { throw MediaToolError("Invalid native keyframes for \(track.parameterId) on clip \(clip.id)") }
    }
    guard let parameters = clip.staticParameters else { return }
    for id in parameters.keys {
        guard STATIC_PARAMETERS.contains(id) else { throw MediaToolError("Native renderer does not support \(id) on clip \(clip.id)") }
        let vector = id == "transform.position" || id == "transform.scale"
        switch parameters[id] {
        case .number?: break
        case .vec2? where vector: break
        default: throw MediaToolError("Invalid native parameter \(id)")
        }
    }
}

/// Resolves a project-relative media path inside the project (symlinks resolved) and probes it with the engine.
/// HDR media is refused until its colour pipeline exists; a format the engine cannot decode is refused with the
/// engine's user-facing reason.
func probeExportMedia(root: String, source: String) throws -> NativeMediaInfo {
    if PosixPath.isAbsolute(source) || source.range(of: "^[a-z][a-z\\d+.-]*:", options: [.regularExpression, .caseInsensitive]) != nil {
        throw MediaToolError("Native media must be a project-relative file")
    }
    let path = try ProjectFS.realpath(PosixPath.resolve(root, source))
    let offset = PosixPath.relative(root, path)
    if try offset.isEmpty || PosixPath.isAbsolute(offset) || offset == ".." || offset.hasPrefix("../") || !ProjectFS.statInfo(path).isFile {
        throw MediaToolError("Native media must be inside its project")
    }
    let probe: MediaProbe
    do { probe = try MediaProbe.probe(path: path) } catch { throw MediaToolError("\(source) cannot be read: \(error)") }
    if probe.video?.hdr == true {
        throw UnsupportedNativeMediaError(message: "Native timeline export requires SDR media until its HDR color pipeline is implemented")
    }
    if let v = probe.video, !v.decodable { throw MediaToolError(v.reason ?? "The picture of \(source) cannot be decoded") }
    // Sound the engine cannot decode yet (a later codec) is left out, as import brings such a video in without sound.
    let audible = probe.audio?.decodable == true
    let natural = probe.video.map { NativeMediaNaturalSize(width: Double($0.displayWidth), height: Double($0.displayHeight)) }
    var info = NativeMediaInfo(path: path, video: probe.video != nil, audio: audible,
                               duration: probe.duration ?? .nan, natural: natural.flatMap { $0.isValid ? $0 : nil })
    info.soundTrack = probe.audio != nil
    return info
}

/// Muted audio groups dropped from export: a muted group's members are skipped
/// before the mixer, so group/member FX, automation and volume never reach the mix (muteParity.json).
func droppableMutedAudioGroups(_ project: NativeProjectDocument) -> Set<String> {
    Set((project.sequence.audioGroups ?? []).filter { $0.muted == true }.map(\.id))
}

/// Whether the mix uses the bus/FX graph's routing or effects: an (unmuted) audio group, a clip FX chain or
/// automation, or keyframed volume. Every export mixes through the graph; this says whether more than clip gains do.
func exportNeedsAudioGraph(_ project: NativeProjectDocument) -> Bool {
    for track in project.sequence.tracks { for clip in track.clips where !clip.muted {
        if !(clip.audioGroupId ?? "").isEmpty || !(clip.audioFxChain ?? "").isEmpty || !(clip.audioAutomation ?? "").isEmpty { return true }
        if clip.parameterTracks.contains(where: { $0.parameterId == "audio.volume" && !$0.keyframes.isEmpty }) { return true }
    } }
    return false
}

/// The document export renders: hidden tracks, hidden clips (the timeline eye) and element layers the renderer
/// cannot draw (`isUndrawnElementClip`; the saved document keeps them) are left out, picture and sound, while the
/// sequence keeps its length. A muted track is its clips' `muted` flags (the
/// timeline's track mute sets every clip), which the audio mix already silences.
public func nativeExportVisibleProject(_ project: NativeProjectDocument) -> NativeProjectDocument {
    let tracks = project.sequence.tracks
    let skipped = { (clip: NativeProjectClip) in clip.hidden == true || project.isUndrawnClip(clip) }
    guard tracks.contains(where: { $0.hidden == true || $0.clips.contains(where: skipped) }) else { return project }
    var out = project
    out.sequence.durationFrames = sequenceEndFrame(project)
    // Keep detached ownership after hidden audio clips/tracks are removed: losing their link must never
    // make the original video's sound return in ExportAudioMix's filtered document.
    let detached = Set(tracks.flatMap(\.clips).compactMap { $0.audioDetachedFrom?.isEmpty == false ? $0.audioDetachedFrom : nil })
    out.sequence.tracks = tracks.filter { $0.hidden != true }.map { track in
        var t = track
        t.clips.removeAll(where: skipped)
        for index in t.clips.indices where detached.contains(t.clips[index].id) { t.clips[index].muted = true }
        return t
    }
    // A transition to a clip left out is a hard cut, as the preview draws it.
    out = reconcileNativeCutTransitions(out)
    return out
}

/// The last frame anything covers (at least 1).
func sequenceEndFrame(_ project: NativeProjectDocument) -> Double {
    project.sequence.tracks.flatMap(\.clips).reduce(Swift.max(1, project.sequence.durationFrames ?? 0)) {
        Swift.max($0, $1.startFrame + $1.durationFrames)
    }
}

/// Frames in `seconds` at `fps`: a duration within rounding of a whole frame count is that count, else rounded up
/// (exportFrameCount's rule, so the plan the dialog shows is what is written).
func exportOutputFrameCount(_ seconds: Double, fps: Double) -> Int {
    let raw = seconds * fps, nearest = raw.rounded()
    return Swift.max(1, Int(abs(raw - nearest) <= 1e-3 ? nearest : raw.rounded(.up)))
}

/// The frame rate as the rational the container stores (24 → 24/1, 29.97… → 30000/1001).
func exportFrameRateRational(_ fps: Double) -> (numerator: Int, denominator: Int) {
    for den in [1, 1001, 1000] {
        let num = (fps * Double(den)).rounded()
        if abs(num / Double(den) - fps) < 1e-9 { return (Int(num), den) }
    }
    return (Int((fps * 1000).rounded()), 1000)
}

/// What one render writes: the document as it renders, its media, and the output's timing.
struct NativeTimelineRenderPlan {
    var project: NativeProjectDocument
    var root: String
    var media: [String: NativeMediaInfo]
    /// Seconds of the whole sequence, and of the part written ([start, start + outputDuration)).
    var duration: Double, start: Double, outputDuration: Double
    var outputFps: Double
    var width: Int, height: Int
}

/// Checks the input and resolves everything the render needs before a single frame is written.
func planNativeTimelineRender(_ input: inout NativeTimelineRenderInput) throws -> NativeTimelineRenderPlan {
    try input.cancellation?.throwIfCancelled()
    if let refusal = exportFormatCapability(input.format).unsupportedMessage { throw MediaToolError(refusal) }
    if try ProjectFS.entry(input.outputPath) != nil { throw MediaToolError("Native render output already exists") }
    if input.project.sequence.tracks.contains(where: { $0.clips.contains { $0.parameterTracks.contains { !$0.keyframes.isEmpty } } }) && input.keyframeEngine == nil {
        do { input.keyframeEngine = try keyframeEngine() } catch {
            throw MediaToolError("The keyframe engine is not loaded, so animated clips cannot be exported")
        }
    }
    var project = try parseNativeProjectDocument(input.project, engine: input.keyframeEngine)
    try assertNativeTimelineSupported(project)
    if let d = input.outputDimensions, !isValidExportOutputDimensions(d) { throw MediaToolError("Invalid native output dimensions") }
    if let fps = input.outputFps, !fps.isFinite || fps <= 0 || fps > 240 { throw MediaToolError("Invalid native output frame rate") }
    project = nativeExportVisibleProject(project)
    let root = try ProjectFS.realpath(input.projectDir)
    var media: [String: NativeMediaInfo] = [:]
    let used = Set(project.sequence.tracks.flatMap { $0.clips.filter { !nativeIsTextClip($0, project) }.map(\.assetId) })
    for asset in project.assets where used.contains(asset.id) {
        try input.cancellation?.throwIfCancelled()
        media[asset.id] = try probeExportMedia(root: root, source: asset.source ?? "")
    }
    try assertClipsFitTheirMedia(project, media)
    project = nativeExportRenderDocument(project, media)
    let fps = project.frameRate.numerator / project.frameRate.denominator
    let duration = sequenceEndFrame(project) / fps
    var start = 0.0, outputDuration = duration
    if let range = input.range {
        guard range.startFrame.isFinite, range.endFrame.isFinite, range.startFrame >= 0, range.endFrame > range.startFrame,
              range.endFrame / fps <= duration + 1e-9 else { throw MediaToolError("Invalid export range") }
        start = range.startFrame / fps; outputDuration = (range.endFrame - range.startFrame) / fps
    }
    let output = input.outputDimensions ?? canvasDimensions(project.canvas)
    return NativeTimelineRenderPlan(project: project, root: root, media: media, duration: duration, start: start,
                                    outputDuration: outputDuration, outputFps: input.outputFps ?? fps,
                                    width: Int(output.width), height: Int(output.height))
}

/// Every clip has the tracks it draws and plays, and its source range lies inside its media.
private func assertClipsFitTheirMedia(_ project: NativeProjectDocument, _ media: [String: NativeMediaInfo]) throws {
    let fps = project.frameRate.numerator / project.frameRate.denominator
    // The first check, before muted groups are skipped, so a clip in a
    // MUTED (dropped) group without an audio stream fails too (muteParity.json, mutedGroupMemberWithoutAudioStream).
    for track in project.sequence.tracks { for clip in track.clips where !(clip.audioGroupId ?? "").isEmpty && media[clip.assetId]?.soundTrack == false {
        throw MediaToolError("Clip \(clip.id) cannot join an audio group: its media has no audio stream")
    } }
    for clip in project.sequence.tracks.flatMap(\.clips) {
        guard let asset = project.assets.first(where: { $0.id == clip.assetId }), let info = media[asset.id] else { continue }
        if asset.kind != .audio && !info.video { throw MediaToolError("No picture track in \(asset.name)") }
        if asset.kind == .audio && !info.soundTrack { throw MediaToolError("No audio track in \(asset.name)") }
        guard asset.kind != .image else { continue }
        if try heldFrameFits(clip, info, fps: fps) { continue }
        let rate = (clip.playbackRate?.numerator ?? 1) / (clip.playbackRate?.denominator ?? 1)
        let sourceStart = sourceFrameValue(NativeSourcePosition(sourceInFrame: clip.sourceInFrame, sourceInFraction: clip.sourceInFraction)) / fps
        if !info.duration.isFinite || sourceStart + clip.durationFrames / fps * rate > info.duration + 1 / fps {
            throw MediaToolError("Clip \(clip.id) extends beyond its media file")
        }
    }
}

/// A held clip reads one source frame, whatever its length: true when it is held and that frame is in its media
/// (thrown when it is not); false for a clip that plays its source.
private func heldFrameFits(_ clip: NativeProjectClip, _ info: NativeMediaInfo, fps: Double) throws -> Bool {
    guard let held = clip.holdSourceFrame?.sourceFrame else { return false }
    guard info.duration.isFinite, held / fps < info.duration else { throw MediaToolError("Clip \(clip.id) holds a frame past the end of its media file") }
    return true
}

/// The document as the frames and the mix render it: droppable muted groups removed (their clips keep their picture
/// and lose their sound), and untouched media clips at the default box for their natural size, as the preview
/// draws them.
func nativeExportRenderDocument(_ project: NativeProjectDocument, _ media: [String: NativeMediaInfo]) -> NativeProjectDocument {
    var out = project
    let dropped = droppableMutedAudioGroups(project)
    if !dropped.isEmpty {
        for t in out.sequence.tracks.indices { for c in out.sequence.tracks[t].clips.indices
            where dropped.contains(out.sequence.tracks[t].clips[c].audioGroupId ?? "") {
            out.sequence.tracks[t].clips[c].muted = true
            out.sequence.tracks[t].clips[c].audioGroupId = nil
        } }
        out.sequence.audioGroups = out.sequence.audioGroups?.filter { !dropped.contains($0.id) }
    }
    var rendered = nativeDocumentWithNaturalLayouts(out) { $0.naturalSize ?? media[$0.id]?.natural }
    // The probed size travels on the asset, as the preview's probed sizes do, so the painter knows a Fill or Stretch
    // picture's aspect and decodes it at the size it is drawn (PreviewLayer.mediaAspect).
    for i in rendered.assets.indices where rendered.assets[i].naturalSize == nil {
        rendered.assets[i].naturalSize = media[rendered.assets[i].id]?.natural
    }
    return rendered
}

/// The document export paints and mixes once its media is probed: visible tracks only, then the render document.
func nativeExportPreparedDocument(_ project: NativeProjectDocument, media: [String: NativeMediaInfo]) -> NativeProjectDocument {
    nativeExportRenderDocument(nativeExportVisibleProject(project), media)
}

public func renderNativeTimeline(_ input: NativeTimelineRenderInput) throws {
    var input = input
    let plan = try planNativeTimelineRender(&input)
    guard let makeRenderer = input.frameRenderer ?? NativeExportFrames.defaultRenderer else {
        throw MediaToolError(EXPORT_NO_FRAME_RENDERER_MESSAGE)
    }
    // Sound first (decoding the stems is the slow part of the mix): 0...10 % of the progress when there is any.
    let mix = try ExportAudioMix(plan, engine: input.keyframeEngine, cancellation: input.cancellation,
                                 onProgress: { [onProgress = input.onProgress] in onProgress?($0 * 10) })
    var request = NativeExportFrameRequest(document: plan.project, projectDir: plan.root, width: plan.width, height: plan.height)
    request.transparentPad = input.format == .mov
    request.keyframeEngine = input.keyframeEngine
    let frames = try makeRenderer(request)
    let writer = try openExportWriter(input, plan, hasAudio: mix != nil)
    try encodeNativeTimeline(NativeTimelineEncode(plan: plan, frames: frames, mix: mix, writer: writer), input,
                             progressRange: mix == nil ? 0...100 : 10...100)
    do { try writer.finish() } catch { throw MediaToolError("The export could not be finished: \(error)") }
    input.onProgress?(100)
}

private func openExportWriter(_ input: NativeTimelineRenderInput, _ plan: NativeTimelineRenderPlan, hasAudio: Bool) throws -> MediaWriter {
    var config = MediaWriter.Config(container: input.format == .mov ? .mov : .mp4, width: plan.width, height: plan.height)
    let rate = exportFrameRateRational(plan.outputFps)
    config.fpsNumerator = rate.numerator; config.fpsDenominator = rate.denominator
    config.quality = { switch input.quality ?? .standard { case .draft: return .draft; case .standard: return .standard; case .high: return .high } }()
    config.audioRate = hasAudio ? EXPORT_AUDIO_SAMPLE_RATE : 0
    config.audioChannels = 2
    do { return try MediaWriter(path: input.outputPath, config: config) } catch {
        throw MediaToolError("The export could not be started: \(error)")
    }
}

/// The parts of one encode the frame loop drives.
struct NativeTimelineEncode {
    let plan: NativeTimelineRenderPlan
    let frames: NativeExportFrameRenderer
    let mix: ExportAudioMix?
    let writer: MediaWriter
}

/// Paints and writes every output frame, the mix's samples up to the end of each frame after it, so the muxer
/// interleaves them; the audio track ends exactly at the video's end. Progress maps the encoded frames onto
/// `progressRange`. With `encodeAhead` the encoder runs on its own thread one frame behind the painter
/// (ExportEncodePipeline, 2 frames); otherwise each frame is painted and encoded in turn on this thread.
private func encodeNativeTimeline(_ encode: NativeTimelineEncode, _ input: NativeTimelineRenderInput,
                                  progressRange: ClosedRange<Double>) throws {
    let count = exportOutputFrameCount(encode.plan.outputDuration, fps: encode.plan.outputFps)
    let painter = NativeTimelineFramePainter(encode, input, count: count)
    let write = nativeTimelineFrameWriter(encode, input, count: count, progressRange: progressRange)
    guard input.encodeAhead else {
        for i in 0..<count {
            try input.cancellation?.throwIfCancelled()
            try withAutoreleasePool { try write(painter.paint(i)) }
        }
        return
    }
    let pipeline = ExportEncodePipeline(depth: EXPORT_ENCODE_QUEUE_FRAMES, cancellation: input.cancellation, encode: write)
    do {
        for i in 0..<count {
            try input.cancellation?.throwIfCancelled()
            // Frame 0 encodes before frame 1 paints: the decoder's and the encoder's start-up buffers, the largest
            // either allocates, are then never live at the same time (they set the export's peak memory otherwise).
            try withAutoreleasePool { try pipeline.submit(painter.paint(i), drain: i == 0) }
        }
        try pipeline.finish()
    } catch {
        pipeline.abandon()
        throw error
    }
}

/// Painted frames export holds at once: the one encoding and the one painting.
let EXPORT_ENCODE_QUEUE_FRAMES = 2

/// Paints output frame `i` and mixes the sound up to its end. Used on one thread, in frame order.
private final class NativeTimelineFramePainter {
    let encode: NativeTimelineEncode
    let stageTimes: NativeExportStageTimes?
    let totalSamples: Int
    var written = 0

    init(_ encode: NativeTimelineEncode, _ input: NativeTimelineRenderInput, count: Int) {
        self.encode = encode
        stageTimes = input.stageTimes
        let samples = Double(EXPORT_AUDIO_SAMPLE_RATE)
        totalSamples = Int((Double(count) / encode.plan.outputFps * samples).rounded())
        encode.mix?.skip(to: Int((encode.plan.start * samples).rounded()))
    }

    func paint(_ i: Int) throws -> ExportPaintedFrame {
        let plan = encode.plan
        let t0 = NativeExportStageTimes.now()
        let rgba = try encode.frames.frame(at: plan.start + Double(i) / plan.outputFps)
        var sound: [Float]?
        if let mix = encode.mix {
            let end = Int((Double(i + 1) / plan.outputFps * Double(EXPORT_AUDIO_SAMPLE_RATE)).rounded())
            let target = Swift.min(totalSamples, end)
            sound = try mix.next(target - written)
            written = target
        }
        stageTimes?.addPaint(NativeExportStageTimes.now() - t0)
        return ExportPaintedFrame(index: i, rgba: rgba, sound: sound)
    }
}

/// Hands one painted frame to the writer and reports the progress it reached (on the encoder's thread).
private func nativeTimelineFrameWriter(_ encode: NativeTimelineEncode, _ input: NativeTimelineRenderInput, count: Int,
                                       progressRange: ClosedRange<Double>) -> (ExportPaintedFrame) throws -> Void {
    let writer = encode.writer, stageTimes = input.stageTimes, onProgress = input.onProgress
    let span = progressRange.upperBound - progressRange.lowerBound
    return { frame in
        let t0 = NativeExportStageTimes.now()
        try writer.addVideo(frame.rgba)
        if let sound = frame.sound { try writer.addAudio(sound) }
        stageTimes?.addEncode(NativeExportStageTimes.now() - t0)
        onProgress?(progressRange.lowerBound + span * Swift.min(0.999, Double(frame.index + 1) / Double(count)))
    }
}
