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

/// Decoded preview frames keyed by (lane, timeline frame index), bounded by a byte budget (least recently used
/// frames go first; `MemoryBudget.previewFrames`: min(2 GB, 10% of RAM) by default). A frame costs its pixels plus
/// the canvas drawable a draw made from them (`CanvasImage.heldBytes`), which appears after `store`, so the preview
/// calls `fitBudget()` after each draw. A memory-pressure warning halves it for the moment, a critical one empties it. Thread-safe: decoders store from their queues, the UI
/// thread looks frames up.
public final class PreviewFrameCache: @unchecked Sendable {
    public struct Key: Hashable, Sendable { public var lane: String; public var frame: Int }

    private var budget: Int
    /// The byte budget. Lowering it (Settings > Preview cache) evicts least recently used frames down to it now.
    public var budgetBytes: Int {
        get { lock.lock(); defer { lock.unlock() }; return budget }
        set { lock.lock(); defer { lock.unlock() }; budget = max(1, newValue); evict(to: budget, protecting: []) }
    }
    let lock = NSLock()
    var frames: [Key: (image: CanvasImage, tick: UInt64)] = [:]
    var byLane: [String: Set<Int>] = [:]
    var tick: UInt64 = 0
    /// Bytes the frames hold now: pixels plus the drawables made from them. Counted live, because a frame's drawable
    /// is made when it is first drawn, after it was stored. Never read it with `lock` held (NSLock is not recursive).
    public var bytes: Int { lock.lock(); defer { lock.unlock() }; return heldLocked() }
    /// Most bytes held after a store or a `fitBudget()` (tests: never above the budget).
    public private(set) var peakBytes = 0
    var pressureToken: MemoryPressureMonitor.Token?

    public init(budgetBytes: Int = MemoryBudget.previewFrames(), pressure: MemoryPressureMonitor? = .shared) {
        budget = max(1, budgetBytes)
        pressureToken = pressure?.observe { [weak self] level in self?.purge(level) }
    }

    /// Memory pressure: a warning keeps the most recent half of the budget, critical drops everything.
    public func purge(_ level: MemoryPressureMonitor.Level) {
        lock.lock(); defer { lock.unlock() }
        switch level {
        case .warning: evict(to: budget / 2, protecting: [])
        case .critical: frames = [:]; byLane = [:]; lookedUp = []
        }
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return frames.count }

    static func size(_ i: CanvasImage) -> Int { i.heldBytes }

    /// What the frames hold. Call with `lock` held.
    func heldLocked() -> Int { frames.values.reduce(0) { $0 + Self.size($1.image) } }

    /// Frames looked up since the last `fitBudget` (the draw being fitted shows them).
    var lookedUp: Set<Key> = []

    /// Evicts least recently used frames until what they hold (drawables made since they were stored included) fits
    /// the budget again, never one looked up since the last fit (the draw that just ran shows it). The preview calls
    /// it after every draw.
    public func fitBudget() {
        lock.lock(); defer { lock.unlock() }
        peakBytes = max(peakBytes, evict(to: budget, protecting: lookedUp))
        lookedUp = []
    }

    public func store(_ image: CanvasImage, lane: String, frame: Int) {
        lock.lock(); defer { lock.unlock() }
        let key = Key(lane: lane, frame: frame)
        tick += 1
        frames[key] = (image, tick)
        byLane[lane, default: []].insert(frame)
        peakBytes = max(peakBytes, evict(to: budget, protecting: [key]))   // least recently used first
    }

    /// Removes least recently used frames (not in `keep`) until they hold at most `limit`; returns what they hold
    /// then. Call with `lock` held.
    @discardableResult
    func evict(to limit: Int, protecting keep: Set<Key>) -> Int {
        var held = heldLocked()
        guard held > limit else { return held }
        let victims = frames.filter { !keep.contains($0.key) }.sorted { $0.value.tick < $1.value.tick }
        for v in victims {
            if held <= limit { break }
            held -= Self.size(v.value.image)
            remove(v.key)
        }
        return held
    }

    func remove(_ key: Key) {
        guard frames.removeValue(forKey: key) != nil else { return }
        lookedUp.remove(key)
        byLane[key.lane]?.remove(key.frame)
        if byLane[key.lane]?.isEmpty == true { byLane[key.lane] = nil }
    }

    /// Exact frame, refreshing its recency.
    public func frame(lane: String, frame: Int) -> CanvasImage? {
        lock.lock(); defer { lock.unlock() }
        let key = Key(lane: lane, frame: frame)
        guard let hit = frames[key] else { return nil }
        tick += 1; frames[key] = (hit.image, tick); lookedUp.insert(key)
        return hit.image
    }

    public func contains(lane: String, frame: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return frames[Key(lane: lane, frame: frame)] != nil
    }

    /// Best stand-in while `frame` is not decoded yet: the latest frame at or before it, else the nearest after.
    /// Returns the frame index used.
    public func nearest(lane: String, to frame: Int) -> (frame: Int, image: CanvasImage)? {
        lock.lock(); defer { lock.unlock() }
        guard let set = byLane[lane], !set.isEmpty else { return nil }
        let pick = set.filter { $0 <= frame }.max() ?? set.min()!
        let key = Key(lane: lane, frame: pick)
        guard let hit = frames[key] else { return nil }
        tick += 1; frames[key] = (hit.image, tick); lookedUp.insert(key)   // a held frame on screen is in use
        return (pick, hit.image)
    }

    /// Frames of `lane` that are cached in [from, to], ascending.
    public func cachedFrames(lane: String, from: Int, to: Int) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        return (byLane[lane] ?? []).filter { $0 >= from && $0 <= to }.sorted()
    }

    /// Drops a lane's frames outside [from, to] (frames played past are not worth their memory).
    public func trim(lane: String, keeping from: Int, _ to: Int) {
        lock.lock(); defer { lock.unlock() }
        for f in byLane[lane] ?? [] where f < from || f > to { remove(Key(lane: lane, frame: f)) }
    }

    public func removeLane(_ lane: String) {
        lock.lock(); defer { lock.unlock() }
        for f in byLane[lane] ?? [] { remove(Key(lane: lane, frame: f)) }
    }

    /// Lanes that have frames cached.
    public var laneKeys: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(byLane.keys) }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        frames = [:]; byLane = [:]; lookedUp = []
    }
}
