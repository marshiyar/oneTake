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
import XCTest
import MpvfxShared
import MpvfxAudioGraph
@testable import MpvfxAudio

/// Learning the noise of a clip (issue #312, A1 and A2): the I/O range is taken in the clip's own time.
final class NoiseLearningTests: XCTestCase {
    static let sr = 48_000
    /// A 2 s clip that starts 0.5 s into the sequence. Its sound is a loud tone except between 1 s and 2 s, which is noise only.
    static let json = #"""
    {"schemaVersion":1,"id":"p","revision":1,"frameRate":{"numerator":30,"denominator":1},
     "canvas":{"width":640,"height":360,"background":"#000000"},
     "assets":[{"id":"a","kind":"audio","name":"Talk.wav","source":"Talk.wav","durationFrames":90}],
     "sequence":{"id":"s","name":"S","tracks":[{"id":"t","kind":"audio","clips":[
      {"id":"c","assetId":"a","startFrame":15,"durationFrames":60,"sourceInFrame":0,"effects":[],"parameterTracks":[]}]}]}}
    """#
    /// The bin of the 1 kHz tone in the profile (bins are 48000 / 1024 Hz apart).
    static let toneBin = 21
    static let stem: [Float] = {
        let n = 2 * sr
        var state: UInt64 = 5
        let noise: [Float] = (0..<n).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let u = Double(state >> 11) / Double(1 << 53) * 2 - 1
            return Float(u * pow(10, -30.0 / 20) * 3.0.squareRoot())
        }
        return (0..<n).map { i in
            let t = Double(i) / Double(sr)
            return noise[i] + (t < 1 ? Float(0.25 * sin(2 * Double.pi * 1000 * t)) : 0)
        }
    }()

    func document() throws -> NativeProjectDocument { try parseNativeProjectDocument(try NativeJSONValue.parse(Self.json)) }

    func testA2TheIORangeIsTakenInTheClipsOwnTime() throws {
        var asked: [DocumentAudioGraph.StemKey] = []
        let load: (DocumentAudioGraph.StemKey) throws -> [[Float]] = { asked.append($0); return [Self.stem, Self.stem] }
        // On the timeline the clip runs 0.5 s to 2.5 s, so 1.5 s to 2.5 s is its noise-only second.
        let learned = try NoiseLearning.learn(.range, clipId: "c", document: try document(), projectDir: URL(fileURLWithPath: "/p"),
                                              inPoint: 1.5, outPoint: 2.5, loadStem: load)
        let direct = try NoiseProfile.learnRange([Self.stem, Self.stem], sampleRate: 48_000, span: .init(start: 1, end: 2))
        XCTAssertEqual(learned, direct, "exactly the part of the clip under the I/O range")
        XCTAssertEqual(asked.count, 1)
        // The same numbers as clip time would be the wrong second: the tone is in the profile.
        let wrong = try NoiseLearning.learn(.range, clipId: "c", document: try document(), projectDir: nil, inPoint: 1, outPoint: 2, loadStem: load)
        XCTAssertGreaterThan(wrong[Self.toneBin] - learned[Self.toneBin], 10)
    }

    func testQuietestIgnoresTheRangeAndRangeNeedsOne() throws {
        let load: (DocumentAudioGraph.StemKey) throws -> [[Float]] = { _ in [Self.stem, Self.stem] }
        let quietest = try NoiseLearning.learn(.quietest, clipId: "c", document: try document(), projectDir: nil, inPoint: nil, outPoint: nil, loadStem: load)
        XCTAssertEqual(quietest, try NoiseProfile.learnQuietest([Self.stem, Self.stem], sampleRate: 48_000))
        for (i, o) in [(nil, nil), (1.5, nil), (9.0, 10.0), (2.5, 1.5)] as [(Double?, Double?)] {
            XCTAssertThrowsError(try NoiseLearning.learn(.range, clipId: "c", document: try document(), projectDir: nil, inPoint: i, outPoint: o, loadStem: load)) {
                XCTAssertEqual($0 as? NoiseLearning.Failure, .noRange)
            }
        }
        XCTAssertThrowsError(try NoiseLearning.learn(.quietest, clipId: "nope", document: try document(), projectDir: nil, inPoint: nil, outPoint: nil, loadStem: load)) {
            XCTAssertEqual($0 as? NoiseLearning.Failure, .noSuchClip)
        }
    }
}
