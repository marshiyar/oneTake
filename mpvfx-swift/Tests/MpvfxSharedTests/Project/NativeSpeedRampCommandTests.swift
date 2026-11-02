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
import XCTest
@testable import MpvfxShared

final class NativeSpeedRampCommandTests: XCTestCase {
    let engine = KeyframeEngineStandIn()

    func fixture(_ points: [NativeSpeedRamp.Point]? = nil) throws -> NativeProjectDocument {
        var d = try parseNativeProjectDocument(J(clipCommandsFixtureJSON), engine: engine)
        mutateClip(&d, "clip:audio") { $0.speedRamp = points.map { NativeSpeedRamp(points: $0) } }
        var follower = try XCTUnwrap(findClip(d, "clip:audio"))
        follower.id = "clip:follower"; follower.startFrame = 120; follower.speedRamp = nil
        d.sequence.tracks[2].clips.append(follower)
        return try parseNativeProjectDocument(d, engine: engine)
    }

    func apply(_ d: NativeProjectDocument, _ command: NativeSpeedRampCommand, keepLength: Bool = true) throws -> NativeProjectClipCommandResult {
        try applyNativeSpeedRampCommand(d, clipId: "clip:audio", command, keepLength: keepLength, engine: engine)
    }

    @discardableResult
    func success(_ d: NativeProjectDocument, _ command: NativeSpeedRampCommand, keepLength: Bool = true,
                 file: StaticString = #filePath, line: UInt = #line) throws -> NativeProjectDocument {
        let result = try apply(d, command, keepLength: keepLength)
        XCTAssertTrue(result.ok, "\(String(describing: result.failure))", file: file, line: line)
        let inverse = try XCTUnwrap(result.inverse, file: file, line: line)
        let restored = try applyNativeProjectClipCommand(result.document, inverse, engine: engine)
        XCTAssertTrue(restored.ok, file: file, line: line)
        XCTAssertEqual(restored.document, d, file: file, line: line)
        XCTAssertEqual(try serializeNativeProjectDocument(restored.document, engine: engine),
                       try serializeNativeProjectDocument(d, engine: engine), file: file, line: line)
        return result.document
    }

    func refused(_ d: NativeProjectDocument, _ command: NativeSpeedRampCommand, keepLength: Bool = true,
                 code: NativeProjectClipFailureCode = .invalidTrim, file: StaticString = #filePath, line: UInt = #line) throws {
        let result = try apply(d, command, keepLength: keepLength)
        XCTAssertFalse(result.ok, file: file, line: line)
        XCTAssertEqual(result.document, d, file: file, line: line)
        XCTAssertEqual(result.failure?.code, code, file: file, line: line)
        XCTAssertNil(result.inverse, file: file, line: line)
        XCTAssertFalse(result.failure?.message.isEmpty ?? true, file: file, line: line)
    }

    func testEveryCommandAndItsInverse() throws {
        let original = try fixture()
        let shaped = try success(original, .setShape(.slowMiddle))
        XCTAssertEqual(findClip(shaped, "clip:audio")?.speedRamp?.points, NativeSpeedRampShape.slowMiddle.points(durationFrames: 120))
        let added = try success(shaped, .addPoint(t: 20, speed: 0.5))
        XCTAssertEqual(findClip(added, "clip:audio")?.speedRamp?.points.map(\.t), [0, 20, 36, 84, 120])
        let moved = try success(added, .movePoint(index: 1, t: 24, speed: 0.75))
        XCTAssertEqual(findClip(moved, "clip:audio")?.speedRamp?.points[1], .init(t: 24, speed: 0.75))
        let eased = try success(moved, .setEase(index: 1, ease: .hold))
        XCTAssertEqual(findClip(eased, "clip:audio")?.speedRamp?.points[1].ease, .hold)
        let removed = try success(eased, .removePoint(index: 1))
        XCTAssertEqual(findClip(removed, "clip:audio")?.speedRamp?.points.count, 4)
        let cleared = try success(removed, .clear)
        XCTAssertNil(findClip(cleared, "clip:audio")?.speedRamp)
        let created = try success(original, .addPoint(t: 0, speed: 2))
        XCTAssertEqual(findClip(created, "clip:audio")?.speedRamp?.points, [.init(t: 0, speed: 2)])
        _ = try success(original, .clear)
    }

