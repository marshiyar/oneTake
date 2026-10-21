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
import XCTest
import MpvfxCanvas
import MpvfxPanels
import MpvfxShared
import MpvfxTimeline
import OneTakeKeyframes
@testable import MpvfxPlayer

/// The matched look is an ordinary grade: the existing preview and export paths consume the same parameters.
final class LookMatchPainterTests: XCTestCase {
    func flat(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> CanvasImage {
        .init(width: 16, height: 16, rgba: (0..<256).flatMap { _ in [r, g, b, 255] })
    }
    func editor() throws -> TimelineEditor {
        try TimelineEditor(json: #"""
        {"schemaVersion":1,"id":"match","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":16,"height":16,"background":"#000000"},
         "assets":[{"id":"a","kind":"video","name":"take.mov","source":"take.mov","durationFrames":30}],
         "sequence":{"id":"s","name":"Main","tracks":[{"id":"v","kind":"video","clips":[
         {"id":"take","assetId":"a","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
        """#, engine: KeyframeRuntime())
    }

    func testExactMatchingRejectsNearestStandInsAndAcceptsOnlyRequestedFrame() throws {
        let e = try editor(), c = PreviewCompositor(decodesMedia: false)
        c.composition = PreviewComposition(document: e.document, projectDir: URL(fileURLWithPath: "/project"), engine: e.engine, fileExists: { _ in true })
        defer { c.stopAll() }
        let layer = try XCTUnwrap(c.composition?.layers(at: 0.5).first)
        c.cache.store(flat(30, 30, 30), lane: layer.laneKey, frame: 0)
        let r = PresetPreviewRenderer(compositor: c)
        if case .unavailable = r.gradedFrame(clipId: "take", time: 0.5, pixelWidth: 16, pixelHeight: 16, exactOnly: true) {} else { XCTFail("nearest frame must never be matched") }
        c.cache.store(flat(180, 180, 180), lane: layer.laneKey, frame: 15)
        _ = r.gradedFrame(clipId: "take", time: 0.5, pixelWidth: 16, pixelHeight: 16, exactOnly: true); r.wait()
        if case .ready(let image) = r.gradedFrame(clipId: "take", time: 0.5, pixelWidth: 16, pixelHeight: 16, exactOnly: true) {
            XCTAssertEqual(image.rgba[0], 180)
        } else { XCTFail("exact frame must become ready") }
    }

    func testExactMatchingStopsWaitingForTerminalDecodeFailure() throws {
        let e = try editor(), c = PreviewCompositor()
        c.composition = PreviewComposition(document: e.document, projectDir: URL(fileURLWithPath: "/project"), engine: e.engine, fileExists: { _ in true })
        defer { c.stopAll() }
        let layer = try XCTUnwrap(c.composition?.layers(at: 0).first)
        let lane = PreviewDecodeLane(layer: layer, fps: 30, cache: c.cache)
        var notifications = 0; lane.onFrame = { notifications += 1 }
        lane.giveUpIfNothingDecoded(); lane.giveUpIfNothingDecoded()
        XCTAssertEqual(notifications, 1, "terminal failure wakes the pending UI exactly once")
        let r = PresetPreviewRenderer(compositor: c)
        r.ownLane = lane
        if case .unavailable = r.gradedFrame(clipId: "take", time: 0, pixelWidth: 16, pixelHeight: 16, exactOnly: true) {} else { XCTFail("terminal failure must not remain rendering") }
    }

    func testMatchingReductionCannotMixInvisibleBlueIntoOpaqueRed() throws {
        let source = CanvasImage(width: 32, height: 16, rgba: (0..<512).flatMap { i in i % 2 == 0 ? [UInt8(255), 0, 0, 255] : [0, 0, 255, 0] })
        let reduced = PresetPreviewRenderer.downscale(source, fitting: 16, 16, alphaCorrect: true)
        let stats = try XCTUnwrap(LookMatch.statistics(reduced))
        XCTAssertEqual(stats.mean.x, 1, accuracy: 1e-9); XCTAssertEqual(stats.mean.z, 0, accuracy: 1e-9)
    }

    func testExistingOffsetIsNotMultipliedByNewExposure() throws {
        let e = try editor(); var grade = ColorGrading()
        grade.balance["offset"] = .init(hue: 0, amount: 0, level: 0.4)
        let matched = try XCTUnwrap(LookMatch.matched(grade, source: flat(77, 77, 77), reference: flat(115, 115, 115)))
        XCTAssertTrue(e.setColorGrading(clipId: "take", matched))
        let comp = PreviewComposition(document: e.document, projectDir: URL(fileURLWithPath: "/project"), engine: e.engine, fileExists: { _ in true })
        let preview = PreviewCompositor(); defer { preview.stopAll() }
        let shown = preview.graded(try XCTUnwrap(comp.layers(at: 0).first), flat(51, 51, 51), frame: 0, time: 0, fps: 30)
        XCTAssertEqual(Double(shown.rgba[0]), 115, accuracy: 2)
    }

    func testMatchedStatisticsImproveTheRenderedColourAndPreviewEqualsExport() throws {
        for (source, reference) in [(flat(60, 60, 60), flat(120, 120, 120)), (flat(110, 90, 70), flat(90, 100, 110))] {
            let e = try editor(), matched = try XCTUnwrap(LookMatch.matched(ColorGrading(), source: source, reference: reference))
            XCTAssertTrue(e.setColorGrading(clipId: "take", matched))
            let reopened = try TimelineEditor(json: serializeNativeProjectDocument(e.document, engine: e.engine), engine: e.engine)
            let comp = PreviewComposition(document: reopened.document, projectDir: URL(fileURLWithPath: "/project"), engine: e.engine, fileExists: { _ in true })
            let layer = try XCTUnwrap(comp.layers(at: 0).first)
            let preview = PreviewCompositor(); defer { preview.stopAll() }
            let shown = preview.graded(layer, source, frame: 0, time: 0, fps: 30)
            let painter = try ExportFramePainter(composition: comp, width: 16, height: 16, pad: .init(r: 0, g: 0, b: 0))
            let exported = try painter.paint(time: 0) { _, _, _, _ in source }
            XCTAssertEqual(exported.rgba, shown.rgba, "saved values go through the same grade and painter contract")
            func error(_ image: CanvasImage) -> Double {
                zip(image.rgba.prefix(3), reference.rgba.prefix(3)).reduce(0) { $0 + abs(Double($1.0) - Double($1.1)) }
            }
            XCTAssertLessThan(error(shown), error(source) * 0.2, "the synthetic brightness/cast moves towards the reference")
        }
    }
}
