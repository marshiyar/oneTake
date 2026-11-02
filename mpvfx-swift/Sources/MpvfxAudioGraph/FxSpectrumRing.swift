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
import Synchronization

/// One analysed spectrum: `SpectrumAnalyzer.bandCount` levels in dBFS, tagged like a meter reading with the frame of the
/// chain's own count that it was taken for.
public struct FxSpectrumReading: Equatable, Sendable {
    public var frame: Int
    public var bands: [Float]

    public init(frame: Int, bands: [Float]) {
        self.frame = frame
        self.bands = bands
    }
}

/// A small fixed ring of spectra with one writer (the feeder) and any reader (the UI), made like `FxMeterRing`: the bands
/// live in preallocated storage, `publish` copies into the next slot and advances an atomic count with release ordering,
/// and a reader copies a slot and checks that the writer has not come back to it.
public final class FxSpectrumRing: @unchecked Sendable {
    public static let capacity = 16
    private static let guardSlots = 2
    public let bandCount: Int
    private let frames: UnsafeMutablePointer<Int>
    private let levels: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)

    public init(bandCount: Int) {
        self.bandCount = bandCount
        frames = .allocate(capacity: Self.capacity)
        frames.initialize(repeating: Int.min, count: Self.capacity)
        levels = .allocate(capacity: Self.capacity * bandCount)
        levels.initialize(repeating: -90, count: Self.capacity * bandCount)
    }

    deinit {
        frames.deallocate()
        levels.deallocate()
    }

    public var count: Int { written.load(ordering: .acquiring) }

    /// Feeder thread only. `bands` must hold `bandCount` values; nothing is allocated.
    public func publish(frame: Int, bands: UnsafeBufferPointer<Float>) {
        let next = written.load(ordering: .relaxed)
        let slot = next % Self.capacity
        frames[slot] = frame
        var band = 0
        while band < bandCount {
            levels[slot * bandCount + band] = bands[band]
            band += 1
        }
        written.store(next + 1, ordering: .releasing)
    }

    /// The newest spectrum for a frame no later than `frame`, or nil when none that recent is held.
    public func reading(atOrBefore frame: Int) -> FxSpectrumReading? {
        let end = written.load(ordering: .acquiring)
        var index = end - 1
        let oldest = max(0, end - Self.capacity + Self.guardSlots)
        while index >= oldest {
            let slot = index % Self.capacity
            if frames[slot] <= frame {
                let tag = frames[slot]
                let copy = Array(UnsafeBufferPointer(start: levels + slot * bandCount, count: bandCount))
                return written.load(ordering: .acquiring) - index <= Self.capacity - 1 ? FxSpectrumReading(frame: tag, bands: copy) : nil
            }
            index -= 1
        }
        return nil
    }
}