    func testRefusesInvalidPointsAndIndicesWithoutChangingDocument() throws {
        let d = try fixture([.init(t: 0, speed: 1), .init(t: 60, speed: 1), .init(t: 120, speed: 1)])
        let commands: [NativeSpeedRampCommand] = [
            .addPoint(t: 60, speed: 1), .addPoint(t: -1, speed: 1), .addPoint(t: 121, speed: 1),
            .addPoint(t: .nan, speed: 1), .addPoint(t: 20, speed: .infinity),
            .addPoint(t: 20, speed: 0.09), .addPoint(t: 20, speed: 10.1),
            .movePoint(index: 1, t: 0, speed: 1), .movePoint(index: 1, t: 120, speed: 1),
            .movePoint(index: 1, t: 121, speed: 1), .movePoint(index: 0, t: -1, speed: 1),
            .movePoint(index: 1, t: 60, speed: 11), .movePoint(index: -1, t: 10, speed: 1),
            .removePoint(index: 3), .setEase(index: -1, ease: .linear)
        ]
        for command in commands { try refused(d, command) }
        let one = try fixture([.init(t: 0, speed: 1)])
        try refused(one, .removePoint(index: 0))
        let empty = try fixture()
        try refused(empty, .movePoint(index: 0, t: 0, speed: 1))
        try refused(empty, .removePoint(index: 0))
        try refused(empty, .setEase(index: 0, ease: .linear))
        let full = try fixture((0..<64).map { .init(t: Double($0), speed: 1) })
        try refused(full, .addPoint(t: 64, speed: 1))
        let missing = try applyNativeSpeedRampCommand(d, clipId: "missing", .clear, keepLength: true, engine: engine)
        XCTAssertEqual(missing.failure?.code, .missingClip)
        XCTAssertEqual(missing.document, d)
    }

    func testKeepLengthKeepsClipAndFollowersInPlace() throws {
        let original = try fixture()
        for shape in NativeSpeedRampShape.allCases {
            let changed = try success(original, .setShape(shape))
            XCTAssertEqual(findClip(changed, "clip:audio")?.durationFrames, 120)
            XCTAssertEqual(findClip(changed, "clip:follower"), findClip(original, "clip:follower"))
        }
        try refused(original, .addPoint(t: 0, speed: 10))
        var nearEnd = original
        mutateClip(&nearEnd, "clip:audio") { $0.sourceInFrame = 780 }
        try refused(nearEnd, .addPoint(t: 0, speed: 2))
        var fast = try fixture([.init(t: 0, speed: 0.5)])
        mutateClip(&fast, "clip:audio") { $0.sourceInFrame = 840 }
        try refused(fast, .clear)
    }

    func testKeepingSourceSpanShortensOrExtendsAndRipplesOnlyItsTrack() throws {
        for speed in [0.5, 2.0] {
            let original = try fixture()
            let changed = try success(original, .addPoint(t: 0, speed: speed), keepLength: false)
            let clip = try XCTUnwrap(findClip(changed, "clip:audio"))
            let ramp = try XCTUnwrap(clip.speedRamp)
            XCTAssertEqual(clip.durationFrames, 120 / speed)
            XCTAssertEqual(ramp.sourcePosition(atClipFrame: clip.durationFrames), 120, accuracy: 1e-6)
            XCTAssertEqual(findClip(changed, "clip:follower")?.startFrame, clip.durationFrames)
            XCTAssertEqual(changed.sequence.tracks[0], original.sequence.tracks[0])
            XCTAssertEqual(changed.sequence.tracks[1], original.sequence.tracks[1])
        }
    }

