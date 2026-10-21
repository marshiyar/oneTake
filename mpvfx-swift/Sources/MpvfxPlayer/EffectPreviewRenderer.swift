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
import MpvfxColor
import MpvfxPanels
import MpvfxShared

/// Look and effect tile demos: the built-in sample picture (`EffectSampleImage`) graded with a tile's grade JSON,
/// through the same `ColorGradeRenderer` and `ColorRenderer` as the preview and export, at the tile's device pixels.
///
/// Work runs on one serial background queue; `preview` never blocks: it answers `.rendering` and calls `onReady`
/// when the picture is cached, and the host redraws. Results sit in an LRU bounded by `budgetBytes`, keyed by the
/// request's key and size. A size outside 2…`maxSide` is refused with a typed failure, never rendered.
public final class EffectPreviewRenderer: @unchecked Sendable {
    struct Key: Hashable { var key: String, width: Int, height: Int }

    /// The largest tile side rendered, in device pixels (a 16:9 tile on a 4x display is well under it).
    public static let maxSide = 2048

    public let budgetBytes: Int
    /// Project folder for resolving a look's LUT path (read on the caller's thread).
    public var projectDir: () -> String? = { nil }
    public var colorRenderer: ColorRenderer = ColorRendering.shared
    /// Called on the background queue when a tile is ready; hosts hop to the UI and redraw.
    public var onReady: (() -> Void)?

    let queue = DispatchQueue(label: "mpvfx.effect-preview", qos: .userInitiated)
    let lock = NSLock()
    var results: [Key: (result: Result<CanvasImage, PreviewFailure>, tick: UInt64)] = [:]
    var pending = Set<Key>()
    var tick: UInt64 = 0
    /// Advanced by `reset`: a render queued before it is dropped when it finishes (it may use the old project's LUT).
    var generation: UInt64 = 0
    public private(set) var bytes = 0
    /// Tiles rendered (tests, diagnostics).
    public private(set) var rendered = 0

    /// The default budget holds a whole visible grid: the 18 Grade preset tiles at the panel's largest request
    /// (`InspectorPanel.maxTilePixels`, 320 x 180) are about 4.1 MB.
    public init(budgetBytes: Int = 8 << 20) {
        self.budgetBytes = max(1, budgetBytes)
    }

    /// The tile for `req`: ready from the cache, else queued and `.rendering`; a refused size fails at once.
    public func preview(_ req: EffectPreviewRequest) -> PresetPreviewState {
        let w = req.pixelWidth, h = req.pixelHeight
        guard (2...Self.maxSide).contains(w), (2...Self.maxSide).contains(h) else { return .failed(.invalidSize(width: w, height: h)) }
        let key = Key(key: "\(req.key)|\(Self.gradeText(req.grade))", width: w, height: h)
        lock.lock()
        if let hit = results[key] {
            tick += 1; results[key] = (hit.result, tick)
            lock.unlock()
            return Self.state(hit.result)
        }
        let queued = !pending.insert(key).inserted
        let gen = generation
        lock.unlock()
        if !queued {
            let dir = projectDir(), renderer = colorRenderer
            queue.async { [weak self] in self?.finish(key, gen, Self.render(req, projectDir: dir, renderer: renderer)) }
        }
        return .rendering
    }

    /// The sample picture at the request's size graded with its grade (a disabled or neutral grade leaves it as drawn).
    public static func render(_ req: EffectPreviewRequest, projectDir: String?, renderer: ColorRenderer) -> Result<CanvasImage, PreviewFailure> {
        let width = req.pixelWidth, height = req.pixelHeight, grade = req.grade
        let sample = EffectSampleImage.make(width: width, height: height)
        guard sample.width == width, sample.height == height else { return .failure(.invalidSize(width: width, height: height)) }
        guard let g = ColorGradeRenderer.forClip(ColorGradeParams(json: grade), clipId: "", projectDir: projectDir) else { return .success(sample) }
        var px = sample.rgba
        renderer.render(g, &px, width: width, height: height, time: 0)
        guard px.count == width * height * 4 else { return .failure(.renderFailed("the \(renderer.backend) renderer returned \(px.count) bytes")) }
        return .success(CanvasImage(width: width, height: height, rgba: px))
    }

    /// The grade as text (cache keys): the tile's grade carries the clip's own grade, so it changes with edits. Keys
    /// are written in the map's order (`keys`, which `ColorGrading.json` fills in a fixed order), so equal grades give
    /// equal text. (`String(describing:)` is not stable: it prints the map's backing dictionary in hash order.)
    static func gradeText(_ grade: NativeJSONObject) -> String {
        "{" + grade.keys.map { k in "\(k):\(grade[k].map(valueText) ?? "null")" }.joined(separator: ",") + "}"
    }

    static func valueText(_ v: NativeJSONValue) -> String {
        switch v {
        case .null: "null"
        case .bool(let b): b ? "true" : "false"
        case .number(let d): "\(d)"
        case .string(let s): "\"\(s)\""
        case .array(let a): "[" + a.map(valueText).joined(separator: ",") + "]"
        case .object(let o): gradeText(o)
        }
    }

    static func state(_ r: Result<CanvasImage, PreviewFailure>) -> PresetPreviewState {
        switch r {
        case .success(let img): .ready(img)
        case .failure(let why): .failed(why)
        }
    }

    /// Stores a finished tile, unless `reset` ran since it was queued (`gen` is then stale and the result is dropped;
    /// `reset` already cleared its pending entry, so a request after the reset renders anew).
    func finish(_ key: Key, _ gen: UInt64, _ result: Result<CanvasImage, PreviewFailure>) {
        lock.lock()
        guard gen == generation else { lock.unlock(); return }
        pending.remove(key)
        tick += 1
        if let old = results[key] { bytes -= Self.size(old.result) }
        results[key] = (result, tick)
        bytes += Self.size(result)
        evict(protecting: key)
        rendered += 1
        lock.unlock()
        onReady?()
    }

    static func size(_ r: Result<CanvasImage, PreviewFailure>) -> Int {
        if case .success(let i) = r { return i.width * i.height * 4 }
        return 0
    }

    func evict(protecting keep: Key) {
        guard bytes > budgetBytes else { return }
        for v in results.filter({ $0.key != keep }).sorted(by: { $0.value.tick < $1.value.tick }) {
            if bytes <= budgetBytes { break }
            if let old = results.removeValue(forKey: v.key) { bytes -= Self.size(old.result) }
        }
    }

    /// Cached tiles (tests).
    public var count: Int { lock.lock(); defer { lock.unlock() }; return results.count }

    /// Drops every cached tile and every render still queued ("Retry look previews", switching projects).
    public func reset() {
        lock.lock(); results = [:]; pending = []; bytes = 0; generation &+= 1; lock.unlock()
    }

    /// Blocks until queued renders have run (tests).
    public func wait() { queue.sync {} }
}
