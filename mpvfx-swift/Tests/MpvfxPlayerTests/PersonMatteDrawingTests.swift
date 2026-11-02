import XCTest
@testable import MpvfxPlayer
import MpvfxCanvas
import MpvfxShared

/// The person matte as the painter draws it (preview and export share `PreviewPainter`): a cached matte frame multiplies the
/// layer's alpha; a missing or damaged cache draws the clip unmatted.
final class PersonMatteDrawingTests: XCTestCase {
    static let width = 640, height = 360
    var dir = ""

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("matte-\(UUID().uuidString.prefix(8))").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data((0..<4096).map { UInt8($0 % 251) }).write(to: URL(fileURLWithPath: dir + "/clip.mp4"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: dir) }

    func document(_ parameters: String = #"{"v":1,"quality":"balanced"}"#) throws -> NativeProjectDocument {
        try parseNativeProjectDocument(try NativeJSONValue.parse("""
        {"schemaVersion":1,"id":"project:m","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":\(Self.width),"height":\(Self.height),"background":"#00000000"},
         "assets":[{"id":"a","kind":"video","name":"Interview 2","source":"clip.mp4","durationFrames":300,"width":\(Self.width),"height":\(Self.height)}],
         "sequence":{"id":"s","name":"Main","tracks":[{"id":"t1","kind":"video","clips":[
           {"id":"C","assetId":"a","startFrame":0,"durationFrames":30,"sourceInFrame":0,"muted":false,
            "effects":[{"id":"e1","effectId":"person-matte","enabled":true,"parameters":\(parameters)}],"parameterTracks":[]}]}]}}
        """))
    }

    func composition(_ doc: NativeProjectDocument) -> PreviewComposition {
        PreviewComposition(document: doc, projectDir: URL(fileURLWithPath: dir), engine: nil)
    }

    func key(_ doc: NativeProjectDocument) throws -> PersonMatteCacheKey {
        let clip = doc.sequence.tracks[0].clips[0]
        return try XCTUnwrap(PersonMatteEffect.cacheKey(clip: clip, asset: doc.assets[0], mediaPath: dir + "/clip.mp4", projectFPS: 30, quality: "balanced"))
    }

