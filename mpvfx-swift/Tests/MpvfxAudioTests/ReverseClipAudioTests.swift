import XCTest
import MpvfxShared
import MpvfxAudioGraph
@testable import MpvfxAudio

/// Issue #294: a reversed clip sounds backwards in the live graph and in the export mix, which render the same project
/// (`DocumentAudioGraph.project`, decoded by `DocumentAudioGraph.decodeStem`).
final class ReverseClipAudioTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws { dir = try WavFixtures.tempDir() }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    /// A rising tone: 300 Hz to 3000 Hz over 2 s, mono, 48 kHz.
    func risingTone() throws -> String {
        var phase = 0.0
        let samples = (0..<96_000).map { i -> Float in
            let f = 300 + 2700 * Double(i) / 96_000
            phase += 2 * Double.pi * f / 48_000
            return Float(0.4 * sin(phase))
        }
        return try WavFixtures.write("rise.wav", in: dir, samples, sampleRate: 48_000, encoding: .s16)
    }

    func document(_ path: String, clipExtra: String) throws -> NativeProjectDocument {
        let json = """
        {"schemaVersion":1,"id":"p","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":64,"height":36,"background":"#000000"},
         "assets":[{"id":"a","kind":"audio","name":"rise.wav","source":"\(path)","durationFrames":60}],
         "sequence":{"id":"s","name":"S","tracks":[{"id":"t","kind":"audio","clips":[
          {"id":"c","assetId":"a","startFrame":0,"durationFrames":60,"sourceInFrame":0,"muted":false,"effects":[],"parameterTracks":[]\(clipExtra)}]}]}}
        """
        return try parseNativeProjectDocument(try NativeJSONValue.parse(json))
    }

    /// The offline render (export's mix) and the live source's output after a seek to 0, for the document's one clip.
    func render(_ doc: NativeProjectDocument) throws -> (export: [Float], live: [Float])? {
        let inputs = DocumentAudioGraph.inputs(doc, duration: 2, projectDir: nil, fileExists: { _ in true })
        guard !inputs.tracks.isEmpty else { return nil }
        var issues: [String] = []
        let project = DocumentAudioGraph.project(inputs, loadStem: { try DocumentAudioGraph.decodeStem($0, sampleRate: 48_000) },
                                                 issues: &issues, sampleRate: 48_000)
        XCTAssertEqual(issues, [])
        let export = AudioGraphRenderer.renderOffline(project)
        let source = GraphAudioSource(project: project)
        let out = NullAudioOutput(format: source.format)
        let playback = AudioPlayback(output: out, source: source)
        playback.source.seek(0)
        for _ in 0..<(96_000 / 128) { try playback.pump() }
        return (export, out.written)
    }

    /// Zero crossings per second of the left channel of interleaved stereo `x` over the frame range.
    func rate(_ x: [Float], frames: Range<Int>) -> Double {
        crossingsPerSecond(frames.map { x[2 * $0] }, sampleRate: 48_000)
    }

    /// A3: a rising tone reversed is falling, in the live graph and in the export mix.
    func testA3ReversedRisingToneIsFallingInLiveGraphAndExport() throws {
        let path = try risingTone()
        let forward = try XCTUnwrap(render(document(path, clipExtra: "")))
        let reversed = try XCTUnwrap(render(document(path, clipExtra: #","reversed":true"#)))
        let early = 4_800..<19_200, late = 76_800..<91_200
        for (name, f, r) in [("export", forward.export, reversed.export), ("live", forward.live, reversed.live)] {
            XCTAssertGreaterThan(rate(f, frames: late), rate(f, frames: early) * 3, "\(name): the source tone rises")
            XCTAssertLessThan(rate(r, frames: late), rate(r, frames: early) / 3, "\(name): reversed it falls")
            XCTAssertEqual(rate(r, frames: early), rate(f, frames: late), accuracy: rate(f, frames: late) * 0.1,
                           "\(name): the reversed start is the source end")
        }
        XCTAssertEqual(reversed.live.count >= 96_000 * 2 - 256, true)
        XCTAssertTrue(Array(reversed.live.prefix(2 * 90_000)) == Array(reversed.export.prefix(2 * 90_000)), "live equals export, sample for sample")
    }

    /// The stem is the source's samples last to first, exactly.
    func testReversedStemIsTheForwardStemBackwards() throws {
        let path = try risingTone()
        let key = DocumentAudioGraph.StemKey(path: path, sourceIn: 0, duration: 2, rate: 1)
        var back = key; back.reversed = true
        let f = try DocumentAudioGraph.decodeStem(key, sampleRate: 48_000)
        let b = try DocumentAudioGraph.decodeStem(back, sampleRate: 48_000)
        XCTAssertEqual(f[0].count, 96_000)
        XCTAssertTrue(b[0] == f[0].reversed() && b[1] == f[1].reversed())
        XCTAssertNotEqual(key, back, "a reversed stem is its own cache entry")
    }

    /// Reverse audio off mutes a reversed clip; absent or true plays it reversed.
    func testReverseAudioFalseMutesTheClip() throws {
        let path = try risingTone()
        func tracks(_ extra: String) throws -> Int {
            DocumentAudioGraph.inputs(try document(path, clipExtra: extra), duration: 2, projectDir: nil, fileExists: { _ in true }).tracks.count
        }
        XCTAssertEqual(try tracks(#","reversed":true"#), 1)
        XCTAssertEqual(try tracks(#","reversed":true,"reverseAudio":true"#), 1)
        XCTAssertEqual(try tracks(#","reversed":true,"reverseAudio":false"#), 0, "muted by choice")
    }
}
