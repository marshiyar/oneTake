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
import OneTakeMedia
import MpvfxShared

/// Where the luma pictures of a range come from: the real decoder in the app, synthetic pictures in tests.
public protocol GlobalMotionFrameSource: Sendable {
    var frameCount: Int { get }
    /// Size of the picture the source decoded from, in pixels: what the cache's translations are expressed in.
    var sourceWidth: Int { get }
    var sourceHeight: Int { get }
    /// Luma of frame `index` at the analysis size (the same size for every frame).
    func luma(at index: Int) throws -> LumaImage
}

/// The saved result: per-frame motion from the previous frame, translations in source pixels. Frame 0 is the
/// reference (no motion, confidence 1).
public struct GlobalMotionCache: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var v: Int
    public var key: String
    public var sourceWidth: Int, sourceHeight: Int
    public var frameRate: Double
    public var sourceStart: Double
    public var frames: [Frame]

    public struct Frame: Codable, Equatable, Sendable {
        public var tx: Double, ty: Double
        /// Radians.
        public var rotation: Double
        public var scale: Double
        public var confidence: Double
    }

    public init(key: String, sourceWidth: Int, sourceHeight: Int, frameRate: Double, sourceStart: Double, frames: [Frame]) {
        self.v = Self.currentVersion; self.key = key; self.sourceWidth = sourceWidth; self.sourceHeight = sourceHeight
        self.frameRate = frameRate; self.sourceStart = sourceStart; self.frames = frames
    }
}

public enum GlobalMotionAnalysis {
    /// The analysis picture is this wide (aspect kept); a wider source is scaled down by the decoder.
    public static let analysisWidth = 640
    static let cacheDirectory = ".motion-cache"
    /// Bumped when the estimator changes what it returns, so old caches stop matching.
    static let algorithmVersion = "gm1"

    // MARK: Cache

    /// The cache key: media identity (project path, size, modification time), range and algorithm version, hashed.
    public static func cacheKey(projectDir: String, source: String, sourceStart: Double, sourceDuration: Double) throws -> String {
        let (_, relative, info) = try resolve(projectDir, source)
        var hasher = SHA256Hasher()
        hasher.update(Array("\(algorithmVersion)|\(relative)|\(info.size)|\(info.mtimeNs)|\(sourceStart)|\(sourceDuration)|\(analysisWidth)".utf8))
        return hasher.finalizeHex()
    }

    static func cachePath(_ projectDir: String, key: String) throws -> String {
        PosixPath.join(PosixPath.join(try ProjectFS.realpath(projectDir), cacheDirectory), key + ".json")
    }

    /// The cached analysis for `key`, or nil when there is none, it cannot be read, or it is from another version
    /// (the caller analyses again; nothing is repaired in place).
    public static func loadCache(projectDir: String, key: String) -> GlobalMotionCache? {
        guard key.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let path = try? cachePath(projectDir, key: key), let data = try? ProjectFS.readData(path),
              let cache = try? JSONDecoder().decode(GlobalMotionCache.self, from: data),
              cache.v == GlobalMotionCache.currentVersion, cache.key == key else { return nil }
        return cache
    }

    /// Writes the cache through the durable write path.
    public static func writeCache(_ cache: GlobalMotionCache, projectDir: String, durableWrite: DurableWrite) throws {
        let path = try cachePath(projectDir, key: cache.key)
        try ProjectFS.mkdirRecursive(PosixPath.dirname(path))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(cache)
        try durableWrite.write(data, to: path, tempName: ".\(cache.key).\(UUID().uuidString.lowercased()).tmp",
                               preserveMode: false, beforeRename: {})
    }

    // MARK: Analysis

    /// Motion of every frame of `source` against the one before, in source pixels. Throws `MediaAbortError` when
    /// cancelled (between frames), with nothing returned.
    public static func analyze(_ source: GlobalMotionFrameSource, estimator: GlobalMotionEstimator = GlobalMotionEstimator(),
                               cancellation: MediaCancellation? = nil,
                               onProgress: (Double) -> Void = { _ in }) throws -> [GlobalMotionCache.Frame] {
        let count = source.frameCount
        var out: [GlobalMotionCache.Frame] = []
        out.reserveCapacity(count)
        var previous: [LumaImage] = []
        onProgress(0)
        for index in 0..<count {
            try cancellation?.throwIfCancelled()
            let image = try source.luma(at: index)
            let pyramid = estimator.pyramid(image)
            if previous.isEmpty {
                out.append(.init(tx: 0, ty: 0, rotation: 0, scale: 1, confidence: 1))
            } else {
                let m = estimator.estimate(from: previous, to: pyramid)
                let factor = Double(source.sourceWidth) / Double(image.width)
                out.append(.init(tx: m.tx * factor, ty: m.ty * factor, rotation: m.rotation, scale: m.scale, confidence: m.confidence))
            }
            previous = pyramid
            if index == count - 1 || index % 8 == 0 { onProgress(Double(index + 1) / Double(count)) }
        }
        try cancellation?.throwIfCancelled()
        return out
    }

