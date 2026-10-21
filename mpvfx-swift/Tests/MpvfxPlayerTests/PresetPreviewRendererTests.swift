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
@testable import MpvfxPlayer
import MpvfxCanvas
import MpvfxColor
import MpvfxShared
import MpvfxTimeline

/// Grade preset thumbnails: the selected clip's frame graded with each preset, rendered off the UI thread, bounded.
final class PresetPreviewRendererTests: XCTestCase {
    static let packageRoot = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var dir: URL!
    var compositor: PreviewCompositor!

    override func setUpWithError() throws {
        dir = try TestMedia.scratch("preset-preview")
        _ = try TestMedia.PatternVideo().write(to: dir.appendingPathComponent("media.mov").path)
        // The clip sits at 2 s..3 s, so at time 0 it is not under the playhead and the compositor has no lane for it.
        let editor = try TimelineEditor(json: #"""
        {"schemaVersion":1,"id":"project:p","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":160,"height":90,"background":"#000000"},
         "assets":[{"id":"asset:a","kind":"video","name":"media.mov","source":"media.mov","durationFrames":30}],
         "sequence":{"id":"sequence:main","name":"Main","tracks":[
          {"id":"track:v1","kind":"video","lane":{"authoredTrack":1,"displayTrack":0},"clips":[
           {"id":"clip:a","assetId":"asset:a","startFrame":60,"durationFrames":30,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]}]}]}}
        """#)
        compositor = PreviewCompositor()
        compositor.composition = PreviewComposition(document: editor.document, projectDir: dir, engine: nil)
    }
    override func tearDown() {
        compositor?.stopAll()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// Polls like the panel's redraws do until the tile is ready.
    func ready(_ r: PresetPreviewRenderer, _ preset: String, w: Int = 120, h: Int = 68, file: StaticString = #filePath, line: UInt = #line) throws -> CanvasImage {
        for _ in 0..<50 {
            if case .ready(let img) = r.preview(clipId: "clip:a", presetId: preset, lut: nil, time: 0, pixelWidth: w, pixelHeight: h) { return img }
            r.wait()
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("\(preset) never became ready", file: file, line: line)
        throw XCTSkip("not ready")
    }

    func meanDiff(_ a: CanvasImage, _ b: CanvasImage) -> Double {
        XCTAssertEqual(a.width, b.width); XCTAssertEqual(a.height, b.height)
        return zip(a.rgba, b.rgba).map { abs(Double($0) - Double($1)) }.reduce(0, +) / Double(a.rgba.count)
    }

    func testTilesAreFramesAndDifferPerPreset() throws {
        let r = PresetPreviewRenderer(compositor: compositor)
        XCTAssertNil(compositor.lanes.first, "the clip is off the playhead")
        let ids = ["neutral", "warm-daylight", "mono-clean", "deep-contrast", "vhs-playback", "two-ink-print"]
        var tiles: [String: CanvasImage] = [:]
        for id in ids { tiles[id] = try ready(r, id) }
        for (id, img) in tiles {
            // aspect-fit inside 120x68: the 16:9 frame comes out 120x68 (rounded), never larger than the tile.
            XCTAssertLessThanOrEqual(img.width, 120, id); XCTAssertLessThanOrEqual(img.height, 68, id)
            XCTAssertGreaterThan(img.width, 100, id)
            let lumas = stride(from: 0, to: img.rgba.count, by: 4).map { (i: Int) -> Int in Int(img.rgba[i]) + Int(img.rgba[i + 1]) + Int(img.rgba[i + 2]) }
            XCTAssertGreaterThan(Set(lumas).count, 20, "\(id) shows a picture, not an empty box")
        }
        for i in ids.indices { for j in ids.indices where j > i {
            XCTAssertGreaterThan(meanDiff(tiles[ids[i]]!, tiles[ids[j]]!), 0.5, "\(ids[i]) and \(ids[j]) look different")
        } }
        // Neutral is the ungraded frame; mono has no colour.
        let mono = tiles["mono-clean"]!
        let chroma = stride(from: 0, to: mono.rgba.count, by: 4).map { i -> Int in
            let c = [mono.rgba[i], mono.rgba[i + 1], mono.rgba[i + 2]].map(Int.init); return c.max()! - c.min()!
        }.reduce(0, +) / (mono.width * mono.height)
        XCTAssertLessThan(chroma, 4)
        XCTAssertEqual(r.rendered, ids.count, "each tile graded once")
        // A second pass is served from the cache.
        for id in ids { _ = try ready(r, id) }
        XCTAssertEqual(r.rendered, ids.count)
    }

    /// A tile's grade carries the clip grade's contract (issue #172): contract 3 by default, 2 when asked.
    func testTileGradeUsesTheRequestedContract() throws {
        XCTAssertEqual(try XCTUnwrap(PresetPreviewRenderer.params(preset: "warm-daylight", lut: nil)).version, 3)
        XCTAssertEqual(try XCTUnwrap(PresetPreviewRenderer.params(preset: "warm-daylight", lut: nil, version: 2)).version, 2)
        XCTAssertTrue(try XCTUnwrap(PresetPreviewRenderer.params(preset: "warm-daylight", lut: nil, version: 3)).whiteBalanceGains)
    }

    func testCacheStaysUnderBudget() throws {
        let tile = 120 * 68 * 4
        let r = PresetPreviewRenderer(compositor: compositor, budgetBytes: tile * 3 + 100)
        for p in ColorGradeParams.presets { _ = try ready(r, p.id) }
        XCTAssertLessThanOrEqual(r.bytes, r.budgetBytes)
        XCTAssertLessThanOrEqual(r.count, 3)
        XCTAssertLessThanOrEqual(r.ownCache.bytes, r.ownCache.budgetBytes)
        r.reset()
        XCTAssertEqual(r.bytes, 0); XCTAssertEqual(r.count, 0)
    }

    func testUnavailableWithoutPicture() {
        let r = PresetPreviewRenderer(compositor: compositor)
        guard case .unavailable = r.preview(clipId: "clip:missing", presetId: "neutral", lut: nil, time: 0, pixelWidth: 120, pixelHeight: 68) else {
            return XCTFail("a clip with no picture has no preview")
        }
    }

    func testDownscaleAveragesAndKeepsAspect() {
        var px = [UInt8](repeating: 0, count: 4 * 2 * 4)
        for i in 0..<8 { px[i * 4] = i % 2 == 0 ? 0 : 200; px[i * 4 + 3] = 255 }
        let out = PresetPreviewRenderer.downscale(CanvasImage(width: 4, height: 2, rgba: px), fitting: 2, 2)
        XCTAssertEqual(out.width, 2); XCTAssertEqual(out.height, 1)
        XCTAssertEqual(out.rgba[0], 100); XCTAssertEqual(out.rgba[3], 255)
    }
}