    func testShorteningSlicesTheCurveAndKeepsTheSourceSpan() throws {
        let d = try fixture([.init(t: 0, speed: 1), .init(t: 120, speed: 1)])
        // Integral of the new 1...4 linear curve through frame 80 is 160.
        var original = d
        mutateClip(&original, "clip:audio") { $0.speedRamp = NativeSpeedRamp(points: [.init(t: 0, speed: 4.0 / 3)]) }
        let changed = try success(original, .setShape(.speedUp), keepLength: false)
        let clip = try XCTUnwrap(findClip(changed, "clip:audio"))
        XCTAssertEqual(clip.durationFrames, 80)
        XCTAssertEqual(clip.speedRamp?.points.last?.t, 80)
        XCTAssertEqual(try XCTUnwrap(clip.speedRamp).sourcePosition(atClipFrame: 80), 160, accuracy: 1e-6)
    }

    func testClearKeepsOldRampedSpanAndConstantPlaybackRate() throws {
        var original = try fixture([.init(t: 0, speed: 2)])
        mutateClip(&original, "clip:audio") { $0.playbackRate = .init(numerator: 2, denominator: 1) }
        let cleared = try success(original, .clear, keepLength: false)
        XCTAssertEqual(findClip(cleared, "clip:audio")?.durationFrames, 120)
        XCTAssertNil(findClip(cleared, "clip:audio")?.speedRamp)
        let d = try fixture([.init(t: 0, speed: 2)])
        let longer = try success(d, .clear, keepLength: false)
        XCTAssertEqual(findClip(longer, "clip:audio")?.durationFrames, 240)
        XCTAssertEqual(findClip(longer, "clip:follower")?.startFrame, 240)
        try refused(try fixture(), .setShape(.speedUp), keepLength: false, code: .nonIntegralSourceBoundary)
    }

    func testRippleReconcilesTransitionsInTheSameUndoStep() throws {
        var original = try fixture()
        mutateClip(&original, "clip:first") { $0.parameterTracks = [] }
        original.sequence.tracks[0].transitions = [
            .init(id: "transition:ramp", cut: ("clip:first", "clip:second"), kind: .dip, durationFrames: 60)
        ]
        original = try parseNativeProjectDocument(original, engine: engine)
        let result = try applyNativeSpeedRampCommand(original, clipId: "clip:first", .addPoint(t: 0, speed: 6),
                                                    keepLength: false, engine: engine)
        XCTAssertTrue(result.ok, "\(String(describing: result.failure))")
        XCTAssertEqual(findClip(result.document, "clip:first")?.durationFrames, 20)
        XCTAssertEqual(findClip(result.document, "clip:second")?.startFrame, 20)
        XCTAssertEqual(result.document.sequence.tracks[0].cutTransitions.first?.durationFrames, 20)
        let restored = try applyNativeProjectClipCommand(result.document, XCTUnwrap(result.inverse), engine: engine)
        XCTAssertEqual(restored.document, original)
    }

    func testNoRampUsesTheConstantRateForTheOldSpan() throws {
        var original = try fixture()
        mutateClip(&original, "clip:audio") { $0.playbackRate = .init(numerator: 2, denominator: 1) }
        let changed = try success(original, .addPoint(t: 0, speed: 0.5), keepLength: false)
        let clip = try XCTUnwrap(findClip(changed, "clip:audio"))
        XCTAssertEqual(clip.durationFrames, 480)
        XCTAssertEqual(try XCTUnwrap(clip.speedRamp).sourcePosition(atClipFrame: clip.durationFrames), 240, accuracy: 1e-6)
        XCTAssertEqual(findClip(changed, "clip:follower")?.startFrame, 480)
    }

    func testUnsupportedRampIsRefusedForEveryCommand() throws {
        for ramp in [NativeSpeedRamp(v: 2, points: []), NativeSpeedRamp(kind: "future", points: [])] {
            var original = try fixture()
            mutateClip(&original, "clip:audio") { $0.speedRamp = ramp }
            for command: NativeSpeedRampCommand in [.setShape(.slowMiddle), .addPoint(t: 0, speed: 1),
                                                     .movePoint(index: 0, t: 0, speed: 1), .removePoint(index: 0),
                                                     .setEase(index: 0, ease: .linear), .clear] {
                try refused(original, command)
            }
        }
    }
}
