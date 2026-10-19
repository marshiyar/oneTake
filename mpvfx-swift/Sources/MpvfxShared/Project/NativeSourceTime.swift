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
// Source time math (rational frame rates and fractions) in overflow-checked Int64; an intermediate that would
// not fit throws NativeSourceTimeRangeError (see docs/IMPLEMENTATION_NOTES.md).
import Foundation

public struct NativeSourcePosition: Equatable {
    public var sourceInFrame: Double
    public var sourceInFraction: NativePlaybackRate?
    public init(sourceInFrame: Double, sourceInFraction: NativePlaybackRate? = nil) { self.sourceInFrame = sourceInFrame; self.sourceInFraction = sourceInFraction }
}

public struct NativeSourceTimeRangeError: Error, Equatable { public let message: String }

private let overflowError = NativeSourceTimeRangeError(message: "Media time arithmetic overflows 64-bit range")

private func big(_ d: Double) throws -> Int64 {
    guard d.isFinite, d.rounded(.towardZero) == d, let v = Int64(exactly: d) else { throw overflowError }
    return v
}
private func mul(_ a: Int64, _ b: Int64) throws -> Int64 {
    let (r, o) = a.multipliedReportingOverflow(by: b); if o { throw overflowError }; return r
}
private func add(_ a: Int64, _ b: Int64) throws -> Int64 {
    let (r, o) = a.addingReportingOverflow(b); if o { throw overflowError }; return r
}
private func sub(_ a: Int64, _ b: Int64) throws -> Int64 {
    let (r, o) = a.subtractingReportingOverflow(b); if o { throw overflowError }; return r
}

private func gcd(_ a0: Int64, _ b0: Int64) -> Int64 {
    var a = a0.magnitude, b = b0.magnitude
    while b != 0 { (a, b) = (b, a % b) }
    return Int64(a)
}

private let maxSafe: Int64 = 9_007_199_254_740_991

private func safe(_ v: Int64) throws -> Double {
    if v < 0 || v > maxSafe { throw NativeSourceTimeRangeError(message: "Media time exceeds the supported range") }
    return Double(v)
}

public func rationalFromNumber(_ value: Double) throws -> NativePlaybackRate {
    if !value.isFinite || value < 0 { throw NativeSourceTimeRangeError(message: "Media time must be finite and nonnegative") }
    var previousN = 0.0, numerator = 1.0, previousD = 1.0, denominator = 0.0
    var rest = value
    func isSafe(_ x: Double) -> Bool { jsIsInteger(x) && abs(x) <= jsMaxSafeInteger }
    for _ in 0..<48 {
        let whole = rest.rounded(.down)
        let nextN = whole * numerator + previousN
        let nextD = whole * denominator + previousD
        if !isSafe(nextN) || !isSafe(nextD) || nextD > 1_000_000_000 { break }
        (previousN, numerator) = (numerator, nextN)
        (previousD, denominator) = (denominator, nextD)
        let remainder = rest - whole
        if remainder == 0 || abs(numerator / denominator - value) <= 4 * Double.ulpOfOne * max(1, value) { break }
        rest = 1 / remainder
    }
    if denominator == 0 { throw NativeSourceTimeRangeError(message: "Media time exceeds the supported range") }
    return NativePlaybackRate(numerator: numerator, denominator: denominator)
}

private func position(_ numerator: Int64, _ denominator: Int64) throws -> NativeSourcePosition {
    if numerator < 0 { throw NativeSourceTimeRangeError(message: "Cannot extend before the beginning of the source media") }
    let whole = numerator / denominator, remainder = numerator % denominator
    let divisor = gcd(remainder, denominator)
    return NativeSourcePosition(sourceInFrame: try safe(whole), sourceInFraction: remainder == 0 ? nil :
        NativePlaybackRate(numerator: try safe(remainder / divisor), denominator: try safe(denominator / divisor)))
}

public func sourcePositionFromSeconds(_ seconds: Double, frameRate: NativePlaybackRate) throws -> NativeSourcePosition {
    let t = try rationalFromNumber(seconds)
    return try position(mul(big(t.numerator), big(frameRate.numerator)), mul(big(t.denominator), big(frameRate.denominator)))
}

private let zeroFraction = NativePlaybackRate(numerator: 0, denominator: 1)

/// Exact (numerator, denominator) of clip start + frames*rate, in units of 1/(fd*rd) source frames.
private func endPoint(_ clip: NativeSourcePosition, _ rate: NativePlaybackRate?, _ frames: Double) throws -> (Int64, Int64) {
    let f = clip.sourceInFraction ?? zeroFraction, r = rate ?? DEFAULT_NATIVE_PLAYBACK_RATE
    let den = try mul(big(f.denominator), big(r.denominator))
    let start = try mul(add(mul(big(clip.sourceInFrame), big(f.denominator)), big(f.numerator)), big(r.denominator))
    let advance = try mul(mul(big(frames), big(r.numerator)), big(f.denominator))
    return (try add(start, advance), den)
}

public func advanceSourcePosition(_ clip: NativeSourcePosition, playbackRate: NativePlaybackRate?, timelineFrames: Double) throws -> NativeSourcePosition {
    let (num, den) = try endPoint(clip, playbackRate, timelineFrames)
    return try position(num, den)
}

public func sourceFrameValue(_ clip: NativeSourcePosition) -> Double {
    clip.sourceInFrame + (clip.sourceInFraction.map { $0.numerator / $0.denominator } ?? 0)
}

/// Throws on 64-bit overflow.
public func availableTimelineFrames(_ clip: NativeSourcePosition, playbackRate: NativePlaybackRate?, sourceDurationFrames: Double) throws -> Double {
    let f = clip.sourceInFraction ?? zeroFraction, r = playbackRate ?? DEFAULT_NATIVE_PLAYBACK_RATE
    let remaining = try sub(mul(big(sourceDurationFrames - clip.sourceInFrame), big(f.denominator)), big(f.numerator))
    if remaining < 0 { return 0 }
    let frames = try mul(remaining, big(r.denominator)) / mul(big(f.denominator), big(r.numerator))
    return Double(min(frames, maxSafe))
}

/// Throws on 64-bit overflow.
public func sourceRangeFits(_ clip: NativeSourcePosition, playbackRate: NativePlaybackRate?, durationFrames: Double, sourceDurationFrames: Double) throws -> Bool {
    let (end, den) = try endPoint(clip, playbackRate, durationFrames)
    return end <= (try mul(big(sourceDurationFrames), den))
}
