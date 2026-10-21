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
import MpvfxPlayer
import MpvfxShared
#if os(Windows)
import WinSDK
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Preview playback benchmark through the app's own path: PreviewCompositor -> PreviewDecodeLane -> MediaFrameStream ->
// VideoFrameReader (engine decode, convert, scale, FFI copy) -> PreviewGrader -> PreviewPainter on the platform canvas
// (Cairo on Linux, Core Graphics on macOS). Build with -c release; scripts/preview-bench.sh makes the fixtures
// (--make-clips) and runs every scenario in its own process (so peak memory is per scenario), appending one JSON line
// per run to a file.
//
//   MpvfxPreviewBench <scenario> <fixtures dir> <results file> [frames] [--no-realtime]
//   MpvfxPreviewBench --make-clips <fixtures dir>   (writes the clips with the media engine's encoder; Clips.swift)
//   (--no-realtime: playback only, for allocation counts under valgrind --tool=dhat)
//   scenarios: 1080p, 4k, stacked, graded, scrub

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

/// Peak resident memory of this process, in MiB.
func peakMiB() -> Double {
    #if os(Windows)
    var c = PROCESS_MEMORY_COUNTERS()
    c.cb = DWORD(MemoryLayout<PROCESS_MEMORY_COUNTERS>.size)
    guard K32GetProcessMemoryInfo(GetCurrentProcess(), &c, c.cb) else { return 0 }
    return Double(c.PeakWorkingSetSize) / 1_048_576
    #else
    var u = rusage()
    #if canImport(Darwin)
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_maxrss) / 1_048_576
    #else
    getrusage(RUSAGE_SELF.rawValue, &u)
    return Double(u.ru_maxrss) / 1024
    #endif
    #endif
}

/// An offscreen canvas of the display size, drawn like the preview view's.
final class Screen {
    let canvas: CanvasContext
    #if os(Linux)
    let target: CairoImageTarget
    init(width: Int, height: Int) { target = CairoImageTarget(width: width, height: height); canvas = target.canvas }
    #elseif canImport(CoreGraphics)
    let context: CGContext
    init(width: Int, height: Int) {
        guard let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("no bitmap context")
        }
        context = c; canvas = CoreGraphicsCanvas(context: c)
    }
    #else
    init(width: Int, height: Int) {
        guard let c = try? RasterCanvas(width: width, height: height) else { fatalError("no raster canvas") }
        canvas = c
    }
    #endif
}

struct Clip { var file: String; var track: Int; var opacity = 1.0; var grade: String? = nil }

