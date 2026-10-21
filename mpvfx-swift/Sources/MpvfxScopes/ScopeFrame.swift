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

/// Why a frame cannot be analysed.
public enum ScopeError: Error, Equatable, Sendable {
    /// Width or height is not in 1...`ScopeFrame.maxSide`.
    case invalidSize(width: Int, height: Int)
    /// The buffer does not hold width x height x 4 bytes.
    case byteCount(expected: Int, actual: Int)
}

/// One picture for the scopes: RGBA8, straight alpha, rows top to bottom, non-linear (gamma-encoded) full-range
/// R'G'B' as the preview and export draw it. Pixels with alpha 0 are not part of the picture and are not counted.
public struct ScopeFrame: Sendable {
    /// Larger than any frame the editor makes (8K is 7680); keeps width x height x 4 far from overflow.
    public static let maxSide = 32768

    public let width: Int, height: Int
    public let rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) throws {
        guard (1...Self.maxSide).contains(width), (1...Self.maxSide).contains(height) else {
            throw ScopeError.invalidSize(width: width, height: height)
        }
        let expected = width * height * 4
        guard rgba.count == expected else { throw ScopeError.byteCount(expected: expected, actual: rgba.count) }
        self.width = width; self.height = height; self.rgba = rgba
    }
}

/// How a frame is analysed. Every value is clamped to a usable range by `resolved`, so no setting can make the
/// analysis fail or allocate without bound.
public struct ScopeOptions: Sendable, Equatable {
    public var matrix: ScopeMatrix
    /// Waveform columns across the frame (at most the sampled width).
    public var columns: Int
    /// Vectorscope bins from the centre to the +-0.5 edge; the grid is (2 radius + 1) square, centre = achromatic.
    public var vectorRadius: Int
    /// Vectorscope magnification, 1...8: at 2 the grid spans +-0.25.
    public var vectorZoom: Double
    /// Frames with more pixels are point-sampled on a uniform grid down to at most this many samples.
    public var maxSamples: Int
    /// Threads; 0 = min(8, active processors).
    public var workers: Int

    public init(matrix: ScopeMatrix = .rec709, columns: Int = 512, vectorRadius: Int = 128, vectorZoom: Double = 1,
                maxSamples: Int = 1920 * 1080, workers: Int = 0) {
        self.matrix = matrix; self.columns = columns; self.vectorRadius = vectorRadius
        self.vectorZoom = vectorZoom; self.maxSamples = maxSamples; self.workers = workers
    }

    /// The options with every value inside its range.
    public var resolved: ScopeOptions {
        var o = self
        o.columns = min(4096, max(1, columns))
        o.vectorRadius = min(512, max(16, vectorRadius))
        o.vectorZoom = vectorZoom.isFinite ? min(8, max(1, vectorZoom)) : 1
        o.maxSamples = max(1, maxSamples)
        o.workers = workers <= 0 ? min(8, ProcessInfo.processInfo.activeProcessorCount) : min(64, workers)
        return o
    }
}
