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
/// back (`release`). A reservation that would take the frames in flight past the budget waits until another one is
/// settled, so cached plus in-flight frames stay within the budget for any number of lanes (issue #97). The one
/// exception is a single frame larger than the whole budget: it is still decoded and kept, alone.
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
            lock.broadcast()
        }
    }
    /// Guards everything below; reservations wait on it for frames in flight to settle.
    let lock = NSCondition()
    var frames: [Key: (image: CanvasImage, tick: UInt64)] = [:]
    var byLane: [String: Set<Int>] = [:]
    var tick: UInt64 = 0
    var cached = 0, inFlight = 0
    var peakCached = 0, peakHeld = 0, peakInFlight = 0
    var pressureToken: MemoryPressureMonitor.Token?

    /// Bytes of the frames cached now.
    public var bytes: Int { lock.lock(); defer { lock.unlock() }; return cached }
    /// Most bytes ever cached at once (tests: never above the budget).
    public var peakBytes: Int { lock.lock(); defer { lock.unlock() }; return peakCached }
    /// Bytes reserved for frames decode lanes are producing now and have not stored yet.
    public var inFlightBytes: Int { lock.lock(); defer { lock.unlock() }; return inFlight }
    /// Most bytes ever held at once counting frames in flight: cached plus reserved (tests, the preview benchmark).
    public var peakHeldBytes: Int { lock.lock(); defer { lock.unlock() }; return peakHeld }
    /// Most bytes ever in flight at once.
    public var peakInFlightBytes: Int { lock.lock(); defer { lock.unlock() }; return peakInFlight }

    public init(budgetBytes: Int = MemoryBudget.previewFrames(), pressure: MemoryPressureMonitor? = .shared) {
        budget = max(1, budgetBytes)
        pressureToken = pressure?.observe { [weak self] level in self?.purge(level) }
    }

    /// Memory pressure: a warning keeps the most recent half of the budget (frames in flight included), critical
    /// drops every cached frame.
    public func purge(_ level: MemoryPressureMonitor.Level) {
        lock.lock(); defer { lock.unlock() }
        switch level {
        case .warning: evict(to: budget / 2 - inFlight, protecting: nil)
        case .critical: frames = [:]; byLane = [:]; cached = 0
        }
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return frames.count }

    static func size(_ i: CanvasImage) -> Int { i.width * i.height * 4 }

    /// Stores a decoded frame. `reserved` is what `reserve` returned for it: those bytes move from in flight to
    /// cached, so a frame that was made room for evicts nothing more when it lands.
    public func store(_ image: CanvasImage, lane: String, frame: Int, reserved: Int = 0) {
        lock.lock(); defer { lock.unlock() }
        settle(reserved)
        let key = Key(lane: lane, frame: frame)
        if let old = frames[key] { cached -= Self.size(old.image) }
        tick += 1
        frames[key] = (image, tick)
        byLane[lane, default: []].insert(frame)
        cached += Self.size(image)
        let room = budget - inFlight
        if cached > room { evict(to: room, protecting: key) }   // least recently used first
        notePeaks()
    }

    /// Counts the `frameBytes` of a frame `lane` is about to decode against the budget, evicting least recently
    /// used frames to make room now rather than after the frame exists. When the frames already in flight leave no
    /// room for it, it waits until one of them is stored or released (a reservation never waits when nothing else
    /// is in flight). The lane's own most recent frame stays while it fits beside the frames in flight: it is what
    /// the layer shows if this decode fails. Returns the bytes reserved: pass them to
    /// `store(_:lane:frame:reserved:)` with the frame, or to `release` when no frame is stored.
    public func reserve(_ frameBytes: Int, lane: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let reserved = max(0, frameBytes)
        while inFlight > 0 && inFlight + reserved > budget { lock.wait() }
        inFlight += reserved
        let room = budget - inFlight
        if cached > room { evict(to: room, protecting: fallback(of: lane, within: room)) }
        notePeaks()
        return reserved
    }

    /// Gives back a reservation whose frame was not stored (the media ended, or the frame was dropped).
    public func release(_ reserved: Int) {
        lock.lock(); defer { lock.unlock() }
        settle(reserved)
    }

    /// A reservation ends: its bytes leave the frames in flight and waiting reservations look again. Call with
    /// `lock` held.
    func settle(_ reserved: Int) {
        inFlight = max(0, inFlight - reserved)
        lock.broadcast()
    }

    /// The most recently used frame of `lane`, when it fits in `room`. Call with `lock` held.
    func fallback(of lane: String, within room: Int) -> Key? {
        guard let held = byLane[lane] else { return nil }
        let entries = held.compactMap { frame in
            frames[Key(lane: lane, frame: frame)].map { (key: Key(lane: lane, frame: frame), entry: $0) }
        }
        guard let newest = entries.max(by: { $0.entry.tick < $1.entry.tick }),
              Self.size(newest.entry.image) <= room else { return nil }
        return newest.key
    }

    /// Call with `lock` held.
    func notePeaks() {
        peakCached = max(peakCached, cached)
        peakHeld = max(peakHeld, cached + inFlight)
        peakInFlight = max(peakInFlight, inFlight)
    }

    func evict(to limit: Int, protecting keep: Key?) {
        guard cached > limit else { return }
        let victims = frames.filter { $0.key != keep }.sorted { $0.value.tick < $1.value.tick }
        for v in victims {
            if cached <= limit { break }
            remove(v.key)
        }
    }

    func remove(_ key: Key) {
        guard let old = frames.removeValue(forKey: key) else { return }
        cached -= Self.size(old.image)
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
        frames = [:]; byLane = [:]; cached = 0
    }
}
