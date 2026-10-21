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

/// The last picture each clip drew, kept as a stand-in for a paused seek whose lanes have nothing cached (frames
/// evicted by other clips). Bounded like every preview cache: a byte budget with the least recently stored pictures
/// dropped first (the newest is kept even when it alone is larger, so the clip on screen never blanks), only clips
/// drawn by the last draw are kept, and any memory-pressure warning drops them all (they are a convenience, rebuilt
/// by the next draw). Thread-safe: the UI thread draws, the pressure monitor may call from its own queue.
final class PreviewStandIns: @unchecked Sendable {
    struct Entry { var picture: PreviewCompositor.Picture; var tick: UInt64 }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var tick: UInt64 = 0
    private var budget: Int
    private var pressureToken: MemoryPressureMonitor.Token?

    init(budgetBytes: Int, pressure: MemoryPressureMonitor? = .shared) {
        budget = max(1, budgetBytes)
        pressureToken = pressure?.observe { [weak self] level in self?.purge(level) }
    }

    static func size(_ picture: PreviewCompositor.Picture) -> Int { picture.image.width * picture.image.height * 4 }

    /// The byte budget; lowering it drops the least recently stored pictures now.
    var budgetBytes: Int {
        get { lock.lock(); defer { lock.unlock() }; return budget }
        set { lock.lock(); defer { lock.unlock() }; budget = max(1, newValue); trimLocked(keep: newestLocked()) }
    }

    /// Bytes of pictures held (counted in full, even when the frame cache shares their pixels).
    var bytes: Int { lock.lock(); defer { lock.unlock() }; return bytesLocked() }

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    func picture(_ clip: String) -> PreviewCompositor.Picture? {
        lock.lock(); defer { lock.unlock() }
        return entries[clip]?.picture
    }

    /// Keeps `picture` as `clip`'s stand-in, then drops older pictures of other clips until the budget holds.
    func store(_ picture: PreviewCompositor.Picture, clip: String) {
        lock.lock(); defer { lock.unlock() }
        tick += 1
        entries[clip] = Entry(picture: picture, tick: tick)
        trimLocked(keep: clip)
    }

    /// Drops the pictures of clips not in `clips` (not drawn by the last draw, or no longer in the composition).
    func keepOnly(_ clips: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { clips.contains($0.key) }
    }

    func removeAll() { lock.lock(); entries = [:]; lock.unlock() }

    /// Memory pressure, warning or critical: every stand-in goes.
    func purge(_ level: MemoryPressureMonitor.Level) { removeAll() }

    private func newestLocked() -> String? { entries.max { $0.value.tick < $1.value.tick }?.key }

    private func bytesLocked() -> Int { entries.values.reduce(0) { $0 + Self.size($1.picture) } }

    /// Drops the least recently stored pictures (never `keep`) until the bytes fit the budget. Call with `lock` held.
    private func trimLocked(keep: String?) {
        var total = bytesLocked()
        guard total > budget else { return }
        for (clip, entry) in entries.sorted(by: { $0.value.tick < $1.value.tick }) where clip != keep {
            if total <= budget { break }
            total -= Self.size(entry.picture)
            entries[clip] = nil
        }
    }
}
