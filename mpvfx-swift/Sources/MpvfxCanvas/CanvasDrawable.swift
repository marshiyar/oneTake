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

/// The drawables made from one image's pixels, one per backend type, shared by every copy of the image.
///
/// Thread-safe: images are made on decode and grade queues and drawn on the UI thread; the last copy can be released
/// on any of them, and the drawables go with it.
final class CanvasImageDrawables: @unchecked Sendable {
    let lock = NSLock()
    private var entries: [ObjectIdentifier: CanvasDrawable] = [:]
    private var bytes = 0
    private var conversions = 0

    deinit { CanvasImage.ledger.add(-bytes) }

    var heldBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    var conversionCount: Int { lock.lock(); defer { lock.unlock() }; return conversions }

    /// The kept `D`, or a new one from `make` (kept unless it is nil). `reuse` false replaces the kept one (a
    /// Direct2D bitmap of another render target). `make` runs under the lock, so two threads drawing one image
    /// convert it once.
    func drawable<D: CanvasDrawable>(_ type: D.Type, reuse: (D) -> Bool, make: () -> D?) -> D? {
        lock.lock(); defer { lock.unlock() }
        let id = ObjectIdentifier(type)
        if let kept = entries[id] as? D, reuse(kept) { return kept }
        if let old = entries.removeValue(forKey: id) { change(-old.byteCount) }
        guard let made = make() else { return nil }
        entries[id] = made
        conversions += 1
        change(made.byteCount)
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

    /// What holding this image costs: its pixels plus their drawables. Caches budget this, not `rgba.count`.
    var heldBytes: Int { rgba.count + drawableBytes }

    /// Frees the drawables made from these pixels (memory pressure); the next draw makes them again.
    func releaseDrawables() { drawables.removeAll() }

    /// Bytes held by every live drawable in the process (diagnostics, tests).
    static var liveDrawableBytes: Int { ledger.bytes }
}

extension CanvasImage {
    static let ledger = CanvasDrawableLedger()
}
