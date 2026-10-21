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
// Export paints frame N+1 while frame N encodes: the encoder (MediaWriter) runs on its own thread and takes painted
// frames from a queue bounded to `depth` frames, so memory grows by at most one frame over painting and encoding in
// turn. The encoder gets the same frames and samples in the same order, so the file is byte-identical
// (ExportOverlapTests). Cancel is checked before every frame on both sides: it stops within one frame.
import Foundation
import MpvfxShared

/// One painted output frame on its way to the encoder: its index, its picture and its slice of the mix.
struct ExportPaintedFrame {
    let index: Int
    let rgba: [UInt8]
    let sound: [Float]?
}

/// Encodes painted frames on its own thread, in the order they were submitted. `submit` returns once fewer than
/// `depth` frames are outstanding (queued or encoding), so the caller paints at most one frame ahead with depth 2.
/// The first failure (the encoder's error, or the cancellation) stops the encoder and is rethrown to the caller.
final class ExportEncodePipeline: @unchecked Sendable {
    private let condition = NSCondition()
    private var queue: [ExportPaintedFrame] = []
    private var outstanding = 0
    private var closed = false, stopped = false
    private var failure: Error?
    private let depth: Int
    private let cancellation: MediaCancellation?
    private let encode: (ExportPaintedFrame) throws -> Void

    /// Frames submitted and not yet encoded, at most `depth` (for tests).
    private(set) var mostOutstanding = 0

    init(depth: Int, cancellation: MediaCancellation?, encode: @escaping (ExportPaintedFrame) throws -> Void) {
        self.depth = Swift.max(1, depth)
        self.cancellation = cancellation
        self.encode = encode
        let thread = Thread { [self] in run() }
        thread.name = "MpVFX export encoder"
        thread.stackSize = 8 << 20   // the engine's encoder runs on this thread; secondary threads default to 512 KiB
        thread.start()
    }

    /// Queues `frame`, then waits while `depth` frames are outstanding; throws the encoder's first failure.
    func submit(_ frame: ExportPaintedFrame) throws {
        condition.lock(); defer { condition.unlock() }
        if let failure { throw failure }
        queue.append(frame)
        outstanding += 1
        mostOutstanding = Swift.max(mostOutstanding, outstanding)
        condition.broadcast()
        while outstanding >= depth && failure == nil { condition.wait() }
        if let failure { throw failure }
    }

    /// Waits until every submitted frame is encoded and the thread has ended; throws the encoder's first failure.
    func finish() throws {
        condition.lock(); defer { condition.unlock() }
        closed = true
        condition.broadcast()
        while !stopped { condition.wait() }
        if let failure { throw failure }
    }

    /// Drops the frames still queued and waits for the thread to end (after the painter failed or was cancelled).
    func abandon() {
        condition.lock(); defer { condition.unlock() }
        closed = true
        queue.removeAll()
        condition.broadcast()
        while !stopped { condition.wait() }
    }

    private func run() {
        while let frame = take() {
            do {
                try cancellation?.throwIfCancelled()
                try withAutoreleasePool { try encode(frame) }
                settle(nil)
            } catch {
                settle(error)
                break
            }
        }
        condition.lock(); stopped = true; condition.broadcast(); condition.unlock()
    }

    private func take() -> ExportPaintedFrame? {
        condition.lock(); defer { condition.unlock() }
        while queue.isEmpty && !closed && failure == nil { condition.wait() }
        return queue.isEmpty || failure != nil ? nil : queue.removeFirst()
    }

    private func settle(_ error: Error?) {
        condition.lock(); defer { condition.unlock() }
        outstanding -= 1
        if let error, failure == nil { failure = error }
        condition.broadcast()
    }
}
