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
// Cooperative cancellation for long media jobs (export renders, imports): the AbortSignal analogue.
import Foundation

/// Cooperative cancellation, the AbortSignal analogue.
public final class MediaCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [() -> Void] = []
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func cancel() {
        lock.lock(); guard !cancelled else { lock.unlock(); return }
        cancelled = true; let hs = handlers; handlers = []; lock.unlock()
        hs.forEach { $0() }
    }
    func onCancel(_ handler: @escaping () -> Void) {
        lock.lock()
        if cancelled { lock.unlock(); handler(); return }
        handlers.append(handler); lock.unlock()
    }
    public func throwIfCancelled() throws { if isCancelled { throw MediaAbortError() } }
}

/// A cancelled operation (`AbortError`).
public struct MediaAbortError: Error, Equatable { public init() {} }
