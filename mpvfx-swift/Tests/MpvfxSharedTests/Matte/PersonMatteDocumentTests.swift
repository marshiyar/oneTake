import XCTest
@testable import MpvfxShared

/// A1: the person-matte effect entry in `clip.effects`: absent stays absent byte for byte, `"v": 1` round trips with
/// default fields omitted, another version is kept unchanged and noticed, and every bad value is a typed issue.
final class PersonMatteDocumentTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func parse(_ d: NativeJSONValue) throws -> NativeProjectDocument { try parseNativeProjectDocument(d, engine: engine) }
    func serialize(_ d: NativeJSONValue) throws -> String { try serializeNativeProjectDocument(d, engine: engine) }
    func withMatte(_ parameters: String?, enabled: Bool = true) -> NativeJSONValue {
        var d = validNativeDocument()
        let p = parameters.map { #","parameters":\#($0)"# } ?? ""
        d["sequence"]?["tracks"]?[0]?["clips"]?[0]?["effects"] =
            J(#"[{"id":"effect:matte","effectId":"person-matte","enabled":\#(enabled)\#(p)}]"#)
        return d
    }
    func issues(_ d: NativeJSONValue, file: StaticString = #filePath, line: UInt = #line) -> [NativeProjectDocumentValidationIssue] {
        do { _ = try parse(d); XCTFail("accepted", file: file, line: line); return [] }
        catch let e as NativeProjectDocumentValidationError { return e.issues }
        catch { XCTFail("wrong error \(error)", file: file, line: line); return [] }
    }
    func rejects(_ parameters: String?, _ path: String, file: StaticString = #filePath, line: UInt = #line) {
        let found = issues(withMatte(parameters), file: file, line: line)
        XCTAssertTrue(found.contains { $0.code == .invalidEffect && $0.path.hasSuffix(path) }, "\(found)", file: file, line: line)
    }

    func testADocumentWithoutTheEffectOpensAndSavesByteIdentical() throws {
        let saved = try serialize(validNativeDocument())
        XCTAssertFalse(saved.contains("person-matte"))
        XCTAssertEqual(try serialize(J(saved)), saved)
        XCTAssertEqual(try parse(J(saved)).schemaVersion, 1)
    }

    func testAVersionOneEntryRoundTripsAndDefaultsAreOmitted() throws {
        let saved = try serialize(withMatte(#"{"v":1,"quality":"balanced"}"#))
        XCTAssertFalse(saved.contains("shrink") || saved.contains("soften") || saved.contains("invert"), saved)
        let clip = try parse(J(saved)).sequence.tracks[0].clips[0]
        let active = try XCTUnwrap(PersonMatteEffect.active(clip))
        XCTAssertEqual(active.parameters, PersonMatteEffect.Parameters(quality: "balanced"))
        XCTAssertEqual(try serialize(J(saved)), saved)

        let full = PersonMatteEffect.Parameters(quality: "accurate", shrink: -3.5, soften: 12, invert: true)
        let effect = PersonMatteEffect.effect(id: "effect:matte", parameters: full)
        var doc = try parse(validNativeDocument())
        doc.sequence.tracks[0].clips[0].effects = [effect]
        let again = try parse(J(try serializeNativeProjectDocument(doc, engine: engine)))
        XCTAssertEqual(PersonMatteEffect.active(again.sequence.tracks[0].clips[0])?.parameters, full)
    }

    func testAnEntryFromANewerVersionIsKeptUnchangedNotDrawnAndNoticedOnce() throws {
        let parameters = #"{"v":2,"quality":"ultra","people":[1,2]}"#
        let doc = try parse(withMatte(parameters))
        let clip = doc.sequence.tracks[0].clips[0]
        XCTAssertEqual(clip.effects.count, 1)
        XCTAssertNil(PersonMatteEffect.active(clip), "not drawn")
        XCTAssertEqual(clip.effects[0].parameters.map { NativeJSONValue.object($0) }, J(parameters), "kept as written")
        XCTAssertEqual(doc.undrawnContentNotices.filter { $0.contains("person-matte") }.count, 1)
        let saved = try serialize(withMatte(parameters))
        XCTAssertTrue(saved.contains(#""people""#), "the unknown keys survive a save")
        XCTAssertTrue(try parse(validNativeDocument()).undrawnContentNotices.isEmpty)
    }

    func testEveryBadValueIsATypedIssue() {
        rejects(nil, "parameters")
        rejects(#"{"quality":"balanced"}"#, "parameters.v")
        rejects(#"{"v":"1","quality":"balanced"}"#, "parameters.v")
        rejects(#"{"v":1}"#, "parameters.quality")
        rejects(#"{"v":1,"quality":"best"}"#, "parameters.quality")
        rejects(#"{"v":1,"quality":"fast","shrink":10.5}"#, "parameters.shrink")
        rejects(#"{"v":1,"quality":"fast","shrink":-11}"#, "parameters.shrink")
        rejects(#"{"v":1,"quality":"fast","shrink":"4"}"#, "parameters.shrink")
        rejects(#"{"v":1,"quality":"fast","soften":-1}"#, "parameters.soften")
        rejects(#"{"v":1,"quality":"fast","soften":21}"#, "parameters.soften")
        rejects(#"{"v":1,"quality":"fast","invert":1}"#, "parameters.invert")
    }

    func testBoundaryValuesAreAccepted() throws {
        for p in [#"{"v":1,"quality":"fast","shrink":-10,"soften":0}"#, #"{"v":1,"quality":"accurate","shrink":10,"soften":20,"invert":false}"#] {
            XCTAssertNotNil(try? parse(withMatte(p)), p)
        }
    }

    func testTheCacheFileCodecRoundTripsAndRejectsDamage() throws {
        let key = PersonMatteCacheKey(digest: "abc", sourceStartMs: 0, sourceDurationMs: 200, quality: "balanced", width: 8, height: 4)
        let frames: [[UInt8]] = [[UInt8](repeating: 0, count: 32), (0..<32).map { UInt8($0 * 8) }]
        let header = PersonMatteCacheHeader(v: 1, codec: PersonMatteCodec.codecName, frames: 2, width: 8, height: 4, fps: 10, key: key.name,
                                            digest: "abc", sourceStartMs: 0, sourceDurationMs: 200, quality: "balanced")
        let data = try PersonMatteCodec.encode(header: header, frames: frames)
        let index = try PersonMatteCodec.index(of: data, path: "t", expectedKey: key)
        XCTAssertEqual(index.ranges.count, 2)
        XCTAssertEqual(PersonMatteCodec.rleDecode(data.subdata(in: index.ranges[1]), count: 32), frames[1])
        XCTAssertThrowsError(try PersonMatteCodec.index(of: data.prefix(data.count - 3), path: "t", expectedKey: key))
        var wrong = key; wrong.quality = "fast"
        XCTAssertThrowsError(try PersonMatteCodec.index(of: data, path: "t", expectedKey: wrong))
        var versioned = header; versioned.v = 2
        XCTAssertThrowsError(try PersonMatteCodec.index(of: try PersonMatteCodec.encode(header: versioned, frames: frames), path: "t", expectedKey: key))
        XCTAssertEqual(PersonMatteEffect.analysisSize(aspect: 16.0 / 9).width, 512)
        XCTAssertEqual(PersonMatteEffect.analysisSize(aspect: 16.0 / 9).height, 288)
        XCTAssertEqual(PersonMatteEffect.analysisSize(aspect: 9.0 / 16).height, 512)
    }
}
