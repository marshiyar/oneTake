import XCTest
@testable import MpvfxPlayer
import MpvfxCanvas
import MpvfxShared
import OneTakeMedia

/// Issue #294: a reversed clip shows backwards in preview and export. The fixture is a lossless clip whose frame n is
/// a solid colour that encodes n (red steps of 16 for n mod 16, green steps of 16 for n / 16), so a picture names the
/// source frame it came from.
final class ReversedClipTests: XCTestCase {
    var dir: URL!
    override func tearDown() { if let dir { try? FileManager.default.removeItem(at: dir) } }

    static func color(_ n: Int) -> [UInt8] { [UInt8((n % 16) * 16), UInt8((n / 16) * 16), 0] }
    static func number(r: UInt8, g: UInt8) -> Int { Int((Double(r) / 16).rounded()) % 16 + 16 * Int((Double(g) / 16).rounded()) }

    func makeMedia(frames: Int, width: Int = 64, height: Int = 36) throws {
        dir = try TestMedia.scratch("reversed")
        let w = try TestMedia.movWriter(path: dir.appendingPathComponent("n.mov").path, width: width, height: height, fps: 30)
        for n in 0..<frames { try w.addVideo(TestMedia.solid(Self.color(n), width: width, height: height)) }
        try w.finish()
    }

    func document(assetFrames: Int, sourceIn: Int, duration: Int, extra: String = #","reversed":true"#,
                  width: Int = 64, height: Int = 36) throws -> NativeProjectDocument {
        let json = """
        {"schemaVersion":1,"id":"p","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":\(width),"height":\(height),"background":"#000000"},
         "assets":[{"id":"a","kind":"video","name":"n.mov","source":"n.mov","durationFrames":\(assetFrames)}],
         "sequence":{"id":"s","name":"S","tracks":[{"id":"t","kind":"video","clips":[
          {"id":"c","assetId":"a","startFrame":0,"durationFrames":\(duration),"sourceInFrame":\(sourceIn),"muted":false,"effects":[],"parameterTracks":[]\(extra)}]}]}}
        """
        return try parseNativeProjectDocument(try NativeJSONValue.parse(json))
    }

    func centre(_ rgba: [UInt8], width: Int, height: Int) -> Int {
        let i = ((height / 2) * width + width / 2) * 4
        return Self.number(r: rgba[i], g: rgba[i + 1])
    }

    // MARK: A1

    /// A1: exported frame k of a reversed clip shows source frame (in + out - 1 - k) for every k, across several
    /// export chunks.
    func testA1ExportedFrameKShowsSourceFrameInPlusOutMinusOneMinusK() throws {
        try makeMedia(frames: 100)
        let (sourceIn, length) = (10, 80)   // out = 90; 80 frames span three 32-frame chunks
        let reversed = try PreviewExportFrames(.init(document: document(assetFrames: 100, sourceIn: sourceIn, duration: length), projectDir: dir.path, width: 64, height: 36))
        for k in 0..<length {
            let t = Double(k) / 30
            XCTAssertEqual(centre(try reversed.frame(at: t), width: 64, height: 36), sourceIn + length - 1 - k, "reversed export frame \(k)")
        }
        // The reversed clip decoded a chunk per stream, not a seek per frame beyond the chunk's pictures.
        XCTAssertEqual(reversed.framesDecoded, length, "each source frame was decoded once")
    }

    // MARK: A2

    func canvas(width: Int, height: Int) throws -> (CanvasContext, CairoImageTarget) {
        #if os(Linux)
        let t = CairoImageTarget(width: width, height: height); return (t.canvas, t)
        #else
        throw XCTSkip("the preview pixel comparison reads a Cairo target (Linux)")
        #endif
    }

    /// A2: the preview playing at 10 times speed draws the pictures the export paints, frame by frame.
    func testA2PreviewAtTenTimesEqualsExport() throws {
        #if os(Linux)
        try makeMedia(frames: 100)
        let doc = try document(assetFrames: 100, sourceIn: 10, duration: 80)
        let cx = PreviewCompositor(cacheBudgetBytes: 32 << 20)
        defer { cx.stopAll() }
        cx.composition = PreviewComposition(document: doc, projectDir: dir, engine: nil)
        let export = try PreviewExportFrames(.init(document: doc, projectDir: dir.path, width: 64, height: 36))
        let (c, target) = try canvas(width: 64, height: 36)
        let rect = CanvasRect(x: 0, y: 0, width: 64, height: 36)
        let context = FrameDrawContext(isPlaying: true, speed: 10)
        var worst = 0
        for k in 0..<80 {
            let t = Double(k) / 30
            cx.draw(c, in: rect, time: t, elements: [], context: context)
            for l in cx.lanes.values { l.wait() }
            cx.draw(c, in: rect, time: t, elements: [], context: context)
            let preview = target.straightRGBA()
            let exported = try export.frame(at: t)
            XCTAssertEqual(centre(preview, width: 64, height: 36), 10 + 80 - 1 - k, "preview frame \(k) shows the source frame the export does")
            XCTAssertEqual(preview.count, exported.count)
            worst = max(worst, zip(preview, exported).map { abs(Int($0) - Int($1)) }.max() ?? 0)
        }
        XCTAssertLessThanOrEqual(worst, 1, "preview and export pixels agree to rounding")
        #else
        throw XCTSkip("Linux only")
        #endif
    }

    // MARK: Layer mapping

