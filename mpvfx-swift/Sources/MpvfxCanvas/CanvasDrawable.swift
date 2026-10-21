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

/// A backend's drawable form of a `CanvasImage`: a cairo image surface, a CGImage, a Direct2D bitmap. It owns its
/// native resource and frees it in `deinit`.
public protocol CanvasDrawable: AnyObject {
    /// Bytes the native resource holds (counted with the image in the caches' budgets).
    var byteCount: Int { get }
}

/// The drawables made from one image's pixels, shared by every copy of the image: per backend type, the ones for the
/// last `keptPerType` owners (Direct2D render targets; Cairo and Core Graphics have one owner).
///
/// Thread-safe: images are made on decode and grade queues and drawn on the UI thread; the last copy can be released
/// on any of them, and the drawables go with it.
final class CanvasImageDrawables: @unchecked Sendable {
    /// Drawables kept per backend type: a window's target and one offscreen target (a snapshot) drawn in turn each
    /// keep theirs.
    static let keptPerType = 2
    let lock = NSLock()
    /// Per type, least recently used first.
    private var entries: [ObjectIdentifier: [CanvasDrawable]] = [:]
    private var bytes = 0
    private var conversions = 0

    deinit { CanvasImage.ledger.add(-bytes) }

    var heldBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    var conversionCount: Int { lock.lock(); defer { lock.unlock() }; return conversions }

    /// A kept `D` that `reuse` accepts, or a new one from `make` (kept unless it is nil; past `keptPerType` the least
    /// recently used one goes). `make` runs under the lock, so two threads drawing one image convert it once.
    func drawable<D: CanvasDrawable>(_ type: D.Type, reuse: (D) -> Bool, make: () -> D?) -> D? {
        lock.lock(); defer { lock.unlock() }
        let id = ObjectIdentifier(type)
        var list = entries[id] ?? []
        if let i = list.firstIndex(where: { ($0 as? D).map(reuse) ?? false }), let kept = list[i] as? D {
            list.append(list.remove(at: i))
            entries[id] = list
            return kept
        }
        guard let made = make() else { return nil }
        list.append(made)
        conversions += 1
        change(made.byteCount)
        while list.count > Self.keptPerType { change(-list.removeFirst().byteCount) }
        entries[id] = list
        return made
    }

    /// Drops every drawable (they are made again on the next draw).
    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries = [:]
        change(-bytes)
    }

    /// Call with `lock` held.
    private func change(_ delta: Int) { bytes += delta; CanvasImage.ledger.add(delta) }
}

/// Bytes held by every live drawable in the process.
final class CanvasDrawableLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    func add(_ delta: Int) { guard delta != 0 else { return }; lock.lock(); total += delta; lock.unlock() }
    var bytes: Int { lock.lock(); defer { lock.unlock() }; return total }
}

public extension CanvasImage {
    /// The backend drawable of type `D` for these pixels: the one an earlier draw made (of this image or any copy),
    /// or a new one from `make`. `reuse` returning false makes it again (a Direct2D bitmap belongs to one render
    /// target). A nil from `make` is not kept, so the next draw tries again.
    func drawable<D: CanvasDrawable>(_ type: D.Type, reuse: (D) -> Bool = { _ in true }, make: () -> D?) -> D? {
        drawables.drawable(type, reuse: reuse, make: make)
    }

    /// Bytes of the drawables made from these pixels.
    var drawableBytes: Int { drawables.heldBytes }

    /// How many times these pixels were converted to a drawable (diagnostics, tests).
    var drawableConversions: Int { drawables.conversionCount }

    /// What holding this image costs now: its pixels plus their drawables. Caches that count it live budget this.
    var heldBytes: Int { rgba.count + drawableBytes }

    /// What holding this image costs once it is drawn on one target: its pixels plus one drawable of the same size
    /// (a cairo surface, CGImage or Direct2D bitmap of an image is width x height x 4 bytes). Constant, so caches that
    /// keep a running byte count charge it on store and take the same amount back on removal; only a Direct2D image
    /// drawn on a second render target holds one more drawable than this counts (`keptPerType`).
    var drawnBytes: Int { rgba.count * 2 }

    /// Frees the drawables made from these pixels (memory pressure); the next draw makes them again.
    func releaseDrawables() { drawables.removeAll() }

    /// Bytes held by every live drawable in the process (diagnostics, tests).
    static var liveDrawableBytes: Int { ledger.bytes }
}

extension CanvasImage {
    static let ledger = CanvasDrawableLedger()
}
