// Issue #307: camera moves (shake, punch-in, push) in the document, the validator and the pure evaluation.
import XCTest
@testable import MpvfxShared

final class NativeCameraMovesTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func parse(_ d: NativeJSONValue) throws -> NativeProjectDocument { try parseNativeProjectDocument(d, engine: engine) }
    func serialize(_ d: NativeJSONValue) throws -> String { try serializeNativeProjectDocument(d, engine: engine) }
    func withCamera(_ parameters: String?, enabled: Bool = true) -> NativeJSONValue {
        var d = validNativeDocument()
        let p = parameters.map { #","parameters":\#($0)"# } ?? ""
        d["sequence"]?["tracks"]?[0]?["clips"]?[0]?["effects"] = J(#"[{"id":"effect:cam","effectId":"camera-moves","enabled":\#(enabled)\#(p)}]"#)
        return d
    }
    func rejects(_ parameters: String, at path: String, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        do { _ = try parse(withCamera(parameters)); XCTFail("accepted \(parameters)", file: file, line: line) }
        catch let e as NativeProjectDocumentValidationError {
            XCTAssertEqual(e.issues.map(\.code), [.invalidEffect], e.message, file: file, line: line)
            XCTAssertEqual(e.issues.first?.path, "sequence.tracks[0].clips[0].effects[0].parameters\(path)", file: file, line: line)
            XCTAssertTrue(e.message.contains(text), e.message, file: file, line: line)
        } catch { XCTFail("\(error)", file: file, line: line) }
    }

    // MARK: A1 parameters and validator

    func testA1EveryFieldRoundTripsAndTheSerializedParametersAreTheInput() throws {
        let json = #"{"allowEdges":true,"punch":{"at":[0,30],"ease":{"type":"linear"},"everyFrames":15,"lengthFrames":8,"scale":1.3,"v":1},"#
            + #""push":{"direction":"up","drift":4,"endScale":1.2,"startScale":1,"v":1},"#
            + #""shake":{"amount":12,"frequency":3,"rotation":1.5,"seed":7,"v":1},"v":1}"#
        let doc = try parse(J(try serialize(withCamera(json))))
        let clip = doc.sequence.tracks[0].clips[0]
        let moves = try XCTUnwrap(clip.cameraMoves)
        XCTAssertEqual(moves.shake, NativeCameraShake(amount: 12, frequency: 3, rotation: 1.5, seed: 7))
        XCTAssertEqual(moves.punch, NativeCameraPunch(scale: 1.3, lengthFrames: 8, ease: .linear, at: [0, 30], everyFrames: 15))
        XCTAssertEqual(moves.push, NativeCameraPush(startScale: 1, endScale: 1.2, direction: .up, drift: 4))
        XCTAssertTrue(moves.allowEdges)
        XCTAssertEqual(clip.effects[0].parameters.map { NativeJSONValue.object($0) }, J(json))
    }

    func testA1ADocumentWithoutCameraMovesOpensAndSavesByteIdentical() throws {
        let first = try serialize(validNativeDocument())
        XCTAssertFalse(first.contains("camera-moves"))
        XCTAssertEqual(try serialize(J(first)), first)
        XCTAssertNil(try parse(J(first)).sequence.tracks[0].clips[0].cameraMoves)
        let withOne = try serialize(withCamera(#"{"v":1,"shake":{"v":1,"seed":3}}"#))
        XCTAssertEqual(try serialize(J(withOne)), withOne, "a document with camera moves saves byte-identical too")
        XCTAssertTrue(withOne.contains("\"schemaVersion\": 1"))
        XCTAssertNil(try parse(J(withOne)).unreadableCameraMovesNotice)
    }

    func testA1VersionsFromANewerEditorAreKeptUnchangedNotDrawnAndNoticedOnce() throws {
        let newer = #"{"v":2,"shake":{"v":1,"amount":"lots"},"extra":[1,2]}"#
        let section = #"{"v":1,"shake":{"v":3,"wobble":true},"push":{"v":1,"endScale":1.1}}"#
        var d = withCamera(newer)
        d["sequence"]?["tracks"]?[0]?["clips"]?.append(J(
            #"{"id":"clip:b","assetId":"asset:camera-a","startFrame":100,"durationFrames":30,"sourceInFrame":0,"effects":[{"id":"e2","effectId":"camera-moves","enabled":true,"parameters":\#(section)}],"parameterTracks":[]}"#))
        let first = try serialize(d)
        XCTAssertEqual(try serialize(J(first)), first, "kept byte for byte")
        let doc = try parse(J(first))
        XCTAssertNil(doc.sequence.tracks[0].clips[0].cameraMoves, "an unknown version is not drawn")
        XCTAssertNil(doc.sequence.tracks[0].clips[1].cameraMoves, "an unknown section version makes the effect unreadable")
        XCTAssertEqual(doc.unreadableCameraMovesCount, 2)
        XCTAssertEqual(doc.unreadableCameraMovesNotice,
                       "2 camera moves from a newer version of the editor are kept in the project but not drawn in preview or export.")
        XCTAssertEqual(doc.undrawnContentNotices.filter { $0.contains("camera move") }.count, 1, "one notice on open")
        XCTAssertNil(try parse(withCamera(newer, enabled: false)).unreadableCameraMovesNotice, "a disabled effect draws nothing anyway")
    }

    func testA1RulesParametersAndVersion() {
        rejects(#"{"shake":{"v":1}}"#, at: ".v", "version v")
        rejects(#"{"v":1.5}"#, at: ".v", "version v")
        rejects(#"{"v":1,"allowEdges":1}"#, at: ".allowEdges", "boolean")
        XCTAssertThrowsError(try parse(withCamera(nil)))
        rejects(#"{"v":1,"shake":[]}"#, at: ".shake", "object")
        rejects(#"{"v":1,"punch":{"scale":1.2}}"#, at: ".punch.v", "version v")
    }
    func testA1RulesShake() {
        rejects(#"{"v":1,"shake":{"v":1,"amount":-1}}"#, at: ".shake.amount", "0 through 200")
        rejects(#"{"v":1,"shake":{"v":1,"amount":201}}"#, at: ".shake.amount", "0 through 200")
        rejects(#"{"v":1,"shake":{"v":1,"amount":"8"}}"#, at: ".shake.amount", "0 through 200")
        rejects(#"{"v":1,"shake":{"v":1,"frequency":0}}"#, at: ".shake.frequency", "above 0")
        rejects(#"{"v":1,"shake":{"v":1,"frequency":5.5}}"#, at: ".shake.frequency", "5 Hz")
        rejects(#"{"v":1,"shake":{"v":1,"rotation":46}}"#, at: ".shake.rotation", "0 through 45")
        rejects(#"{"v":1,"shake":{"v":1,"seed":-1}}"#, at: ".shake.seed", "integer")
        rejects(#"{"v":1,"shake":{"v":1,"seed":1.5}}"#, at: ".shake.seed", "integer")
    }
    func testA1RulesPunchAndPush() {
        rejects(#"{"v":1,"punch":{"v":1,"scale":0.9}}"#, at: ".punch.scale", "1 through 1.5")
        rejects(#"{"v":1,"punch":{"v":1,"scale":1.6}}"#, at: ".punch.scale", "1 through 1.5")
        rejects(#"{"v":1,"punch":{"v":1,"lengthFrames":0}}"#, at: ".punch.lengthFrames", "length")
        rejects(#"{"v":1,"punch":{"v":1,"everyFrames":0}}"#, at: ".punch.everyFrames", "every")
        rejects(#"{"v":1,"punch":{"v":1,"at":[1,-2]}}"#, at: ".punch.at", "list of whole frames")
        rejects(#"{"v":1,"punch":{"v":1,"ease":{"type":"spring"}}}"#, at: ".punch.ease", "ease")
        rejects(#"{"v":1,"push":{"v":1,"startScale":0.4}}"#, at: ".push.startScale", "0.5 through 3")
        rejects(#"{"v":1,"push":{"v":1,"endScale":3.1}}"#, at: ".push.endScale", "0.5 through 3")
        rejects(#"{"v":1,"push":{"v":1,"drift":51}}"#, at: ".push.drift", "0 through 50")
        rejects(#"{"v":1,"push":{"v":1,"direction":"back"}}"#, at: ".push.direction", "left, right, up or down")
    }

    // MARK: A2 same seed, same offsets

    func testA2SameSeedGivesTheSameOffsetsAndAnotherSeedAnotherShake() {
        let a = NativeCameraShake(amount: 20, frequency: 3, rotation: 2, seed: 42)
        let samples = (0..<120).map { a.offsets(atSeconds: Double($0) / 30) }
        XCTAssertEqual(samples, (0..<120).map { NativeCameraShake(amount: 20, frequency: 3, rotation: 2, seed: 42).offsets(atSeconds: Double($0) / 30) })
        let b = NativeCameraShake(amount: 20, frequency: 3, rotation: 2, seed: 43)
        XCTAssertNotEqual(samples, (0..<120).map { b.offsets(atSeconds: Double($0) / 30) })
        XCTAssertEqual(NativeCameraShake(amount: 0, frequency: 3, rotation: 0, seed: 9).offsets(atSeconds: 1.234), .identity, "amount 0 is exactly no motion")
    }

    /// Recorded once from this code: 10 frames at 30 fps of seed 12345, amount 10 px, 3 Hz, rotation 2 degrees (dx, dy, rotation).
    /// Integer-only seeding; only `sin` is libm, so the table is compared to 1e-6.
    static let golden: [(Double, Double, Double)] = [
        (3.622768447405128, 2.590574545850485, -1.604581095301612),
        (4.710850713416378, 3.7581249407684068, -1.7311684679316617),
        (5.957459341331188, 5.658237526005769, -1.2316005542770516),
        (6.441100570865719, 6.911024017398746, -0.448191879090899),
        (5.112976989521253, 5.926483378523888, 0.18246157358387544),
        (1.654868998538921, 2.239680238889936, 0.3969543908573184),
        (-3.019154757314739, -2.9079166134597783, 0.24250675025120558),
        (-7.066242922095881, -7.261494899277704, 0.002961323624213308),
        (-8.71882510286422, -9.01862180889389, -0.02276619479787456),
        (-7.3623781885708475, -7.943348429599607, 0.2692313784970431),
    ]

    func testA2GoldenTableOfTenFrames() {
        let shake = NativeCameraShake(amount: 10, frequency: 3, rotation: 2, seed: 12345)
        XCTAssertEqual(Self.golden.count, 10)
        for (frame, expected) in Self.golden.enumerated() {
            let o = shake.offsets(atSeconds: Double(frame) / 30)
            XCTAssertEqual(o.dx, expected.0, accuracy: 1e-6, "dx at frame \(frame)")
            XCTAssertEqual(o.dy, expected.1, accuracy: 1e-6, "dy at frame \(frame)")
            XCTAssertEqual(o.rotation, expected.2, accuracy: 1e-6, "rotation at frame \(frame)")
        }
    }

    // MARK: A3 band limit

    func testA3ShakeSpectrumHasNoEnergyAboveTwiceTheSetFrequency() {
        let fps = 30.0, hz = 3.0, n = 300   // 10 s
        for seed in [0, 1, 12345] {
            let shake = NativeCameraShake(amount: 20, frequency: hz, rotation: 5, seed: seed)
            let offsets = (0..<n).map { shake.offsets(atSeconds: Double($0) / fps) }
            for channel in [\NativeMoveOffsets.dx, \NativeMoveOffsets.dy, \NativeMoveOffsets.rotation] {
                let x = offsets.map { $0[keyPath: channel] }
                let mean = x.reduce(0, +) / Double(n)
                // A Hann window keeps the 10 s cut from leaking low-frequency energy upward.
                let w = (0..<n).map { (x[$0] - mean) * 0.5 * (1 - cos(2 * Double.pi * Double($0) / Double(n - 1))) }
                var total = 0.0, above = 0.0
                for k in 1...(n / 2) {
                    var re = 0.0, im = 0.0
                    for t in 0..<n { let a = 2 * Double.pi * Double(k * t) / Double(n); re += w[t] * cos(a); im -= w[t] * sin(a) }
                    let power = re * re + im * im
                    total += power
                    if Double(k) * fps / Double(n) > 2 * hz { above += power }
                }
                XCTAssertGreaterThan(total, 0)
                XCTAssertLessThan(above / total, 1e-4, "seed \(seed): energy above \(2 * hz) Hz")
            }
        }
    }

    func testShakeStaysWithinItsAmount() {
        let shake = NativeCameraShake(amount: 40, frequency: 5, rotation: 3, seed: 5)
        for f in 0..<600 {
            let o = shake.offsets(atSeconds: Double(f) / 30)
            XCTAssertLessThanOrEqual(abs(o.dx), 40); XCTAssertLessThanOrEqual(abs(o.dy), 40); XCTAssertLessThanOrEqual(abs(o.rotation), 3)
        }
    }

    func testCoverScaleIsOneWithAllowEdgesOrNothingMoving() throws {
        let canvas = NativeCanvas(width: 1920, height: 1080, background: "")
        let shaky = NativeCameraMovesParameters(try XCTUnwrap(J(#"{"v":1,"shake":{"v":1,"amount":40}}"#).objectValue))
        XCTAssertGreaterThan(shaky.coverScale(width: 1920, height: 1080, canvas: canvas), 1.07)
        let edges = NativeCameraMovesParameters(try XCTUnwrap(J(#"{"v":1,"allowEdges":true,"shake":{"v":1,"amount":40}}"#).objectValue))
        XCTAssertEqual(edges.coverScale(width: 1920, height: 1080, canvas: canvas), 1)
        let still = NativeCameraMovesParameters(try XCTUnwrap(J(#"{"v":1,"shake":{"v":1,"amount":0}}"#).objectValue))
        XCTAssertEqual(still.coverScale(width: 1920, height: 1080, canvas: canvas), 1)
    }
}