    /// Analyses a range of a project video and caches the result; a cache that is already there is returned as is.
    public static func run(projectDir: String, source: String, sourceStart: Double, sourceDuration: Double,
                           durableWrite: DurableWrite, cancellation: MediaCancellation = MediaCancellation(),
                           onProgress: (Double) -> Void = { _ in }) throws -> GlobalMotionCache {
        guard sourceStart.isFinite, sourceStart >= 0, sourceDuration.isFinite, sourceDuration > 0 else {
            throw MediaToolError("Invalid steady shot analysis range")
        }
        let key = try cacheKey(projectDir: projectDir, source: source, sourceStart: sourceStart, sourceDuration: sourceDuration)
        if let cached = loadCache(projectDir: projectDir, key: key) { onProgress(1); return cached }
        let (path, _, _) = try resolve(projectDir, source)
        let frames: GlobalMotionVideoSource
        do { frames = try GlobalMotionVideoSource(path: path, start: sourceStart, duration: sourceDuration) }
        catch let error as MediaError { throw mediaToolError(error) }
        let result: [GlobalMotionCache.Frame]
        do { result = try analyze(frames, cancellation: cancellation, onProgress: onProgress) }
        catch let error as MediaError { throw mediaToolError(error) }
        let cache = GlobalMotionCache(key: key, sourceWidth: frames.sourceWidth, sourceHeight: frames.sourceHeight,
                                      frameRate: frames.frameRate, sourceStart: sourceStart, frames: result)
        try cancellation.throwIfCancelled()
        try writeCache(cache, projectDir: projectDir, durableWrite: durableWrite)
        return cache
    }

    /// The same, on a background task; `cancel()` stops it between frames and writes nothing.
    public static func start(projectDir: String, source: String, sourceStart: Double, sourceDuration: Double,
                             durableWrite: DurableWrite, onProgress: @escaping @Sendable (Double) -> Void = { _ in }) -> GlobalMotionAnalysisJob {
        let cancellation = MediaCancellation()
        let task = Task.detached(priority: .utility) {
            try run(projectDir: projectDir, source: source, sourceStart: sourceStart, sourceDuration: sourceDuration,
                    durableWrite: durableWrite, cancellation: cancellation, onProgress: onProgress)
        }
        return GlobalMotionAnalysisJob(task: task, cancellation: cancellation)
    }

    private static func resolve(_ projectDir: String, _ source: String) throws -> (path: String, relative: String, info: FileInfo) {
        guard !source.isEmpty, !source.contains("\0") else { throw MediaToolError("A project media path is required") }
        let root = try ProjectFS.realpath(projectDir)
        let path = try ProjectFS.realpath(PosixPath.resolve(root, source))
        let offset = PosixPath.relative(root, path)
        if offset.isEmpty || PosixPath.isAbsolute(offset) || offset == ".." || offset.hasPrefix("../") {
            throw MediaToolError("Media must be a file inside this project")
        }
        let info = try ProjectFS.statInfo(path)
        guard info.isFile else { throw MediaToolError("Media must be a regular file") }
        return (path, offset, info)
    }
}

/// A running analysis: `value` waits for it, `cancel()` stops it.
public final class GlobalMotionAnalysisJob: Sendable {
    private let task: Task<GlobalMotionCache, Error>
    private let cancellation: MediaCancellation
    init(task: Task<GlobalMotionCache, Error>, cancellation: MediaCancellation) { self.task = task; self.cancellation = cancellation }
    public func cancel() { cancellation.cancel() }
    public var value: GlobalMotionCache { get async throws { try await task.value } }
}

/// Frames of a video range decoded by the media engine, straight at the analysis size.
struct GlobalMotionVideoSource: GlobalMotionFrameSource, @unchecked Sendable {
    let reader: VideoFrameReader
    let start: Double, frameRate: Double
    let frameCount: Int
    let sourceWidth: Int, sourceHeight: Int
    let width: Int, height: Int

    init(path: String, start: Double, duration: Double) throws {
        reader = try VideoFrameReader(path: path)
        let info = reader.info
        guard !info.isStill, info.width > 0, info.height > 0 else { throw MediaToolError("Select a video clip") }
        let available = min(duration, max(0, info.duration - start))
        guard available > 0 else { throw MediaToolError("Selected clip is outside the video source") }
        frameRate = info.frameRate > 0 ? info.frameRate : 30
        self.start = start
        let n = (available * frameRate).rounded(.down)
        guard n.isFinite, n >= 2, n < 10_000_000 else { throw MediaToolError("Steady shot needs at least two frames to analyse") }
        frameCount = Int(n)
        sourceWidth = info.width; sourceHeight = info.height
        width = min(GlobalMotionAnalysis.analysisWidth, info.width)
        height = max(1, Int((Double(width) * Double(info.height) / Double(info.width)).rounded()))
    }

    func luma(at index: Int) throws -> LumaImage {
        let frame = try reader.frame(at: start + Double(index) / frameRate, width: width, height: height, fit: .stretch)
        return LumaImage(rgba: frame.rgba, width: width, height: height)
    }
}
