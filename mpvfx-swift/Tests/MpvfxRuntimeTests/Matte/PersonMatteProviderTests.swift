import XCTest
import MpvfxShared
@testable import MpvfxRuntime

/// The matte provider interface with the stub provider, the cache writer's durable write, and the export pre-flight.
final class PersonMatteProviderTests: XCTestCase {
    var dir = ""
    let roots = TempRoots()

    override func setUpWithError() throws {
        dir = try roots.make("matte-")
        try Data((0..<4096).map { UInt8($0 % 241) }).write(to: URL(fileURLWithPath: dir + "/clip.mp4"))
    }
    override func tearDown() { roots.cleanup() }

    func document() throws -> NativeProjectDocument {
        try parseNativeProjectDocument(try NativeJSONValue.parse("""
        {"schemaVersion":1,"id":"project:m","revision":1,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":640,"height":360,"background":"#000000"},
         "assets":[{"id":"a","kind":"video","name":"Interview 2","source":"clip.mp4","durationFrames":900,"width":640,"height":360}],
         "sequence":{"id":"s","name":"Main","tracks":[{"id":"t1","kind":"video","clips":[
           {"id":"C","assetId":"a","startFrame":360,"durationFrames":240,"sourceInFrame":0,"muted":false,
            "effects":[{"id":"e1","effectId":"person-matte","enabled":true,"parameters":{"v":1,"quality":"balanced"}}],"parameterTracks":[]}]}]}}
        """))
    }

    func request(_ doc: NativeProjectDocument, durableWrite: DurableWrite = TestDurableWrite()) throws -> MatteAnalysisRequest {
        let clip = doc.sequence.tracks[0].clips[0]
        let key = try XCTUnwrap(PersonMatteEffect.cacheKey(clip: clip, asset: doc.assets[0], mediaPath: dir + "/clip.mp4", projectFPS: 30, quality: "balanced"))
        return MatteAnalysisRequest(mediaPath: dir + "/clip.mp4", assetName: "Interview 2", key: key, fps: 30,
                                    writer: MatteCacheWriter(key: key, fps: 30, projectDir: dir, durableWrite: durableWrite))
    }

    func testStubProviderWritesACacheTheReaderReadsBack() async throws {
        let doc = try document()
        let r = try request(doc)
        var seen: [Double] = []
        let progress = ProgressBox()
        try await StubMatteProvider().analyse(r, progress: { progress.add($0) }, cancel: { false })
        seen = progress.values
        XCTAssertEqual(seen.last, 1)
        XCTAssertEqual(r.key.width, 512); XCTAssertEqual(r.key.height, 288)
        XCTAssertTrue(r.writer.path.hasSuffix(".studio/analysis/person-matte/\(r.key.name).matte"))
        let reader = try PersonMatteCacheReader(path: r.writer.path, expectedKey: r.key)
        XCTAssertEqual(reader.frameCount, 240)
        let frame = try XCTUnwrap(reader.frame(atSourceSeconds: 1.0))
        XCTAssertEqual(frame.alpha[144 * 512 + 256], 255, "centre is a person")
        XCTAssertEqual(frame.alpha[0], 0)
        // 512 x 288 bytes a frame, run-length coded: far below the 40 MB per minute budget at 30 fps.
        let size = try FileManager.default.attributesOfItem(atPath: r.writer.path)[.size] as! Int
        XCTAssertLessThan(Double(size) / 240 * 1800, 40e6)
    }

    func testUnavailableAndCancelledAnalysesAreTypedErrors() async throws {
        let doc = try document()
        let none = StubMatteProvider(availability: .unavailable(.platformHasNoPersonSegmentation))
        XCTAssertEqual(none.availability(), .unavailable(.platformHasNoPersonSegmentation))
        XCTAssertEqual(MatteUnavailableReason.platformHasNoPersonSegmentation.message,
                       "Person matte analysis needs macOS. Mattes already analysed on a Mac are still shown.")
        do { try await none.analyse(try request(doc), progress: { _ in }, cancel: { false }); XCTFail("ran") }
        catch { XCTAssertEqual(error as? MatteError, .unavailable(.platformHasNoPersonSegmentation)) }
        do { try await StubMatteProvider().analyse(try request(doc), progress: { _ in }, cancel: { true }); XCTFail("ran") }
        catch { XCTAssertEqual(error as? MatteError, .cancelled) }
        let failing = StubMatteProvider(failure: (afterFrames: 3, error: .providerFailed(code: "boom", message: "no")))
        let r = try request(doc)
        do { try await failing.analyse(r, progress: { _ in }, cancel: { false }); XCTFail("ran") }
        catch { XCTAssertEqual(error as? MatteError, .providerFailed(code: "boom", message: "no")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.writer.path), "an analysis that stopped writes no file")
    }