    /// A centred hard-edged ellipse matte, written the way the cache writer does.
    func writeCache(_ key: PersonMatteCacheKey, version: Int = 1, keyName: String? = nil, truncate: Int = 0) throws {
        let w = key.width, h = key.height
        var frame = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let dx = (Double(x) + 0.5 - Double(w) / 2) / (0.35 * Double(w)), dy = (Double(y) + 0.5 - Double(h) / 2) / (0.35 * Double(h))
            if dx * dx + dy * dy <= 1 { frame[y * w + x] = 255 }
        } }
        let header = PersonMatteCacheHeader(v: version, codec: PersonMatteCodec.codecName, frames: key.expectedFrameCount(fps: 30), width: w, height: h,
                                            fps: 30, key: keyName ?? key.name, digest: key.digest, sourceStartMs: key.sourceStartMs,
                                            sourceDurationMs: key.sourceDurationMs, quality: key.quality)
        var data = try PersonMatteCodec.encode(header: header, frames: [[UInt8]](repeating: frame, count: header.frames))
        if truncate > 0 { data = data.prefix(data.count - truncate) }
        let path = key.path(projectDir: dir)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
    }

    func white() -> CanvasImage {
        CanvasImage(width: Self.width, height: Self.height, rgba: [UInt8](repeating: 255, count: Self.width * Self.height * 4))
    }

    func paint(_ comp: PreviewComposition, time: Double = 0.2) throws -> CanvasImage {
        let painter = try ExportFramePainter(composition: comp, width: Self.width, height: Self.height, pad: .transparent)
        return try painter.paint(time: time) { _, _, _, _ in self.white() }
    }

    func alpha(_ img: CanvasImage, _ x: Int, _ y: Int) -> Int { Int(img.rgba[(y * img.width + x) * 4 + 3]) }
    /// First x on row `y` whose alpha reaches 128.
    func edge(_ img: CanvasImage, y: Int = 180) -> Int { (0..<img.width).first { alpha(img, $0, y) >= 128 } ?? -1 }

    func testA2WhiteClipWithTheEllipseMatteIsOpaqueInsideAndTransparentOutside() throws {
        let doc = try document()
        try writeCache(try key(doc))
        let comp = composition(doc)
        let img = try paint(comp)
        XCTAssertEqual(Array(img.rgba[((180 * img.width + 320) * 4)..<((180 * img.width + 320) * 4 + 4)]), [255, 255, 255, 255], "inside reads white")
        XCTAssertEqual(alpha(img, 5, 5), 0)
        XCTAssertEqual(alpha(img, 635, 355), 0, "outside is transparent")
        // radius 0.35 of 640 px: the left edge sits at 320 - 224 = 96 at layer size.
        XCTAssertEqual(Double(edge(img)), 96, accuracy: 1)
        let top = (0..<img.height).first { alpha(img, 320, $0) >= 128 } ?? -1
        XCTAssertEqual(Double(top), 180 - 126, accuracy: 1)
        // The preview's painter path draws the same pixels.
        let canvas = try RasterCanvas(width: Self.width, height: Self.height)
        canvas.clear(.transparent)
        let layer = try XCTUnwrap(comp.layers(at: 0.2).first)
        XCTAssertNotNil(layer.matte)
        PreviewPainter.draw(layer, image: white(), on: canvas, frame: CanvasRect(x: 0, y: 0, width: 640, height: 360), scale: 1)
        XCTAssertEqual(canvas.image().rgba, img.rgba, "preview and export draw through the same painter")
    }

    func testTheMatteIsTheNearestEarlierFrameNeverInterpolated() throws {
        let doc = try document()
        let k = try key(doc)
        try writeCache(k)
        let comp = composition(doc)
        let a = try XCTUnwrap(comp.layers(at: 0.2).first?.matte), b = try XCTUnwrap(comp.layers(at: 0.2 + 0.01).first?.matte)
        XCTAssertEqual(a.identity, b.identity, "0.01 s later is still analysed frame 6")
        let c = try XCTUnwrap(comp.layers(at: 0.2 + 1.0 / 30).first?.matte)
        XCTAssertNotEqual(a.identity, c.identity)
    }

    func testA3ShrinkMovesTheEdgeInwardByFourPixels() throws {
        let plain = try document(), shrunk = try document(#"{"v":1,"quality":"balanced","shrink":4}"#)
        try writeCache(try key(plain))
        let before = edge(try paint(composition(plain))), after = edge(try paint(composition(shrunk)))
        XCTAssertEqual(Double(after - before), 4, accuracy: 1)
        let grown = try document(#"{"v":1,"quality":"balanced","shrink":-4}"#)
        XCTAssertEqual(Double(edge(try paint(composition(grown))) - before), -4, accuracy: 1)
    }

    func testA3SoftenTenPixelsGivesHalfAlphaAtTheEdge() throws {
        let plain = try document(), soft = try document(#"{"v":1,"quality":"balanced","soften":10}"#)
        try writeCache(try key(plain))
        let before = edge(try paint(composition(plain)))
        let img = try paint(composition(soft))
        let a = Double(alpha(img, before, 180)) / 255
        XCTAssertEqual(a, 0.5, accuracy: 0.03 + 1.0 / 255)
        XCTAssertGreaterThan(alpha(img, before - 12, 180), 0)
        XCTAssertLessThan(alpha(img, before - 12, 180), 100, "the soft edge spreads outward")
    }

    func testA3InvertSwapsInsideAndOutside() throws {
        let plain = try document(), inverted = try document(#"{"v":1,"quality":"balanced","invert":true}"#)
        try writeCache(try key(plain))
        let img = try paint(composition(inverted))
        XCTAssertEqual(alpha(img, 320, 180), 0)
        XCTAssertEqual(alpha(img, 5, 5), 255)
    }

    func testA4DamagedCachesDrawUnmattedAndReportOnce() throws {
        let doc = try document()
        let k = try key(doc)
        let damages: [(String, () throws -> Void)] = [
            ("truncated", { try self.writeCache(k, truncate: 40) }),
            ("wrong v", { try self.writeCache(k, version: 2) }),
            ("wrong key", { try self.writeCache(k, keyName: "another-key") }),
        ]
        for (name, damage) in damages {
            try? FileManager.default.removeItem(atPath: k.path(projectDir: dir))
            try damage()
            let comp = composition(doc)   // the project opens
            for time in [0.0, 0.2, 0.5] {
                let layer = try XCTUnwrap(comp.layers(at: time).first, name)
                XCTAssertNil(layer.matte, name)
                XCTAssertTrue(layer.matteNeedsAnalysis, "Matte needs analysing: \(name)")
            }
            let img = try paint(comp)
            XCTAssertEqual(alpha(img, 5, 5), 255, "\(name): drawn without the matte")
            let store = try XCTUnwrap(comp.entries[0].personMatte?.store)
            XCTAssertEqual(store.corruptionReports.count, 1, "\(name): reported once")
            XCTAssertEqual(store.corruptionReports.first?.path, k.path(projectDir: dir))
        }
    }

    func testAMissingCacheDrawsUnmattedAndIsNotReportedAsCorrupt() throws {
        let comp = composition(try document())
        let layer = try XCTUnwrap(comp.layers(at: 0.2).first)
        XCTAssertNil(layer.matte); XCTAssertTrue(layer.matteNeedsAnalysis)
        XCTAssertEqual(comp.entries[0].personMatte?.store.corruptionReports.count, 0)
    }

    func testTheReaderKeepsAtMostSixtyFourFramesDecoded() throws {
        let doc = try document()
        let clip = doc.sequence.tracks[0].clips[0]
        var long = clip; long.durationFrames = 300
        let k = try XCTUnwrap(PersonMatteEffect.cacheKey(clip: long, asset: doc.assets[0], mediaPath: dir + "/clip.mp4", projectFPS: 30, quality: "balanced"))
        try writeCache(k)
        let reader = try PersonMatteCacheReader(path: k.path(projectDir: dir), expectedKey: k)
        for i in 0..<reader.frameCount { XCTAssertNotNil(reader.frame(index: i)) }
        XCTAssertLessThanOrEqual(reader.decodedFrameCount, PersonMatteCacheReader.maxFrames)
        XCTAssertLessThanOrEqual(PersonMatteCacheReader.maxFrames * 512 * 512, MemoryBudget.personMatteFrames())
    }

    /// Estimated budget: at most 2 ms per 1080p frame (the issue's estimate). Reported, not asserted tightly: the
    /// machine and build configuration decide it. Only the unshrunk, unsoftened path is expected to meet it.
    func testDrawingBenchmarkReport() throws {
        let frame = PersonMatteFrame(width: 512, height: 288, alpha: [UInt8](repeating: 255, count: 512 * 288))
        let image = CanvasImage(width: 1920, height: 1080, rgba: [UInt8](repeating: 255, count: 1920 * 1080 * 4))
        for (label, matte) in [("plain", PreviewMatte(identity: "b", frame: frame)),
                               ("shrink4", PreviewMatte(identity: "b", frame: frame, shrink: 4)),
                               ("soften10", PreviewMatte(identity: "b", frame: frame, soften: 10))] {
            let start = ContinuousClock.now
            for _ in 0..<5 { _ = PersonMatteApplier.apply(matte, to: image) }
            let ms = (start.duration(to: .now) / 5).components.attoseconds / 1_000_000_000_000_000
            print("person-matte apply 1080p \(label): \(ms) ms/frame")
        }
    }
}
