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
// Silence detection: windowed RMS over decoded samples finds the pauses "Remove silences" cuts.
import Foundation

public struct SilenceRange: Codable, Equatable {
    public var start: Double; public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
}

public struct SilenceRemovalOptions: Codable, Equatable {
    public var thresholdDb: Double; public var minimumSilenceSeconds: Double; public var paddingSeconds: Double
    public init(thresholdDb: Double, minimumSilenceSeconds: Double, paddingSeconds: Double) {
        self.thresholdDb = thresholdDb; self.minimumSilenceSeconds = minimumSilenceSeconds; self.paddingSeconds = paddingSeconds
    }
}

/// `Partial<SilenceRemovalOptions>` (`??` treats undefined and null alike, so one optional suffices).
public struct PartialSilenceRemovalOptions: Equatable {
    public var thresholdDb: Double?; public var minimumSilenceSeconds: Double?; public var paddingSeconds: Double?
    public init(thresholdDb: Double? = nil, minimumSilenceSeconds: Double? = nil, paddingSeconds: Double? = nil) {
        self.thresholdDb = thresholdDb; self.minimumSilenceSeconds = minimumSilenceSeconds; self.paddingSeconds = paddingSeconds
    }
}

public let DEFAULT_SILENCE_REMOVAL_OPTIONS = SilenceRemovalOptions(thresholdDb: -42, minimumSilenceSeconds: 0.65, paddingSeconds: 0.12)

private let ANALYSIS_WINDOW_SECONDS = 0.01

/// Return padded source-time intervals whose windowed RMS is below the threshold.
/// Channels are Float32 samples; each is widened to Double before squaring.
public func detectSilences(_ channels: [[Float]], sampleRate: Double, options: PartialSilenceRemovalOptions = .init()) -> [SilenceRange] {
    if !sampleRate.isFinite || sampleRate <= 0 || channels.isEmpty { return [] }
    let sampleCount = Double(channels.map(\.count).max()!)
    if sampleCount == 0 { return [] }

    let thresholdDb = options.thresholdDb ?? DEFAULT_SILENCE_REMOVAL_OPTIONS.thresholdDb
    let minimumSilenceSeconds = jsMathMax(0, options.minimumSilenceSeconds ?? DEFAULT_SILENCE_REMOVAL_OPTIONS.minimumSilenceSeconds)
    let paddingSeconds = jsMathMax(0, options.paddingSeconds ?? DEFAULT_SILENCE_REMOVAL_OPTIONS.paddingSeconds)
    let thresholdAmplitude = jsExponentiate(10, thresholdDb / 20)
    // Frame positions stay Double (JS numbers): a huge sampleRate gives a window wider than any Int.
    let windowFrames = jsMathMax(1, jsMathRound(sampleRate * ANALYSIS_WINDOW_SECONDS))
    var silences: [SilenceRange] = []
    var silenceStartFrame: Double? = nil

    func finishSilence(_ endFrame: Double) {
        guard let startFrame = silenceStartFrame else { return }
        let start = startFrame / sampleRate, end = endFrame / sampleRate
        silenceStartFrame = nil
        if end - start < minimumSilenceSeconds { return }
        let paddedStart = start + paddingSeconds, paddedEnd = end - paddingSeconds
        if paddedEnd > paddedStart { silences.append(SilenceRange(start: paddedStart, end: paddedEnd)) }
    }

    var windowStart = 0.0
    while windowStart < sampleCount {
        let windowEnd = min(sampleCount, windowStart + windowFrames)
        var sumSquares = 0.0, sampleTotal = 0.0
        for channel in channels {
            let stop = min(windowEnd, Double(channel.count))
            var frame = windowStart
            while frame < stop {
                let sample = Double(channel[Int(frame)])
                frame += 1
                if !sample.isFinite { continue }
                sumSquares += sample * sample
                sampleTotal += 1
            }
        }
        let rms = sampleTotal > 0 ? (sumSquares / sampleTotal).squareRoot() : 0
        if rms <= thresholdAmplitude {
            if silenceStartFrame == nil { silenceStartFrame = windowStart }
        } else {
            finishSilence(windowStart)
        }
        windowStart += windowFrames
    }
    finishSilence(sampleCount)
    return silences
}
