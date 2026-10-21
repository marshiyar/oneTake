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
/// frames go first; `MemoryBudget.previewFrames`: min(2 GB, 10% of RAM) by default). A memory-pressure warning
/// halves it for the moment, a critical one empties it. Thread-safe: decoders store from their queues, the UI
/// thread looks frames up.
///
/// A frame a decode lane is producing is counted before it exists: the lane reserves its bytes (`reserve`), which
/// evicts to make room, and hands the reservation over with the frame (`store(_:lane:frame:reserved:)`) or gives it
/// back (`release`). So cached plus in-flight frames stay within the budget, not the cached frames alone (issue #97).
public final class PreviewFrameCache: @unchecked Sendable {
    public struct Key: Hashable, Sendable { public var lane: String; public var frame: Int }

    private var budget: Int
    /// The byte budget. Lowering it (Settings > Preview cache) evicts least recently used frames down to it now.
    public var budgetBytes: Int {
        get { lock.lock(); defer { lock.unlock() }; return budget }
        set {
            lock.lock(); defer { lock.unlock() }
            budget = max(1, newValue)
            evict(to: budget - inFlight, protecting: nil)
        }
    }
    let lock = NSLock()
    var frames: [Key: (image: CanvasImage, tick: UInt64)] = [:]
    var byLane: [String: Set<Int>] = [:]
    var tick: UInt64 = 0
    public private(set) var bytes = 0
    /// Most bytes ever held at once (tests: never above the budget).
    public private(set) var peakBytes = 0
    /// Bytes reserved for frames decode lanes are producing now and have not stored yet.
    public var inFlightBytes: Int { lock.lock(); defer { lock.unlock() }; return inFlight }
    var inFlight = 0
    /// Most bytes ever held at once counting frames in flight: cached plus reserved (tests, the preview benchmark).
    public private(set) var peakHeldBytes = 0
    /// Most bytes ever in flight at once.
    public private(set) var peakInFlightBytes = 0
    var pressureToken: MemoryPressureMonitor.Token?

    public init(budgetBytes: Int = MemoryBudget.previewFrames(), pressure: MemoryPressureMonitor? = .shared) {
        budget = max(1, budgetBytes)
        pressureToken = pressure?.observe { [weak self] level in self?.purge(level) }
    }

    /// Memory pressure: a warning keeps the most recent half of the budget, critical drops everything.
    public func purge(_ level: MemoryPressureMonitor.Level) {
        lock.lock(); defer { lock.unlock() }
        switch level {
        case .warning: evict(to: budget / 2, protecting: nil)
        case .critical: frames = [:]; byLane = [:]; bytes = 0
        }
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return frames.count }

    static func size(_ i: CanvasImage) -> Int { i.width * i.height * 4 }

    /// Stores a decoded frame. `reserved` is what `reserve` returned for it: those bytes move from in flight to
    /// cached, so a frame that was made room for evicts nothing more when it lands.
    public func store(_ image: CanvasImage, lane: String, frame: Int, reserved: Int = 0) {
        lock.lock(); defer { lock.unlock() }
        inFlight = max(0, inFlight - reserved)
        let key = Key(lane: lane, frame: frame)
        if let old = frames[key] { bytes -= Self.size(old.image) }
        tick += 1
        frames[key] = (image, tick)
        byLane[lane, default: []].insert(frame)
        bytes += Self.size(image)
        let room = budget - inFlight
        if bytes > room { evict(to: room, protecting: key) }   // least recently used first
        peakBytes = max(peakBytes, bytes)
        notePeaks()
    }

    /// Counts the `frameBytes` of a frame about to be decoded against the budget, evicting least recently used
    /// frames to make room now rather than after the frame exists. The most recently used frame stays (it is the
    /// one most likely on screen). Returns the bytes reserved: pass them to `store(_:lane:frame:reserved:)` with
    /// the frame, or to `release` when no frame is stored.
    public func reserve(_ frameBytes: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let reserved = max(0, frameBytes)
        inFlight += reserved
        let room = budget - inFlight
        if bytes > room { evict(to: room, protecting: newestKey()) }
        notePeaks()
        return reserved
    }

    /// Gives back a reservation whose frame was not stored (the media ended, or the frame was dropped).
    public func release(_ reserved: Int) {
        lock.lock(); defer { lock.unlock() }
        inFlight = max(0, inFlight - reserved)
    }

    /// The most recently used frame. Call with `lock` held.
    func newestKey() -> Key? { frames.max { $0.value.tick < $1.value.tick }?.key }

    /// Call with `lock` held.
    func notePeaks() {
        peakHeldBytes = max(peakHeldBytes, bytes + inFlight)
        peakInFlightBytes = max(peakInFlightBytes, inFlight)
    }

    func evict(to limit: Int, protecting keep: Key?) {
        guard bytes > limit else { return }
        let victims = frames.filter { $0.key != keep }.sorted { $0.value.tick < $1.value.tick }
        for v in victims {
            if bytes <= limit { break }
            remove(v.key)
        }
    }

    func remove(_ key: Key) {
        guard let old = frames.removeValue(forKey: key) else { return }
        bytes -= Self.size(old.image)
        byLane[key.lane]?.remove(key.frame)
        if byLane[key.lane]?.isEmpty == true { byLane[key.lane] = nil }
    }

    /// Exact frame, refreshing its recency.
    public func frame(lane: String, frame: Int) -> CanvasImage? {
        lock.lock(); defer { lock.unlock() }
        let key = Key(lane: lane, frame: frame)
        guard let hit = frames[key] else { return nil }
        tick += 1; frames[key] = (hit.image, tick)
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
        guard let hit = frames[Key(lane: lane, frame: pick)] else { return nil }
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
        frames = [:]; byLane = [:]; bytes = 0
    }
}
