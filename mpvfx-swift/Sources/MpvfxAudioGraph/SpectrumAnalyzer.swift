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

/// A spectrum of the sound at one point in an FX chain. All access belongs to the feeder thread.
/// Scratch storage and FFT tables are made at init. push processes every supplied sample synchronously,
/// without locks, allocation or an input queue; it has no busy/drop path. Transfer results to the UI
/// through a synchronized slot, never by reading this object concurrently.
public final class SpectrumAnalyzer {
    public static let fftSize = 4096
    public static let bandCount = 60
    private static let hopSize = 2048

    /// The geometric centre of a sixth-octave band, in Hz.
    public static func bandCenter(_ index: Int) -> Double {
        20 * pow(2, (Double(index) + 0.5) / 6)
    }

    /// An allocating snapshot of smoothed one-sided band power in dBFS, floored at -90 and capped at 0.
    /// Retaining it cannot cause a later push to copy the feeder's storage. For allocation-free
    /// publication on the feeder, use withUnsafeBands instead.
    public var bands: [Float] { levels.map { $0 } }
    private var levels: [Float]

    /// Borrow the current levels on the feeder thread without allocating. Do not retain the pointer
    /// or call push from the closure. Publish a copy through a synchronized slot for UI readers.
    public func withUnsafeBands<Result>(_ body: (UnsafeBufferPointer<Float>) throws -> Result) rethrows -> Result {
        try levels.withUnsafeBufferPointer(body)
    }

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
        levels = [Float](repeating: -90, count: Self.bandCount)
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
            // Sub-bin bands cannot resolve separate frequencies: interpolate the two
            // neighbouring bin powers at the centre instead of leaving empty bands.
            // Wider bands sum bins whose centres are in [lower, upper). Consequently
            // white noise rises by roughly 10*log10(bins per band) in wider bands;
            // this is band power, not a bandwidth-normalized power-density display.
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
            // A periodic Hann's coherent-gain scaling leaves 1.5 times the sine power
            // across its three-bin lobe. Remove that noise-equivalent bandwidth so a
            // full lobe measures the sine's amplitude in dBFS, without flattening the
            // top 1.76 dB. A lobe split by a band edge is intentionally split in power.
            power /= 1.5
            let decibels = power > 1e-9 ? min(0, 10 * log10(power)) : -90
            levels[band] += Float(smoothing * (decibels - Double(levels[band])))
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

#if SPECTRUM_REGRESSION_TESTS
import XCTest

/// Standalone macOS scoped checks, from the repository root (no package dependencies):
/// platform="$(xcode-select -p)/Platforms/MacOSX.platform/Developer"
/// swiftc -parse-as-library -D SPECTRUM_REGRESSION_TESTS \
///   -I "$platform/usr/lib" -L "$platform/usr/lib" -lXCTestSwiftSupport \
///   -F "$platform/Library/Frameworks" \
///   -Xlinker -rpath -Xlinker "$platform/Library/Frameworks" \
///   -Xlinker -rpath -Xlinker "$platform/usr/lib" \
///   mpvfx-swift/Sources/MpvfxAudioGraph/SpectrumAnalyzer.swift -o /tmp/spectrum-tests
/// /tmp/spectrum-tests
final class SpectrumAnalyzerRegressionTests: XCTestCase {
    private func tone(_ analyzer: SpectrumAnalyzer, bin: Int = 400, amplitude: Double = 1) {
        let samples = (0..<SpectrumAnalyzer.fftSize).map {
            Float(amplitude * sin(2 * .pi * Double(bin * $0) / Double(SpectrumAnalyzer.fftSize)))
        }
        for _ in 0..<24 { analyzer.push([samples]) }
    }

    @objc func testHannCalibrationPreservesTopOfRange() {
        for amplitude in [1.0, pow(10, -1.7 / 20), 0.5] {
            let analyzer = SpectrumAnalyzer(sampleRate: 48_000)
            tone(analyzer, amplitude: amplitude)
            XCTAssertEqual(Double(analyzer.bands.max()!), 20 * log10(amplitude), accuracy: 0.03)
        }
    }

    @objc func testSampleRatesAndBandsAboveNyquist() {
        for rate in [44_100.0, 48_000, 96_000, 16] {
            let analyzer = SpectrumAnalyzer(sampleRate: rate)
            tone(analyzer)
            XCTAssertTrue(analyzer.bands.allSatisfy { $0.isFinite && $0 >= -90 && $0 <= 0 })
            if rate == 16 { XCTAssertEqual(analyzer.bands, [Float](repeating: -90, count: 60)) }
            else {
                let frequency = rate * 400 / 4096
                let peak = analyzer.bands.indices.max { analyzer.bands[$0] < analyzer.bands[$1] }!
                XCTAssertLessThanOrEqual(20 * pow(2, Double(peak) / 6), frequency)
                XCTAssertGreaterThan(20 * pow(2, Double(peak + 1) / 6), frequency)
            }
        }
    }

