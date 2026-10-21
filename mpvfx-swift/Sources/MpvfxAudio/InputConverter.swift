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
// Turns what a capture device delivers (its own rate and channel count) into the recording format: channel mixing and
// linear-interpolation resampling, streaming, so blocks of any size give the same samples. Used where the system
// does not convert for us (Core Audio's input unit never changes the sample rate).
import Foundation

public struct InputConverter {
    public let sourceRate: Int, sourceChannels: Int
    public let targetRate: Int, targetChannels: Int
    /// Source frames per output frame.
    private let step: Double
    /// Position of the next output frame, in source frames after `previous`.
    private var phase = 0.0
    private var previous: [Float]
    private var havePrevious = false

    public init(sourceRate: Int, sourceChannels: Int, targetRate: Int, targetChannels: Int) {
        self.sourceRate = max(1, sourceRate); self.sourceChannels = max(1, sourceChannels)
        self.targetRate = max(1, targetRate); self.targetChannels = max(1, targetChannels)
        step = Double(self.sourceRate) / Double(self.targetRate)
        previous = [Float](repeating: 0, count: self.targetChannels)
    }

    /// Mixes one source frame to the target channel count: mono is the average, more channels than the target keep the
    /// first ones, fewer repeat the last.
    func mix(_ source: UnsafeBufferPointer<Float>, frame: Int) -> [Float] {
        let base = frame * sourceChannels
        if targetChannels == 1 {
            var sum: Float = 0
            for c in 0..<sourceChannels { sum += source[base + c] }
            return [sum / Float(sourceChannels)]
        }
        return (0..<targetChannels).map { source[base + min($0, sourceChannels - 1)] }
    }

    /// `interleaved` is a whole number of source frames; returns whole target frames.
    public mutating func process(_ interleaved: [Float]) -> [Float] {
        let frames = interleaved.count / sourceChannels
        guard frames > 0 else { return [] }
        if sourceRate == targetRate && sourceChannels == targetChannels { return interleaved }
        if sourceRate == targetRate {   // channels only: frame for frame, no interpolation
            return interleaved.withUnsafeBufferPointer { source in (0..<frames).flatMap { mix(source, frame: $0) } }
        }
        var out: [Float] = []
        out.reserveCapacity(Int(Double(frames) / step + 2) * targetChannels)
        interleaved.withUnsafeBufferPointer { source in
            if !havePrevious { previous = mix(source, frame: 0); havePrevious = true; phase = 0 }
            // `phase` counts source frames from `previous`; frame i of this block sits at i + 1.
            var next = phase
            while next <= Double(frames) {
                let whole = Int(next.rounded(.down)), fraction = Float(next - Double(whole))
                let a = whole == 0 ? previous : mix(source, frame: whole - 1)
                let b = whole >= frames ? a : mix(source, frame: whole)
                for c in 0..<targetChannels { out.append(a[c] + (b[c] - a[c]) * fraction) }
                next += step
            }
            phase = next - Double(frames)
            previous = mix(source, frame: frames - 1)
        }
        return out
    }
}
