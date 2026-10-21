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

/// `clip.fit` (Fit, Fill, Stretch): where the picture lands in its box, the default box it implies, and the
/// document round trip (absent stays absent, so older projects open and save unchanged).
final class NativeMediaFitTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    /// A 1080×1920 (9:16) box, the whole portrait frame.
    let portrait = NativeClipLayoutBox(left: 0, top: 0, width: 1080, height: 1920)

    func parse(_ d: NativeJSONValue) throws -> NativeProjectDocument { try parseNativeProjectDocument(d, engine: engine) }
    func withFit(_ fit: String) -> NativeJSONValue {
        var d = validNativeDocument(); d["sequence"]?["tracks"]?[0]?["clips"]?[0]?["fit"] = J(fit); return d
    }
    func rejects(_ fit: String, file: StaticString = #filePath, line: UInt = #line) {
        do { _ = try parse(withFit(fit)); XCTFail("accepted \(fit)", file: file, line: line) }
        catch let e as NativeProjectDocumentValidationError {
            XCTAssertEqual(e.issues.map(\.path), ["sequence.tracks[0].clips[0].fit"], e.message, file: file, line: line)
            XCTAssertTrue(e.message.contains("Fit must be fit, fill or stretch"), e.message, file: file, line: line)
        } catch { XCTFail("\(error)", file: file, line: line) }
    }

    // Acceptance: without `fit`, a clip renders exactly as today.
    func testWithoutFitTheRectIsTheContainFitAsBefore() {
        let none = nativeMediaRect(imageWidth: 1920, imageHeight: 1080, box: portrait)
        XCTAssertEqual(none, NativeClipLayoutBox(left: 0, top: (1920 - 607.5) / 2, width: 1080, height: 607.5), "letterboxed, centred")
        XCTAssertEqual(nativeMediaRect(imageWidth: 1920, imageHeight: 1080, box: portrait, fit: nil), none)
        XCTAssertEqual(nativeMediaRect(imageWidth: 1920, imageHeight: 1080, box: portrait, fit: .fit), none, "Fit is the default")
        // A box within rounding of the picture's aspect is still filled exactly.
        let near = NativeClipLayoutBox(left: 10, top: 20, width: 1080, height: 608)
        XCTAssertEqual(nativeMediaRect(imageWidth: 1920, imageHeight: 1080, box: near), near)
    }

    // Acceptance: Fill on a 1920×1080 picture in a 1080×1920 box covers the whole box and keeps the aspect.
    func testFillCoversTheWholeBoxAndKeepsThePicturesAspect() {
        let r = nativeMediaRect(imageWidth: 1920, imageHeight: 1080, box: portrait, fit: .fill)
        XCTAssertLessThanOrEqual(r.left, 0); XCTAssertLessThanOrEqual(r.top, 0)
        XCTAssertGreaterThanOrEqual(r.left + r.width, 1080); XCTAssertGreaterThanOrEqual(r.top + r.height, 1920)
        XCTAssertEqual(r.width / r.height, 1920.0 / 1080.0, accuracy: 1e-9, "the picture's aspect")
        XCTAssertEqual(r.height, 1920, accuracy: 1e-9, "scaled to cover the taller side")
        XCTAssertEqual(r.left + r.width / 2, 540, accuracy: 1e-9, "centred"); XCTAssertEqual(r.top, 0, accuracy: 1e-9)
    }

    // Acceptance: Stretch maps the picture onto the box exactly.
    func testStretchMapsThePictureOntoTheBoxExactly() {
        XCTAssertEqual(nativeMediaRect(imageWidth: 1920, imageHeight: 1080, box: portrait, fit: .stretch), portrait)
        let placed = NativeClipLayoutBox(left: 12, top: -7, width: 300, height: 40)
        XCTAssertEqual(nativeMediaRect(imageWidth: 10, imageHeight: 10, box: placed, fit: .stretch), placed)
    }

    /// An untouched Fill or Stretch clip has no natural default box: it fills the whole canvas, so a 16:9 clip in a
    /// 9:16 project is not left letterboxed inside a box of its own aspect.
    func testAnUntouchedFillOrStretchClipTakesTheWholeCanvas() throws {
        var clip = try parse(validNativeDocument()).sequence.tracks[0].clips[0]
        clip.staticParameters = nil
        let natural = NativeMediaNaturalSize(width: 1920, height: 1080)
        let fitted = try XCTUnwrap(nativeClipFitLayout(clip, natural: natural, canvasWidth: 1080, canvasHeight: 1920))
        XCTAssertEqual(fitted, fitTimelineAssetGeometry(natural, compWidth: 1080, compHeight: 1920), "Fit keeps the natural default")
        for fit in [NativeMediaFit.fill, .stretch] {
            clip.fit = fit
            XCTAssertNil(nativeClipFitLayout(clip, natural: natural, canvasWidth: 1080, canvasHeight: 1920), "\(fit)")
            XCTAssertEqual(nativeClipWithNaturalLayout(clip, natural: natural, canvasWidth: 1080, canvasHeight: 1920), clip,
                           "no layout written: the box is the canvas")
        }
    }

    func testAbsentFitStaysAbsentAndOlderProjectsSaveUnchanged() throws {
        let doc = try parse(validNativeDocument())
        XCTAssertNil(doc.sequence.tracks[0].clips[0].fit)
        let text = try serializeNativeProjectDocument(validNativeDocument(), engine: engine)
        XCTAssertFalse(text.contains("\"fit\""))
        XCTAssertEqual(try serializeNativeProjectDocument(J(text), engine: engine), text, "a second save writes the same bytes")
    }

    func testEveryFitRoundTrips() throws {
        for fit in NativeMediaFit.allCases {
            let text = try serializeNativeProjectDocument(withFit("\"\(fit.rawValue)\""), engine: engine)
            XCTAssertTrue(text.contains("\"fit\": \"\(fit.rawValue)\""), text)
            XCTAssertEqual(try parse(J(text)).sequence.tracks[0].clips[0].fit, fit)
        }
    }

    func testRejectsMalformedFits() {
        rejects(#""cover""#)
        rejects(#""Fill""#)
        rejects("3")
        rejects("null")
        rejects(#"{"mode":"fill"}"#)
    }
}
