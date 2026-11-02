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
import MpvfxShared
import MpvfxAudioGraph

/// Learning the noise of a clip for Clean up noise (issue #312): the clip's own sound is decoded the way playback and
/// export decode it, and `NoiseProfile` reads the noise from it.
public enum NoiseLearning {
    public enum Source: String, Sendable {
        /// The quietest tenth of the clip.
        case quietest
        /// The part of the clip the timeline's in and out points cover.
        case range
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case noSuchClip
        case noRange
        case profile(NoiseProfile.Failure)
        public var description: String {
            switch self {
            case .noSuchClip: return "This clip has no sound to learn the noise from."
            case .noRange: return "Set an in point and an out point over a part of this clip that holds only the noise, then learn again."
            case .profile(let f): return f.description
            }
        }
    }

    /// The profile for `clipId`. `loadStem` decodes a clip's sound (the app's media engine; synthetic in tests).
    public static func learn(_ source: Source, clipId: String, document: NativeProjectDocument, projectDir: URL?,
                             inPoint: Double?, outPoint: Double?, sampleRate: Int = 48_000,
                             fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                             loadStem: ((DocumentAudioGraph.StemKey) throws -> [[Float]])? = nil) throws -> [Double] {
        let inputs = DocumentAudioGraph.inputs(document, duration: 0, projectDir: projectDir, fileExists: fileExists)
        guard let track = inputs.tracks.first(where: { $0.id == clipId }) else { throw Failure.noSuchClip }
        let span: NoiseProfile.Span?
        if source == .range {
            span = NoiseProfile.clipRange(inPoint: inPoint, outPoint: outPoint, clipStart: track.start, clipDuration: track.end - track.start)
            guard span != nil else { throw Failure.noRange }
        } else { span = nil }
        let stem = try (loadStem ?? { try DocumentAudioGraph.decodeStem($0, sampleRate: sampleRate) })(track.stem)
        do {
            if let span { return try NoiseProfile.learnRange(stem, sampleRate: Double(sampleRate), span: span) }
            return try NoiseProfile.learnQuietest(stem, sampleRate: Double(sampleRate))
        } catch let failure as NoiseProfile.Failure { throw Failure.profile(failure) }
    }
}