    func testLayerSourceTimeMirrorsTheClip() throws {
        let fwd = PreviewComposition(document: try document(assetFrames: 100, sourceIn: 10, duration: 20, extra: ""), projectDir: URL(fileURLWithPath: "/p"), engine: nil, fileExists: { _ in true })
        let rev = PreviewComposition(document: try document(assetFrames: 100, sourceIn: 10, duration: 20), projectDir: URL(fileURLWithPath: "/p"), engine: nil, fileExists: { _ in true })
        for k in 0..<20 {
            let t = Double(k) / 30
            XCTAssertEqual(try XCTUnwrap(fwd.layers(at: t).first).sourceTime(at: t), Double(10 + k) / 30, accuracy: 1e-9)
            XCTAssertEqual(try XCTUnwrap(rev.layers(at: t).first).sourceTime(at: t), (Double(10 + 19 - k) + 0.5) / 30, accuracy: 1e-9, "a reversed layer reads the middle of the source frame")
        }
        XCTAssertNotEqual(fwd.layers(at: 0)[0].laneKey, rev.layers(at: 0)[0].laneKey, "a reversed clip decodes in its own lane")
    }

    func testReversedClipAtDoubleSpeedStepsTwoSourceFramesBackwards() throws {
        let rate = #","reversed":true,"playbackRate":{"numerator":2,"denominator":1}"#
        let comp = PreviewComposition(document: try document(assetFrames: 100, sourceIn: 10, duration: 20, extra: rate), projectDir: URL(fileURLWithPath: "/p"), engine: nil, fileExists: { _ in true })
        // frame k of the forward clip shows 10 + 2k; reversed shows the mirrored frame 19 - k
        for k in 0..<20 {
            let t = Double(k) / 30
            XCTAssertEqual(try XCTUnwrap(comp.layers(at: t).first).sourceTime(at: t), (Double(10 + 2 * (19 - k)) + 1) / 30, accuracy: 1e-9)
        }
    }

    func testAHeldReversedClipHoldsTheFrameShown() throws {
        let extra = #","reversed":true,"holdSourceFrame":{"v":1,"frame":12}"#
        let comp = PreviewComposition(document: try document(assetFrames: 100, sourceIn: 12, duration: 10, extra: extra), projectDir: URL(fileURLWithPath: "/p"), engine: nil, fileExists: { _ in true })
        for k in [0, 5, 9] {
            let layer = try XCTUnwrap(comp.layers(at: Double(k) / 30).first)
            XCTAssertNil(layer.reverseFrames, "the hold decides what is shown")
            XCTAssertEqual(layer.sourceTime(at: Double(k) / 30), 12.0 / 30, accuracy: 1e-9)
        }
    }

    // MARK: Preview decode lane

    /// The lane decodes a reversed clip in chunks and the cache then holds every frame of a played-through window.
    func testLaneDecodesReversedFramesInChunks() throws {
        try makeMedia(frames: 100)
        let comp = PreviewComposition(document: try document(assetFrames: 100, sourceIn: 10, duration: 60), projectDir: dir, engine: nil)
        let layer = try XCTUnwrap(comp.layers(at: 0).first)
        let cache = PreviewFrameCache(budgetBytes: 32 << 20)
        let lane = PreviewDecodeLane(layer: layer, fps: 30, cache: cache)
        defer { lane.stop() }
        let size = PreviewDecodeSize(width: 64, height: 36)
        for f in stride(from: 0, to: 60, by: 1) {
            lane.request(frame: f, ahead: 12, size: size); lane.wait()
            let image = try XCTUnwrap(cache.frame(lane: lane.key, frame: f), "frame \(f)")
            XCTAssertEqual(centre(image.rgba, width: image.width, height: image.height), 10 + 59 - f, "timeline frame \(f)")
        }
        XCTAssertLessThan(lane.restarts, 10, "a stream per chunk, not per frame")
        XCTAssertEqual(lane.framesDecoded, 60, "no source frame decoded twice")
    }

    // MARK: A4

    /// A4 (scaled down, see the pull request): exporting a reversed 1080p clip keeps what the export holds within the
    /// preview frame budget of docs/MEMORY.md, and the process footprint grows by less than that budget.
    func testA4ReversedExportStaysWithinThePreviewFrameBudget() throws {
        let (w, h, n) = (1920, 1080, 90)
        try makeMedia(frames: n, width: w, height: h)
        let doc = try document(assetFrames: n, sourceIn: 0, duration: n, width: w, height: h)
        let export = try PreviewExportFrames(.init(document: doc, projectDir: dir.path, width: w, height: h))
        let budget = MemoryBudget.previewFrames()
        let chunk = ReversedFrameBuffer.capacity(width: w, height: h)
        XCTAssertLessThanOrEqual(chunk * w * h * 4, budget, "one chunk of decoded frames is inside the frame budget")
        XCTAssertLessThanOrEqual(chunk * w * h * 4, budget / 4 + w * h * 4)
        let baseline = ResidentMemory.footprintBytes() ?? 0
        var peak = baseline
        for k in 0..<n {
            XCTAssertEqual(centre(try export.frame(at: Double(k) / 30), width: w, height: h), n - 1 - k, "frame \(k)")
            peak = max(peak, ResidentMemory.footprintBytes() ?? 0)
        }
        print("A4 reversed 1080p export: \(n) frames, chunk \(chunk) frames, footprint growth \((peak - baseline) >> 20) MB, budget \(budget >> 20) MB")
        if baseline > 0 { XCTAssertLessThan(peak - baseline, budget, "peak memory growth stays within the preview frame budget") }
    }
}