    @objc func testUnequalChannelsAverageOnlyPresentSamples() {
        let analyzer = SpectrumAnalyzer(sampleRate: 48_000)
        let reference = SpectrumAnalyzer(sampleRate: 48_000)
        let long = (0..<4096).map { Float(sin(2 * .pi * Double($0) / 16)) }
        let short = Array(long.prefix(1234)).map { -$0 }
        analyzer.push([[], long, short])
        reference.push([Array(repeating: 0, count: short.count) + Array(long.dropFirst(short.count))])
        XCTAssertEqual(analyzer.bands, reference.bands)
    }

    @objc func testSmoothingAndHopCadence() {
        let analyzer = SpectrumAnalyzer(sampleRate: 48_000)
        tone(analyzer, amplitude: 0.5)
        let before = analyzer.bands
        XCTAssertFalse(analyzer.push([[Float](repeating: 0, count: 2047)]))
        XCTAssertEqual(analyzer.bands, before)
        XCTAssertTrue(analyzer.push([[0]]))
        // After the second silent hop the entire FFT window is silent.
        let intermediate = analyzer.bands
        analyzer.push([[Float](repeating: 0, count: 2048)])
        let coefficient = 1 - exp(-2048.0 / (48_000 * 0.1))
        for band in 0..<60 {
            XCTAssertEqual(Double(analyzer.bands[band]), Double(intermediate[band]) + coefficient * (-90 - Double(intermediate[band])), accuracy: 0.00002)
        }
    }

    @objc func testNarrowBandInterpolatesPowerAtCenter() {
        let analyzer = SpectrumAnalyzer(sampleRate: 48_000)
        // Bin 8 lies between the centres of two sub-bin-width bands.
        tone(analyzer, bin: 8, amplitude: 0.5)
        let binWidth = 48_000.0 / 4096
        for band in 0..<24 where SpectrumAnalyzer.bandCenter(band) / binWidth > 7 && SpectrumAnalyzer.bandCenter(band) / binWidth < 9 {
            let distance = abs(SpectrumAnalyzer.bandCenter(band) / binWidth - 8)
            let expectedPower = 0.25 * (1 - 0.75 * distance) / 1.5
            XCTAssertEqual(Double(analyzer.bands[band]), 10 * log10(expectedPower), accuracy: 0.03)
        }
    }

    @objc func testWideBandsAssignBinsByCenterFrequency() {
        // These tones straddle nearby band edges; check the split Hann lobe itself,
        // rather than just accepting a peak somewhere near the tone.
        for centerBin in [120, 121, 128] {
            let analyzer = SpectrumAnalyzer(sampleRate: 48_000)
            tone(analyzer, bin: centerBin, amplitude: 0.5)
            for band in 30..<60 {
                let lower = 20 * pow(2, Double(band) / 6)
                let upper = 20 * pow(2, Double(band + 1) / 6)
                var power = 0.0
                for bin in (centerBin - 1)...(centerBin + 1) {
                    let frequency = Double(bin) * 48_000 / 4096
                    if frequency >= lower && frequency < upper {
                        power += bin == centerBin ? 0.25 : 0.0625
                    }
                }
                let expected = power > 0 ? 10 * log10(power / 1.5) : -90
                XCTAssertEqual(Double(analyzer.bands[band]), expected, accuracy: 0.03)
            }
        }
    }

    @objc func testRetainedSnapshotDoesNotCopyFeederStorage() {
        let analyzer = SpectrumAnalyzer(sampleRate: 48_000)
        let address = analyzer.withUnsafeBands { UInt(bitPattern: $0.baseAddress!) }
        let snapshot = analyzer.bands
        tone(analyzer, amplitude: 0.5)
        XCTAssertEqual(address, analyzer.withUnsafeBands { UInt(bitPattern: $0.baseAddress!) })
        XCTAssertEqual(snapshot, [Float](repeating: -90, count: 60))
        XCTAssertGreaterThan(analyzer.bands.max()!, -10)
    }

}

@main
private enum SpectrumRegressionRunner {
    static func main() {
        let suite = SpectrumAnalyzerRegressionTests.defaultTestSuite
        suite.run()
        exit(suite.testRun!.hasSucceeded ? 0 : 1)
    }
}
#endif
