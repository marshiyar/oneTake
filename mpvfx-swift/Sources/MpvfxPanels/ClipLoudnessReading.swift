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

/// The Loudness row of a clip's Media group: the integrated loudness (BS.1770, LUFS) of the clip's source file, as
/// the host measured it in the background. The clip's static gain is added when the row is drawn, so the readout
/// follows a volume change without a new measurement.
public enum ClipLoudnessReading: Equatable, Sendable {
    /// Still measuring in the background.
    case measuring
    /// Below the BS.1770 absolute gate (-70 LKFS): no programme to measure.
    case silent
    /// Under 400 ms: too short for the gated measurement.
    case tooShort
    /// No readable audio (missing file, no audio track, or the engine cannot decode it).
    case unavailable
    /// The source's integrated loudness.
    case lufs(Double)

    /// The row text for a clip at linear `volume` (1 = 0 dB). A zero volume reads "Silent" whatever the source is.
    /// `keyframed` marks a clip whose volume has keys: the readout uses the static gain only, so it says " + keys".
    public static func label(reading: ClipLoudnessReading, volume: Double, keyframed: Bool) -> String {
        if volume <= 0 { return "Silent" }
        switch reading {
        case .measuring: return "Measuring\u{2026}"
        case .silent: return "Silent"
        case .tooShort: return "Too short to measure"
        case .unavailable: return "Not available"
        case .lufs(let source):
            let loudness = source + 20 * log10(volume)
            guard loudness.isFinite else { return "Not available" }
            return String(format: "%.1f LUFS", loudness) + (keyframed ? " + keys" : "")
        }
    }
}
