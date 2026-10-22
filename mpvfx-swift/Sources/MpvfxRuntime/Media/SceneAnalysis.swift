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
import OneTakeMedia

/// Mean RGB difference between adjacent 64×64 pictures; threshold is a fraction of the full channel range.
/// Analyses only the selected source span and keeps two small frames in memory.
public func analyzeProjectScenes(_ projectRoot: String, source: String, sourceStart: Double,
                                 sourceDuration: Double, framesPerSecond: Double, threshold: Double,
                                 cancellation: MediaCancellation,
                                 onProgress: (Double) -> Void = { _ in }) throws -> [Double] {
    guard sourceStart.isFinite, sourceStart >= 0, sourceDuration.isFinite, sourceDuration > 0,
          framesPerSecond.isFinite, framesPerSecond > 0, framesPerSecond <= 1000,
          threshold.isFinite, threshold > 0, threshold <= 1 else {
        throw MediaToolError("Invalid scene analysis range or threshold")
    }
    let media = try probeProjectMedia(projectRoot, source, cancellation: cancellation)
    guard let video = media.probe.video, !video.still else { throw MediaToolError("Select a video clip") }
    let duration = min(sourceDuration, max(0, (media.probe.duration ?? 0) - sourceStart))
    guard duration > 0 else { throw MediaToolError("Selected clip is outside the video source") }
    let countValue = ceil(duration * framesPerSecond)
    guard countValue.isFinite, countValue < Double(Int.max) else { throw MediaToolError("Scene analysis range is too large") }
    let count = Int(countValue)
    do {
        let reader = try VideoFrameReader(path: media.path)
        var previous: [UInt8] = [], cuts: [Double] = []
        onProgress(0)
        for index in 0..<count {
            try cancellation.throwIfCancelled()
            let time = sourceStart + Double(index) / framesPerSecond
            let rgba = try reader.frame(at: time, width: 64, height: 64, fit: .stretch).rgba
            if !previous.isEmpty {
                var difference = 0
                for pixel in stride(from: 0, to: rgba.count, by: 4) {
                    for channel in 0..<3 { difference += abs(Int(rgba[pixel + channel]) - Int(previous[pixel + channel])) }
                }
                if Double(difference) / (64 * 64 * 3 * 255) >= threshold { cuts.append(time) }
            }
            previous = rgba
            // At most one UI update per analysed second, plus completion.
            if index == count - 1 || index % max(1, Int(framesPerSecond)) == 0 {
                onProgress(Double(index + 1) / Double(count))
            }
        }
        try cancellation.throwIfCancelled()
        return cuts
    } catch let error as MediaError { throw mediaToolError(error) }
}
