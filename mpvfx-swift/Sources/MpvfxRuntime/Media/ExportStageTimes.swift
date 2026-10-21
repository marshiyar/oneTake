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
// Where an export's time goes, per frame: painting (the preview's painter plus the frame's slice of the audio mix)
// and encoding (MediaWriter). The export benchmark (tools/MpvfxPreviewBench, scenario `export`) reads it.
import Foundation

/// Seconds an export spent painting and encoding, summed over its frames. Thread-safe: the painter and the encoder
/// add to it from their own threads.
public final class NativeExportStageTimes: @unchecked Sendable {
    private let lock = NSLock()
    private var paint = 0.0, encode = 0.0, painted = 0, encoded = 0

    public init() {}

    /// Seconds spent painting frames (and mixing their sound).
    public var paintSeconds: Double { lock.lock(); defer { lock.unlock() }; return paint }
    /// Seconds spent handing frames and samples to the encoder.
    public var encodeSeconds: Double { lock.lock(); defer { lock.unlock() }; return encode }
    /// Frames painted, and frames encoded.
    public var framesPainted: Int { lock.lock(); defer { lock.unlock() }; return painted }
    public var framesEncoded: Int { lock.lock(); defer { lock.unlock() }; return encoded }

    func addPaint(_ seconds: Double) { lock.lock(); paint += seconds; painted += 1; lock.unlock() }
    func addEncode(_ seconds: Double) { lock.lock(); encode += seconds; encoded += 1; lock.unlock() }

    /// A monotonic clock in seconds.
    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
}