/// A 1920x1080 30 fps project with `clips` stacked bottom first, each covering `seconds` from frame 0.
func document(_ clips: [Clip], dir: String, seconds: Double) throws -> NativeProjectDocument {
    let frames = Int(seconds * 30)
    let assets = clips.enumerated().map { i, c in
        #"{"id":"a\#(i)","kind":"video","name":"\#(c.file)","source":"\#(dir)/\#(c.file)","durationFrames":\#(frames)}"#
    }
    let tracks = clips.enumerated().reversed().map { i, c in
        let fx = c.grade.map { #"{"id":"g","effectId":"color-grading","enabled":true,"parameters":\#($0)}"# } ?? ""
        return #"{"id":"t\#(i)","kind":"video","lane":{"authoredTrack":\#(i + 1),"displayTrack":\#(clips.count - 1 - i)},"clips":[{"id":"c\#(i)","assetId":"a\#(i)","startFrame":0,"durationFrames":\#(frames),"sourceInFrame":0,"muted":false,"staticParameters":{"visual.opacity":\#(c.opacity)},"effects":[\#(fx)],"parameterTracks":[]}]}"#
    }
    let json = ##"{"schemaVersion":1,"id":"project:bench","revision":1,"frameRate":{"numerator":30,"denominator":1},"canvas":{"width":1920,"height":1080,"background":"#000000"},"assets":[\##(assets.joined(separator: ","))],"sequence":{"id":"s","name":"Main","tracks":[\##(tracks.joined(separator: ","))]}}"##
    return try parseNativeProjectDocument(try NativeJSONValue.parse(json))
}

/// A typical primary grade: exposure, contrast, temperature, saturation and a midtone wheel.
let typicalGrade = #"{"adjust":{"exposure":0.3,"contrast":0.2,"temperature":0.15,"saturation":0.2},"wheels":{"midtones":{"hue":30,"amount":0.2,"level":0.05}}}"#

/// Drives a compositor the way the preview view does and times each part.
final class Run {
    let compositor = PreviewCompositor()
    let screen: Screen
    let rect: CanvasRect
    let ready = DispatchSemaphore(value: 0)
    var paintSeconds = 0.0, draws = 0, stalls = 0

    init(_ doc: NativeProjectDocument, width: Int, height: Int) {
        screen = Screen(width: width, height: height)
        rect = CanvasRect(x: 0, y: 0, width: Double(width), height: Double(height))
        compositor.composition = PreviewComposition(document: doc, projectDir: nil, engine: nil)
        compositor.frameReady = { [ready] in ready.signal() }
    }

    func draw(_ time: Double, playing: Bool) -> Bool {
        let t0 = now()
        compositor.draw(screen.canvas, in: rect, time: time, elements: [], context: FrameDrawContext(isPlaying: playing))
        paintSeconds += now() - t0; draws += 1
        return compositor.lastShown.allSatisfy { $0.exact && $0.gradeCurrent }
    }

    /// Draws `time` until every layer shows its exact, fully graded frame (a stall after 10 s is counted and skipped).
    func show(_ time: Double, playing: Bool) {
        while !draw(time, playing: playing) {
            if ready.wait(timeout: .now() + 10) == .timedOut { stalls += 1; return }
        }
    }

    /// Engine time per stage summed over the lanes, and the Swift-side seconds getting frames.
    func engineTotals() -> (stats: [String: Double], frames: Int, pictures: Int, lane: Double) {
        var s: [String: Double] = [:], frames = 0, pictures = 0, lane = 0.0
        for l in compositor.lanes.values {
            if let e = try? l.engineStats() {
                s["decode", default: 0] += e.decode; s["convert", default: 0] += e.convert
                s["scale", default: 0] += e.scale
                frames += e.frames; pictures += e.pictures
            }
            lane += l.decodeSeconds
        }
        return (s, frames, pictures, lane)
    }
}

func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

/// Unthrottled forward playback: every frame shown exactly, as fast as the pipeline delivers them.
func playback(_ run: Run, frames: Int) -> [String: String] {
    _ = run.draw(0, playing: false); run.show(0, playing: false)
    let t0 = now(), paint0 = run.paintSeconds, draws0 = run.draws
    for f in 0..<frames { run.show(Double(f) / 30, playing: true) }
    let wall = now() - t0
    let e = run.engineTotals()
    let n = Double(max(1, e.frames))
    var out: [String: String] = ["fps": fmt(Double(frames) / wall), "wall_ms_per_frame": fmt(wall / Double(frames) * 1000)]
    for (k, v) in e.stats { out["\(k)_ms"] = fmt(v / n * 1000) }
    let engine = e.stats.values.reduce(0, +)
    out["ffi_swift_ms"] = fmt(max(0, e.lane - engine) / n * 1000)
    out["grade_ms"] = fmt(run.compositor.grader.busySeconds / Double(frames) * 1000)
    out["paint_ms_per_draw"] = fmt((run.paintSeconds - paint0) / Double(max(1, run.draws - draws0)) * 1000)
    out["frames_decoded"] = "\(e.frames)"; out["pictures_decoded"] = "\(e.pictures)"; out["stalls"] = "\(run.stalls)"
    return out
}

/// Sleeps until `deadline` (a `now()` value), rounding the wait up a microsecond so the wake is never early.
func sleepUntil(_ deadline: Double) {
    let wait = deadline - now()
    if wait > 0 { usleep(UInt32(min(1, wait) * 1e6) + 1) }
}

/// Real-time playback for `seconds` at 30 draws per second, as the display timer drives it: the share of draws that
/// showed every layer's exact frame (the rest held an earlier frame), how many different pictures reached the screen
/// per second (smoothness: 30 is every frame), how far the shown frame trailed the playhead, and the draw cadence
/// (`DrawCadence`: draw interval and wake lateness p95 and max, draws that repeated the previous picture). Each draw is
/// due in the middle of its frame, so OS wake jitter under half a frame never decides which frame a draw samples.
func realtime(_ doc: NativeProjectDocument, width: Int, height: Int, seconds: Double) -> [String: String] {
    let run = Run(doc, width: width, height: height)
    run.show(0, playing: false)
    guard var cadence = DrawCadence(fps: 30) else { return [:] }
    var exact = 0, lag = 0
    let t0 = now()
    while true {
        sleepUntil(t0 + cadence.deadline(cadence.starts.count))
        let t = now() - t0
        if t >= seconds { break }
        _ = run.draw(t, playing: true)
        let shown = run.compositor.lastShown
        if shown.allSatisfy({ $0.exact }) { exact += 1 }
        cadence.record(start: t, frames: shown.map(\.frame))
        let want = Int((t * 30 + 1e-6).rounded(.down))
        lag += shown.compactMap(\.frame).map { max(0, want - $0) }.max() ?? 0
    }
    var out = laneTotals(run)
    run.compositor.stopAll()
    let draws = Double(max(1, cadence.starts.count))
    out["realtime_exact_pct"] = fmt(Double(exact) / draws * 100)
    out["realtime_draws"] = "\(cadence.starts.count)"
    out["realtime_new_frames_per_s"] = fmt(Double(cadence.changes) / seconds)
    out["realtime_mean_lag_frames"] = fmt(Double(lag) / draws)
    for (key, value) in cadence.metrics() { out["realtime_\(key)"] = fmt(value) }
    return out
}

/// Restarts, decoded and skipped frames summed over the run's decode lanes.
func laneTotals(_ run: Run) -> [String: String] {
    let lanes = run.compositor.lanes.values
    return ["realtime_lane_restarts": "\(lanes.reduce(0) { $0 + $1.restarts })",
            "realtime_frames_decoded": "\(lanes.reduce(0) { $0 + $1.framesDecoded })",
            "realtime_frames_skipped": "\(lanes.reduce(0) { $0 + $1.framesSkipped })"]
}

/// Random seeks while paused: time until the exact frame is on screen.
func scrub(_ run: Run, seeks: Int, duration: Double) -> [String: String] {
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    var latencies: [Double] = []
    for _ in 0..<seeks {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let frame = Int((seed >> 33) % UInt64(duration * 30 - 1))
        let t0 = now()
        run.show(Double(frame) / 30, playing: false)
        latencies.append(now() - t0)
    }
    let sorted = latencies.sorted()
    let mean = latencies.reduce(0, +) / Double(max(1, latencies.count))
    let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    return ["seek_mean_ms": fmt(mean * 1000), "seek_p95_ms": fmt(p95 * 1000), "seek_max_ms": fmt((sorted.last ?? 0) * 1000),
            "seeks": "\(seeks)", "stalls": "\(run.stalls)"]
}

func scenario(_ name: String) -> (clips: [Clip], seconds: Double)? {
    switch name {
    case "1080p": return ([Clip(file: "clip1080.mp4", track: 0)], 10)
    case "4k": return ([Clip(file: "clip2160.mp4", track: 0)], 6)
    case "stacked": return ([Clip(file: "clip1080.mp4", track: 0), Clip(file: "clip1080b.mp4", track: 1, opacity: 0.6)], 10)
    case "graded": return ([Clip(file: "clip1080.mp4", track: 0, grade: typicalGrade)], 10)
    case "scrub": return ([Clip(file: "clip1080.mp4", track: 0)], 10)
    default: return nil
    }
}

func main() throws {
    let args = CommandLine.arguments
    if args.count == 3 && args[1] == "--make-clips" { try makeClips(args[2]); return }
    guard args.count >= 4, let sc = scenario(args[1]) else {
        print("usage: MpvfxPreviewBench <1080p|4k|stacked|graded|scrub> <fixtures dir> <results file> [frames]")
        print("       MpvfxPreviewBench --make-clips <fixtures dir>"); exit(2)
    }
    let (width, height) = (1280, 720)
    let doc = try document(sc.clips, dir: args[2], seconds: sc.seconds)
    let frames = args.count > 4 ? Int(args[4]) ?? 120 : Int(sc.seconds * 30) - 2
    var result: [String: String] = ["scenario": args[1], "display": "\(width)x\(height)"]
    let run = Run(doc, width: width, height: height)
    if args[1] == "scrub" {
        result.merge(scrub(run, seeks: min(frames, 40), duration: sc.seconds)) { $1 }
    } else {
        result.merge(playback(run, frames: frames)) { $1 }
    }
    run.compositor.stopAll()
    if args[1] != "scrub" && !args.contains("--no-realtime") { result.merge(realtime(doc, width: width, height: height, seconds: min(5, sc.seconds - 0.5))) { $1 } }
    result["peak_rss_mib"] = fmt(peakMiB())
    let line = result.keys.sorted().map { "\"\($0)\":\"\(result[$0] ?? "")\"" }.joined(separator: ",")
    print("{\(line)}")
    let handle = FileHandle(forWritingAtPath: args[3]) ?? {
        _ = FileManager.default.createFile(atPath: args[3], contents: nil)
        return FileHandle(forWritingAtPath: args[3])
    }()
    handle?.seekToEndOfFile(); handle?.write(Data("{\(line)}\n".utf8)); handle?.closeFile()
}

try main()
