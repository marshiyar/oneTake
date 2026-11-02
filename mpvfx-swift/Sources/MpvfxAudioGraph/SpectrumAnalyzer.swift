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

/// A spectrum of the sound at one point in an FX chain. All access belongs to the feeder thread. Scratch storage
/// and FFT tables are made at init. Consume bands before the next push: retaining an array copy across pushes
/// makes Swift copy its storage on the next write. Copy values into the reader's own storage to avoid that.
public final class SpectrumAnalyzer {
    public static let fftSize = 4096
    public static let bandCount = 60
    private static let hopSize = 2048

    /// The geometric centre of a sixth-octave band, in Hz.
    public static func bandCenter(_ index: Int) -> Double {
        20 * pow(2, (Double(index) + 0.5) / 6)
    }

    /// Smoothed one-sided band power in dBFS, floored at -90 and capped at 0.
    public private(set) var bands: [Float]

    private var ring: [Double]
    private var real: [Double]
    private var imaginary: [Double]
    private let window: [Double]
    private let reversed: [Int]
    private let cosine: [Double]
    private let sine: [Double]
    private let firstBin: [Int]
    private let endBin: [Int]
    private let interpolationBin: [Int]
    private let interpolationWeight: [Double]
    private let amplitudeScale: Double
    private let smoothing: Double
    private var writeIndex = 0
    private var pendingSamples = 0

    public init(sampleRate: Double) {
        precondition(sampleRate.isFinite && sampleRate > 0, "Sample rate must be finite and positive")
        let size = Self.fftSize
        bands = [Float](repeating: -90, count: Self.bandCount)
        ring = [Double](repeating: 0, count: size)
        real = [Double](repeating: 0, count: size)
        imaginary = [Double](repeating: 0, count: size)

        var hann = [Double](repeating: 0, count: size)
        var sum = 0.0
        var permutation = [Int](repeating: 0, count: size)
        var cosines = [Double](repeating: 0, count: size / 2)
        var sines = [Double](repeating: 0, count: size / 2)
        for index in 0..<size {
            // A bin-centred sine's FFT magnitude is half the sum of this periodic Hann window.
            hann[index] = 0.5 - 0.5 * cos(2 * .pi * Double(index) / Double(size))
            sum += hann[index]
            var source = index
            var destination = 0
            for _ in 0..<12 {
                destination = (destination << 1) | (source & 1)
                source >>= 1
            }
            permutation[index] = destination
            if index < size / 2 {
                let angle = -2 * Double.pi * Double(index) / Double(size)
                cosines[index] = cos(angle)
                sines[index] = sin(angle)
            }
        }
        window = hann
        reversed = permutation
        cosine = cosines
        sine = sines
        amplitudeScale = 2 / sum
        smoothing = 1 - exp(-Double(Self.hopSize) / (sampleRate * 0.1))

        var starts = [Int](repeating: 0, count: Self.bandCount)
        var ends = [Int](repeating: 0, count: Self.bandCount)
        var neighbors = [Int](repeating: -1, count: Self.bandCount)
        var weights = [Double](repeating: 0, count: Self.bandCount)
        let binWidth = sampleRate / Double(size)
        let nyquist = sampleRate / 2
        for band in 0..<Self.bandCount {
            let lower = 20 * pow(2, Double(band) / 6)
            let upper = 20 * pow(2, Double(band + 1) / 6)
            // Clamp before converting to Int, including sample rates far below the audible range.
            starts[band] = Int(ceil(min(Double(size / 2 + 1), lower / binWidth)))
            ends[band] = Int(ceil(min(Double(size / 2 + 1), upper / binWidth)))
            if upper - lower < binWidth && Self.bandCenter(band) <= nyquist {
                let position = Self.bandCenter(band) / binWidth
                neighbors[band] = min(size / 2 - 1, Int(position))
                weights[band] = position - Double(neighbors[band])
            }
        }
        firstBin = starts
        endBin = ends
        interpolationBin = neighbors
        interpolationWeight = weights
    }

    /// Average the available channels into the ring. Empty input does nothing; unequal channel lengths use
    /// the channels present at each sample. Every 2048 samples produces a spectrum, initially padded with silence.
    /// Returns true if at least one spectrum was produced, with the newest result in `bands`.
    @discardableResult public func push(_ planes: [[Float]]) -> Bool {
        var length = 0
        var channel = 0
        while channel < planes.count {
            length = max(length, planes[channel].count)
            channel += 1
        }
        var computed = false
        var frame = 0
        while frame < length {
            var sum = 0.0
            var count = 0
            channel = 0
            while channel < planes.count {
                if frame < planes[channel].count {
                    let value = Double(planes[channel][frame])
                    sum += value.isFinite ? value : 0
                    count += 1
                }
                channel += 1
            }
            ring[writeIndex] = sum / Double(count)
            writeIndex = (writeIndex + 1) & (Self.fftSize - 1)
            pendingSamples += 1
            if pendingSamples == Self.hopSize {
                pendingSamples = 0
                computeSpectrum()
                computed = true
            }
            frame += 1
        }
        return computed
    }

    private func computeSpectrum() {
        let size = Self.fftSize
        var index = 0
        while index < size {
            let destination = reversed[index]
            real[destination] = ring[(writeIndex + index) & (size - 1)] * window[index]
            imaginary[destination] = 0
            index += 1
        }

        var width = 2
        while width <= size {
            let half = width / 2
            let stride = size / width
            var base = 0
            while base < size {
                var offset = 0
                while offset < half {
                    let even = base + offset
                    let odd = even + half
                    let table = offset * stride
                    let oddReal = real[odd] * cosine[table] - imaginary[odd] * sine[table]
                    let oddImaginary = real[odd] * sine[table] + imaginary[odd] * cosine[table]
                    real[odd] = real[even] - oddReal
                    imaginary[odd] = imaginary[even] - oddImaginary
                    real[even] += oddReal
                    imaginary[even] += oddImaginary
                    offset += 1
                }
                base += width
            }
            width *= 2
        }

        var band = 0
        while band < Self.bandCount {
            var power = 0.0
            let neighbor = interpolationBin[band]
            if neighbor >= 0 {
                let weight = interpolationWeight[band]
                power = binPower(neighbor) * (1 - weight) + binPower(neighbor + 1) * weight
            } else {
                var bin = firstBin[band]
                while bin < endBin[band] {
                    power += binPower(bin)
                    bin += 1
                }
            }
            let decibels = power > 1e-9 ? min(0, 10 * log10(power)) : -90
            bands[band] += Float(smoothing * (decibels - Double(bands[band])))
            band += 1
        }
    }

    private func binPower(_ index: Int) -> Double {
        // DC and Nyquist have no negative-frequency partner to fold into their amplitude.
        let scale = index == 0 || index == Self.fftSize / 2 ? amplitudeScale / 2 : amplitudeScale
        let re = real[index] * scale
        let im = imaginary[index] * scale
        return re * re + im * im
    }
}
