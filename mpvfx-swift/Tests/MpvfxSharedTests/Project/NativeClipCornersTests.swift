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

/// Corner-pin model (#451): saved in project.json, validated, round-trips, one perspective mapping.
final class NativeClipCornersTests: XCTestCase {
    private func projectJSON(corners: String) -> String {
        """
        {"schemaVersion":1,"id":"project:t","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":200,"height":100,"background":"#000000"},
         "assets":[{"id":"a","kind":"image","name":"a.png","source":"a.png","durationFrames":100}],
         "sequence":{"id":"s","name":"Main","tracks":[{"id":"t","kind":"video","clips":[
          {"id":"c","assetId":"a","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]\(corners)}]}]}}
        """
    }

    func testCornersRoundTripThroughProjectJSON() throws {
        let json = projectJSON(corners: #","corners":{"tl":{"x":0.1,"y":0},"tr":{"x":0,"y":0.2},"br":{"x":-0.1,"y":0},"bl":{"x":0,"y":-0.2}}"#)
        let doc = try parseNativeProjectDocument(try NativeJSONValue.parse(json))
        let corners = try XCTUnwrap(doc.sequence.tracks[0].clips[0].corners)
        XCTAssertEqual(corners.tl.x, 0.1); XCTAssertEqual(corners.tr.y, 0.2); XCTAssertEqual(corners.bl.y, -0.2)
        let text = try serializeNativeProjectDocument(doc)
        let again = try parseNativeProjectDocument(try NativeJSONValue.parse(text))
        XCTAssertEqual(again, doc)
        XCTAssertTrue(text.contains(#""corners""#))
    }

    func testAbsentCornersAreOmittedFromTheSavedProject() throws {
        let doc = try parseNativeProjectDocument(try NativeJSONValue.parse(projectJSON(corners: "")))
        XCTAssertNil(doc.sequence.tracks[0].clips[0].corners)
        XCTAssertFalse(try serializeNativeProjectDocument(doc).contains("corners"))
    }

    func testValidationRejectsMalformedCorners() throws {
        for bad in [#","corners":5"#,
                    #","corners":{"tl":{"x":0,"y":0}}"#,
                    #","corners":{"tl":{"x":9,"y":0},"tr":{"x":0,"y":0},"br":{"x":0,"y":0},"bl":{"x":0,"y":0}}"#,
                    #","corners":{"tl":{"x":"a","y":0},"tr":{"x":0,"y":0},"br":{"x":0,"y":0},"bl":{"x":0,"y":0}}"#] {
            let issues = validateNativeProjectDocument(try NativeJSONValue.parse(projectJSON(corners: bad)))
            XCTAssertTrue(issues.contains { $0.path.contains(".corners") && $0.code == .invalidClip }, "\(bad) should be rejected: \(issues)")
        }
    }

    func testHomographyMapsEveryCornerExactlyAndInverts() throws {
        let corners = NativeClipCorners(tl: .init(x: 0.25, y: 0.1), tr: .init(x: -0.25, y: 0), br: .init(x: 0.05, y: -0.1), bl: .init(x: 0, y: 0))
        let pin = NativeCornerPin(corners: corners)
        for (u, v, c) in [(0.0, 0.0, corners.tl), (1.0, 0.0, corners.tr), (1.0, 1.0, corners.br), (0.0, 1.0, corners.bl)] {
            let p = pin.map(u, v)
            XCTAssertEqual(p.x, u + c.x, accuracy: 1e-9); XCTAssertEqual(p.y, v + c.y, accuracy: 1e-9)
        }
        for (u, v) in [(0.3, 0.7), (0.5, 0.5), (0.9, 0.1)] {
            let p = pin.map(u, v)
            let back = try XCTUnwrap(pin.unmap(p.x, p.y))
            XCTAssertEqual(back.u, u, accuracy: 1e-9); XCTAssertEqual(back.v, v, accuracy: 1e-9)
        }
        XCTAssertTrue(pin.isConvex)
        XCTAssertFalse(pin.isAffine)
    }

    func testIdentityHasNoPinAndAParallelogramIsAffine() throws {
        XCTAssertNil(NativeClipCorners.identity.pin)
        let slant = NativeClipCorners(tl: .init(x: 0.2), tr: .init(x: 0.2), br: .init(x: 0.2), bl: .init(x: 0.2))
        XCTAssertTrue(try XCTUnwrap(slant.pin).isAffine)
        let bowTie = NativeClipCorners(tl: .init(x: 1), tr: .init(x: -1))
        XCTAssertFalse(try XCTUnwrap(bowTie.pin).isConvex)
    }

    func testResolvedReplacesOnlyKeyframedComponents() {
        let saved = NativeClipCorners(tl: .init(x: 0.1, y: 0.2))
        let out = saved.resolved { $0 == "corners.tl.x" ? 0.5 : nil }
        XCTAssertEqual(out.tl.x, 0.5); XCTAssertEqual(out.tl.y, 0.2)
    }

    func testEditingSavesKeyframesAndResets() throws {
        var clip = try parseNativeProjectDocument(try NativeJSONValue.parse(projectJSON(corners: ""))).sequence.tracks[0].clips[0]
        let rate = RationalFrameRate(numerator: 30, denominator: 1)
        let moved = NativeClipCorners(tr: .init(x: -0.2, y: 0.1))
        clip.setCorners(moved, atFrame: 3, frameRate: rate)
        XCTAssertEqual(clip.corners, moved); XCTAssertFalse(clip.hasCornerKeyframes)
        clip.setCorners(moved, atFrame: 3, frameRate: rate, keyframed: true)
        XCTAssertEqual(clip.parameterTracks.filter { NativeClipCorners.isCornerParameter($0.parameterId) }.count, 8)
        XCTAssertTrue(clip.hasCornerKeyframes)
        clip.setCorners(NativeClipCorners(tr: .init(x: -0.3, y: 0.1)), atFrame: 3, frameRate: rate)
        let track = try XCTUnwrap(clip.parameterTracks.first { $0.parameterId == "corners.tr.x" })
        XCTAssertEqual(track.keyframes.count, 1, "a second edit at the same frame replaces the key")
        clip.resetCorners()
        XCTAssertFalse(clip.hasCornerState)
        XCTAssertTrue(clip.parameterTracks.isEmpty)
    }
}
