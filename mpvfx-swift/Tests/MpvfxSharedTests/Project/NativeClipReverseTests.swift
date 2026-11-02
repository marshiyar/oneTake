import XCTest
@testable import MpvfxShared

/// `clip.reversed` and `clip.reverseAudio` in the document (#294): absent stays absent byte for byte, set values
/// round trip, and every bad value is a typed issue.
final class NativeClipReverseTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func parse(_ d: NativeJSONValue) throws -> NativeProjectDocument { try parseNativeProjectDocument(d, engine: engine) }
    func serialize(_ d: NativeJSONValue) throws -> String { try serializeNativeProjectDocument(d, engine: engine) }
    func with(_ fields: [String: NativeJSONValue]) -> NativeJSONValue {
        var d = validNativeDocument()
        for (k, v) in fields { d["sequence"]?["tracks"]?[0]?["clips"]?[0]?[k] = v }
        return d
    }
    func rejects(_ d: NativeJSONValue, _ path: String, file: StaticString = #filePath, line: UInt = #line) {
        do { _ = try parse(d); XCTFail("accepted", file: file, line: line) }
        catch let e as NativeProjectDocumentValidationError {
            XCTAssertTrue(e.issues.contains { $0.code == .invalidClip && $0.path.hasSuffix(path) }, "\(e.issues)", file: file, line: line)
        } catch { XCTFail("wrong error \(error)", file: file, line: line) }
    }

    func testADocumentWithoutReversedClipsOpensAndSavesByteIdentical() throws {
        let saved = try serialize(validNativeDocument())
        XCTAssertFalse(saved.contains("reversed")); XCTAssertFalse(saved.contains("reverseAudio"))
        XCTAssertEqual(try serialize(J(saved)), saved, "open and save again: the same bytes")
        XCTAssertEqual(try parse(J(saved)).schemaVersion, 1)
        let clip = try parse(J(saved)).sequence.tracks[0].clips[0]
        XCTAssertNil(clip.reversed); XCTAssertNil(clip.reverseAudio)
        XCTAssertFalse(clip.playsBackwards); XCTAssertTrue(clip.reversesAudio)
    }

    func testReversedAndMutedReverseAudioRoundTrip() throws {
        let saved = try serialize(with(["reversed": J("true"), "reverseAudio": J("false")]))
        let clip = try parse(J(saved)).sequence.tracks[0].clips[0]
        XCTAssertEqual(clip.reversed, true); XCTAssertEqual(clip.reverseAudio, false)
        XCTAssertTrue(clip.playsBackwards); XCTAssertFalse(clip.reversesAudio)
        XCTAssertEqual(try serialize(J(saved)), saved)
        let plain = try serialize(with(["reversed": J("true")]))
        XCTAssertFalse(plain.contains("reverseAudio"), "the default sound choice is not written")
    }

    func testBadValuesAreTypedIssues() {
        rejects(with(["reversed": J(#""yes""#)]), "reversed")
        rejects(with(["reversed": J("1")]), "reversed")
        rejects(with(["reversed": J("true"), "reverseAudio": J(#""no""#)]), "reverseAudio")
        rejects(with(["reverseAudio": J("false")]), "reverseAudio")
        rejects(with(["reversed": J("false"), "reverseAudio": J("false")]), "reverseAudio")
    }

    func testFrameMappingMirrorsTheClip() {
        // frame k of a reversed clip of n frames at rate 1 shows source offset n - 1 - k (in + out - 1 - k)
        for k in 0..<10 {
            XCTAssertEqual(NativeProjectClip.sourceOffset(frame: Double(k), durationFrames: 10, rate: 1, reversed: true), Double(9 - k))
            XCTAssertEqual(NativeProjectClip.sourceOffset(frame: Double(k), durationFrames: 10, rate: 1, reversed: false), Double(k))
        }
        XCTAssertEqual(NativeProjectClip.sourceOffset(frame: 0, durationFrames: 10, rate: 2, reversed: true), 18)
    }
}