    func testA5ExportWithAnIncompleteCacheIsRefusedNamingTheClipAndRange() async throws {
        let doc = try document()
        let before = planExport(doc, settings: .init(), projectDir: dir)
        XCTAssertFalse(before.canStart)
        XCTAssertTrue(before.issues.contains("Interview 2: the person matte is not analysed for 00:12–00:20"), "\(before.issues)")
        XCTAssertThrowsError(try startExport(project: doc, projectDir: dir, outputPath: dir + "/out.mp4", settings: .init())) { error in
            XCTAssertTrue("\(error)".contains("Interview 2: the person matte is not analysed"), "\(error)")
        }
        // A cache for a shorter range is a different key: still not analysed.
        var shorter = doc
        shorter.sequence.tracks[0].clips[0].durationFrames = 120
        let r = try request(shorter)
        try await StubMatteProvider().analyse(r, progress: { _ in }, cancel: { false })
        XCTAssertTrue(planExport(doc, settings: .init(), projectDir: dir).issues.contains { $0.contains("person matte") })
        // Damaged file: refused too.
        let full = try request(doc)
        try await StubMatteProvider().analyse(full, progress: { _ in }, cancel: { false })
        XCTAssertFalse(planExport(doc, settings: .init(), projectDir: dir).issues.contains { $0.contains("person matte") }, "analysed: accepted")
        let data = try Data(contentsOf: URL(fileURLWithPath: full.writer.path))
        try data.prefix(data.count - 5).write(to: URL(fileURLWithPath: full.writer.path))
        XCTAssertTrue(planExport(doc, settings: .init(), projectDir: dir).issues.contains { $0.contains("person matte") })
        // Without a project folder the check is skipped (the plan cannot know).
        XCTAssertFalse(planExport(doc, settings: .init()).issues.contains { $0.contains("person matte") })
    }

    func testAnEntryFromANewerVersionDoesNotBlockExportAndIsNoticed() throws {
        var doc = try document()
        doc.sequence.tracks[0].clips[0].effects[0].parameters = ["v": .number(2), "quality": .string("balanced")]
        let plan = planExport(doc, settings: .init(), projectDir: dir)
        XCTAssertFalse(plan.issues.contains { $0.contains("person matte") || $0.contains("effects that have not been migrated") }, "\(plan.issues)")
        XCTAssertTrue(plan.notices.contains { $0.contains("person-matte") })
    }

    /// Fails the write after the temporary file is complete, as a crash before the rename would.
    final class InterruptedWrite: DurableWrite, @unchecked Sendable {
        let base = TestDurableWrite()
        struct Interrupted: Error {}
        func write(_ data: Data, to path: String, tempName: String, preserveMode: Bool, beforeRename: () throws -> Void) throws {
            try base.write(data, to: path, tempName: tempName, preserveMode: preserveMode, beforeRename: { throw Interrupted() })
        }
        func syncDirectory(_ path: String) throws { try base.syncDirectory(path) }
    }

    func testA6AnInterruptedWriteLeavesThePreviousCacheIntact() async throws {
        let doc = try document()
        let first = try request(doc)
        try await StubMatteProvider().analyse(first, progress: { _ in }, cancel: { false })
        let previous = try Data(contentsOf: URL(fileURLWithPath: first.writer.path))

        let second = try request(doc, durableWrite: InterruptedWrite())
        let other = StubMatteProvider(script: StubMatteProvider.centredEllipse(radiusX: 0.1, radiusY: 0.1))
        do { try await other.analyse(second, progress: { _ in }, cancel: { false }); XCTFail("written") }
        catch let MatteError.cacheWriteFailed(path, _) { XCTAssertEqual(path, first.writer.path) }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: first.writer.path)), previous, "the previous cache is untouched")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: PosixPath.dirname(first.writer.path))
        XCTAssertEqual(leftovers, ["\(first.key.name).matte"], "no temporary file is left behind")
        XCTAssertNoThrow(try PersonMatteCacheReader(path: first.writer.path, expectedKey: first.key))
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [Double] = []
    func add(_ v: Double) { lock.lock(); all.append(v); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return all }
}
