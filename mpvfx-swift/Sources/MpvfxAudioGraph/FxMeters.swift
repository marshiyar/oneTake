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

/// The levels of one block of sound at a module: input and output peak and RMS as linear amplitudes, and how far a
/// dynamics processor pulled the sound down. `frame` is the frame of the chain's own count (the clip's, or the bus's
/// from the start of the project) that the block is heard at, so a reader that knows what is being heard picks the
/// reading that belongs to it, not the newest one the feeder has queued.
public struct FxMeterReading: Equatable, Sendable {
    public var frame: Int
    public var inputPeak: Float
    public var inputRMS: Float
    public var outputPeak: Float
    public var outputRMS: Float
    /// The lowest linear gain a dynamics processor applied in the block (1: none). Other modules leave it at 1.
    public var lowestGain: Float

    public init(frame: Int, inputPeak: Float = 0, inputRMS: Float = 0, outputPeak: Float = 0, outputRMS: Float = 0,
                lowestGain: Float = 1) {
        self.frame = frame
        self.inputPeak = inputPeak; self.inputRMS = inputRMS
        self.outputPeak = outputPeak; self.outputRMS = outputRMS
        self.lowestGain = lowestGain
    }

    /// How many dB the processor took off at its deepest in the block: 0 for none, positive when reducing.
    public var gainReductionDb: Double { -Self.decibels(lowestGain) }
    public var inputPeakDb: Double { Self.decibels(inputPeak) }
    public var inputRMSDb: Double { Self.decibels(inputRMS) }
    public var outputPeakDb: Double { Self.decibels(outputPeak) }
    public var outputRMSDb: Double { Self.decibels(outputRMS) }

    /// A linear amplitude in dBFS, floored at -120.
    public static func decibels(_ amplitude: Float) -> Double {
        amplitude > 1e-6 ? 20 * log10(Double(amplitude)) : -120
    }
}

/// The peak and RMS of one block, measured without allocating.
struct FxLevel {
    var peak: Float = 0
    var rms: Float = 0

    init() {}

    init(_ planes: [[Float]]) {
        var highest: Float = 0
        var energy = 0.0
        var count = 0
        var channel = 0
        while channel < planes.count {
            let length = planes[channel].count
            count += length
            var index = 0
            while index < length {
                let sample = planes[channel][index]
                let magnitude = sample < 0 ? -sample : sample
                if magnitude > highest { highest = magnitude }
                energy += Double(sample) * Double(sample)
                index += 1
            }
            channel += 1
        }
        peak = highest
        rms = count > 0 ? Float((energy / Double(count)).squareRoot()) : 0
    }
}

/// A fixed-size ring of readings with one writer (the feeder thread) and any reader (the UI). It never allocates and
/// never locks: `publish` stores a reading in its slot and then advances an atomic count with release ordering, and a
/// reader takes a copy of a slot and checks the count again, discarding a copy the writer could have reached. The
/// reader looks at most `capacity - guardSlots` readings back, so the slot being written is never one it trusts.
public final class FxMeterRing: @unchecked Sendable {
    public static let capacity = 256
    private static let guardSlots = 8
    private let slots: UnsafeMutablePointer<FxMeterReading>
    private let written = Atomic<Int>(0)

    public init() {
        slots = .allocate(capacity: Self.capacity)
        slots.initialize(repeating: FxMeterReading(frame: Int.min), count: Self.capacity)
    }

    deinit {
        slots.deinitialize(count: Self.capacity)
        slots.deallocate()
    }

    /// Readings published so far.
    public var count: Int { written.load(ordering: .acquiring) }

    /// Feeder thread only.
    public func publish(_ reading: FxMeterReading) {
        let next = written.load(ordering: .relaxed)
        slots[next % Self.capacity] = reading
        written.store(next + 1, ordering: .releasing)
    }

    /// The newest reading for a frame no later than `frame`, or nil when none that recent is held.
    public func reading(atOrBefore frame: Int) -> FxMeterReading? {
        let end = written.load(ordering: .acquiring)
        var index = end - 1
        let oldest = max(0, end - Self.capacity + Self.guardSlots)
        while index >= oldest {
            let copy = slots[index % Self.capacity]
            if copy.frame <= frame {
                // Still ours if the writer has not come within a ring of the slot while it was copied.
                return written.load(ordering: .acquiring) - index <= Self.capacity - 1 ? copy : nil
            }
            index -= 1
        }
        return nil
    }
}

/// The rings of one FX chain: one for the chain as a whole and one per enabled module, in `enabledNodes` order.
/// Publishing is off until a reader asks for it, so a render nobody watches (an export) pays nothing.
public final class FxChainMeters: @unchecked Sendable {
    public let chain = FxMeterRing()
    public let nodes: [FxMeterRing]
    public let nodeIds: [String?]
    public let enabled = Atomic<Bool>(false)
    /// The enabled module (by place, as `nodes`) whose input and output are analysed into a spectrum; -1: none. Only
    /// one is watched at a time, since each analysis is a 4096-point transform per 2048 frames.
    public let watchedNode = Atomic<Int>(-1)
    public let spectrumInput = FxSpectrumRing(bandCount: SpectrumAnalyzer.bandCount)
    public let spectrumOutput = FxSpectrumRing(bandCount: SpectrumAnalyzer.bandCount)

    public init(nodeIds: [String?]) {
        self.nodeIds = nodeIds
        nodes = nodeIds.map { _ in FxMeterRing() }
    }

    public var isEnabled: Bool {
        get { enabled.load(ordering: .relaxed) }
        set { enabled.store(newValue, ordering: .relaxed) }
    }

    /// The readings that belong to chain frame `frame`.
    public func snapshot(atOrBefore frame: Int) -> FxMeterSnapshot {
        FxMeterSnapshot(chain: chain.reading(atOrBefore: frame), nodes: nodes.map { $0.reading(atOrBefore: frame) })
    }
}

/// What the UI reads for one rack: the chain's levels and each enabled module's (nil: nothing rendered for that time).
public struct FxMeterSnapshot: Equatable, Sendable {
    public var chain: FxMeterReading?
    public var nodes: [FxMeterReading?]

    public init(chain: FxMeterReading? = nil, nodes: [FxMeterReading?] = []) {
        self.chain = chain
        self.nodes = nodes
    }
}

/// A unit that knows how far it pulled the sound down in the block it last processed.
protocol GainReducing: AnyObject {
    /// The lowest linear gain applied during the last `process` call (1: no reduction).
    var lowestGain: Double { get }
}
