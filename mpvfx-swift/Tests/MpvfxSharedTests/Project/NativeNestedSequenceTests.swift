import XCTest
@testable import MpvfxShared

/// Nested sequences (#328): the document fields, their validator issues, and the nest / un-nest / make-unique plans.
final class NativeNestedSequenceTests: XCTestCase {
    let engine = KeyframeEngineStandIn()

    /// Three tracks (two video, one audio) with two clips each, and one unrelated clip after them.
    func threeTrackDocument() throws -> NativeProjectDocument {
        try parseNativeProjectDocument(J("""
        {"schemaVersion":1,"id":"project:demo","revision":0,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":1920,"height":1080,"background":"#101010"},
         "assets":[{"id":"asset:v","kind":"video","name":"v.mov","durationFrames":900},
                   {"id":"asset:a","kind":"audio","name":"a.wav","durationFrames":900}],
         "sequence":{"id":"sequence:main","name":"Main","tracks":[
          {"id":"track:v2","kind":"video","clips":[
            {"id":"clip:v2a","assetId":"asset:v","startFrame":30,"durationFrames":60,"sourceInFrame":5,"effects":[],"parameterTracks":[]},
            {"id":"clip:v2b","assetId":"asset:v","startFrame":120,"durationFrames":30,"sourceInFrame":0,"effects":[],"parameterTracks":[]}]},
          {"id":"track:v1","kind":"video","clips":[
            {"id":"clip:v1a","assetId":"asset:v","startFrame":0,"durationFrames":100,"sourceInFrame":0,"effects":[],"parameterTracks":[]},
            {"id":"clip:v1b","assetId":"asset:v","startFrame":300,"durationFrames":30,"sourceInFrame":0,"effects":[],"parameterTracks":[]}]},
          {"id":"track:a1","kind":"audio","clips":[
            {"id":"clip:a1a","assetId":"asset:a","startFrame":10,"durationFrames":120,"sourceInFrame":0,"effects":[],"parameterTracks":[]}]}]}}
        """), engine: engine)
    }

    func addresses(_ doc: NativeProjectDocument, _ ids: [String]) -> [NativeProjectClipAddress] {
        ids.map { id in
            let t = doc.sequence.tracks.first { $0.clips.contains { $0.id == id } }!
            return .init(sequenceId: doc.sequence.id, trackId: t.id, clipId: id)
        }
    }
    func nest(_ d: NativeProjectDocument, _ ids: [String]) throws -> NativeTimelineNestPlan {
        guard case .success(let plan) = try planNativeTimelineNest(d, .init(clips: addresses(d, ids)), engine: engine) else {
            XCTFail("nest refused"); throw NSError(domain: "nest", code: 1)
        }
        return plan
    }
    func json(_ d: NativeProjectDocument) throws -> String { try serializeNativeProjectDocument(d, engine: engine) }
    func issues(_ d: NativeJSONValue) -> [NativeProjectDocumentValidationIssue] {
        do { _ = try parseNativeProjectDocument(d, engine: engine); XCTFail("accepted"); return [] }
        catch let e as NativeProjectDocumentValidationError { return e.issues }
        catch { XCTFail("wrong error \(error)"); return [] }
    }

    // MARK: A1 model and validator

    func testADocumentWithoutSequencesOpensAndSavesByteIdentical() throws {
        let saved = try json(try threeTrackDocument())
        XCTAssertFalse(saved.contains("\"sequences\""))
        XCTAssertFalse(saved.contains("sequenceId"))
        XCTAssertEqual(try serializeNativeProjectDocument(J(saved), engine: engine), saved)
    }

    func testANestedSequenceRoundTripsWithVersionOne() throws {
        let plan = try nest(try threeTrackDocument(), ["clip:v1a", "clip:a1a"])
        let saved = try json(plan.document)
        let value = J(saved)
        XCTAssertEqual(value["sequences"]?[0]?["v"], .number(1))
        XCTAssertEqual(value["sequences"]?[0]?["fps"]?["numerator"], .number(30))
        XCTAssertEqual(try json(try parseNativeProjectDocument(value, engine: engine)), saved)
    }

    func testASequenceFromANewerVersionIsKeptUnchangedNotDrawnAndNoticed() throws {
        var value = J(try json(try nest(try threeTrackDocument(), ["clip:v1a"]).document))
        let newer = #"{"v":2,"id":"sequence:future","name":"F","layers":[{"x":1}]}"#
        value["sequences"]?.append(J(newer))
        let doc = try parseNativeProjectDocument(value, engine: engine)
        XCTAssertEqual(try NativeJSONValue.from(doc.sequences?[1]), J(newer), "every key kept as written")
        XCTAssertEqual(doc.undrawnContentNotices,
                       ["1 nested sequence from a newer version of the editor is kept in the project but not drawn in preview or export."])
        XCTAssertEqual(J(try json(doc))["sequences"]?[1], J(newer))
    }

    func testValidatorReportsEveryBadSequenceValueAsATypedIssue() throws {
        let base = J(try json(try nest(try threeTrackDocument(), ["clip:v1a"]).document))
        func rejects(_ code: NativeProjectDocumentValidationCode, _ pathSuffix: String, _ edit: (inout NativeJSONValue) -> Void,
                     file: StaticString = #filePath, line: UInt = #line) {
            var d = base; edit(&d)
            let found = issues(d)
            XCTAssertTrue(found.contains { $0.code == code && $0.path.hasSuffix(pathSuffix) }, "\(found)", file: file, line: line)
        }
        rejects(.invalidSequence, "sequences") { $0["sequences"] = .string("x") }
        rejects(.invalidSequence, ".v") { $0["sequences"]?[0]?["v"] = .number(0) }
        rejects(.invalidSequence, ".name") { $0["sequences"]?[0]?["name"] = .string(" ") }
        rejects(.invalidSequence, ".size") { $0["sequences"]?[0]?["size"]?["width"] = .number(-1) }
        rejects(.invalidSequence, ".tracks") { $0["sequences"]?[0]?["tracks"] = .string("x") }
        rejects(.invalidId, "sequences[0].id") { $0["sequences"]?[0]?["id"] = .string("") }
        rejects(.duplicateId, "sequences[1].id") { let first = $0["sequences"]![0]!; $0["sequences"]?.append(first) }
        // Frame rate mismatch (A1).
        rejects(.sequenceFrameRateMismatch, "sequences[0].fps") { $0["sequences"]?[0]?["fps"]?["numerator"] = .number(24) }
        rejects(.invalidFrameRate, "sequences[0].fps") { $0["sequences"]?[0]?["fps"]?["denominator"] = .number(0) }
        // Unknown ids (A1).
        rejects(.missingReference, "sequenceId") {
            $0["sequence"]?["tracks"]?[1]?["clips"]?.append(J(#"{"id":"clip:x","assetId":"asset:nest-1","startFrame":500,"durationFrames":10,"sourceInFrame":0,"effects":[],"parameterTracks":[],"sequenceId":"sequence:ghost"}"#))
        }
        rejects(.invalidClip, "sequenceId") { $0["sequence"]?["tracks"]?[1]?["clips"]?[0]?["sequenceId"] = .number(3) }
        rejects(.invalidClip, "sequenceId") { $0["sequence"]?["tracks"]?[1]?["clips"]?[0]?["assetId"] = .string("asset:v") }
        // Bad content inside a nested sequence is reported at its own path.
        rejects(.invalidClip, "sequences[0].tracks[0].clips[0].durationFrames") { $0["sequences"]?[0]?["tracks"]?[0]?["clips"]?[0]?["durationFrames"] = .number(0) }
        rejects(.missingReference, "sequences[0].tracks[0].clips[0].assetId") { $0["sequences"]?[0]?["tracks"]?[0]?["clips"]?[0]?["assetId"] = .string("asset:none") }
        // A clip id used inside a nest and on the main timeline.
        rejects(.duplicateId, "sequences[0].tracks[0].clips[0].id") { let id = $0["sequence"]?["tracks"]?[0]?["clips"]?[0]?["id"]; $0["sequences"]?[0]?["tracks"]?[0]?["clips"]?[0]?["id"] = id }
    }

    func testCyclesAreRefused() throws {
        let base = J(try json(try nest(try threeTrackDocument(), ["clip:v1a"]).document))
        var selfRef = base
        selfRef["sequences"]?[0]?["tracks"]?[0]?["clips"]?[0]?["sequenceId"] = .string("sequence:nest-1")
        selfRef["sequences"]?[0]?["tracks"]?[0]?["clips"]?[0]?["assetId"] = .string("asset:nest-1")
        XCTAssertTrue(issues(selfRef).contains { $0.code == .sequenceCycle && $0.path == "sequences[0]" })

        // Two sequences that contain each other.
        var pair = base
        var second = base["sequences"]![0]!
        second["id"] = .string("sequence:other")
        second["tracks"]?[0]?["id"] = .string("track:other")
        second["tracks"]?[0]?["clips"]?[0]?["id"] = .string("clip:other-inner")
        second["tracks"]?[0]?["clips"]?[0]?["sequenceId"] = .string("sequence:nest-1")
        second["tracks"]?[0]?["clips"]?[0]?["assetId"] = .string("asset:nest-1")
        pair["sequences"]?.append(second)
        pair["sequences"]?[0]?["tracks"]?[0]?["clips"]?[0]?["sequenceId"] = .string("sequence:other")
        pair["sequences"]?[0]?["tracks"]?[0]?["clips"]?[0]?["assetId"] = .string("asset:nest-1")
        let cycles = issues(pair).filter { $0.code == .sequenceCycle }
        XCTAssertEqual(cycles.map(\.path).sorted(), ["sequences[0]", "sequences[1]"])
    }

    // MARK: A2 nest then un-nest

    func testNestThenUnnestOfAThreeTrackSelectionRestoresTheDocumentExactly() throws {
        let original = try threeTrackDocument()
        let plan = try nest(original, ["clip:v2a", "clip:v1a", "clip:a1a"])
        let nested = plan.document
        XCTAssertEqual(nested.sequences?.count, 1)
        XCTAssertEqual(nested.sequences?[0].tracks.map(\.id), ["track:v2", "track:v1", "track:a1"])
        // The nested clip takes the span of the selection (frames 0 to 130) on the lowest selected video track.
        let lowest = nested.sequence.tracks.first { $0.id == "track:v1" }!
        let clip = lowest.clips.first { $0.id == plan.nestedClipId }!
        XCTAssertEqual(clip.sequenceId, plan.sequenceId)
        XCTAssertEqual([clip.startFrame, clip.durationFrames], [0, 130])
        XCTAssertEqual(nested.sequences?[0].tracks[0].clips[0].startFrame, 30, "inside, timing is relative to the earliest clip")
        XCTAssertFalse(nested.sequence.tracks.flatMap(\.clips).contains { $0.id == "clip:v1a" })
        XCTAssertNotEqual(try json(nested), try json(original))

        let address = NativeProjectClipAddress(sequenceId: "sequence:main", trackId: "track:v1", clipId: plan.nestedClipId)
        guard case .success(let back) = try planNativeTimelineUnnest(nested, .init(address: address), engine: engine) else {
            return XCTFail("un-nest refused")
        }
        XCTAssertEqual(try json(back.document), try json(original), "compared as saved JSON")
        XCTAssertEqual(back.document, original)
        XCTAssertEqual(back.restoredClipIds.sorted(), ["clip:a1a", "clip:v1a", "clip:v2a"])
    }

    func testNestCarriesTransitionsBetweenSelectedClipsAndRestoresThem() throws {
        var original = try threeTrackDocument()
        original.sequence.tracks[1].clips[0].durationFrames = 150
        original.sequence.tracks[1].clips[1].startFrame = 150
        original.sequence.tracks[1].transitions = [NativeCutTransition(id: "transition:1", cut: (from: "clip:v1a", to: "clip:v1b"), kind: .dip, durationFrames: 10)]
        original = try parseNativeProjectDocument(original, engine: engine)
        let plan = try nest(original, ["clip:v1a", "clip:v1b"])
        XCTAssertNil(plan.document.sequence.tracks[1].transitions)
        XCTAssertEqual(plan.document.sequences?[0].tracks[0].transitions?.count, 1)
        let address = NativeProjectClipAddress(sequenceId: "sequence:main", trackId: "track:v1", clipId: plan.nestedClipId)
        guard case .success(let back) = try planNativeTimelineUnnest(plan.document, .init(address: address), engine: engine) else {
            return XCTFail("un-nest refused")
        }
        XCTAssertEqual(try json(back.document), try json(original))
    }

    func testNestRefusesWhatItCannotMakeExact() throws {
        let d = try threeTrackDocument()
        func code(_ r: NativeTimelineNestPlanResult) -> NativeTimelineNestFailureCode? { if case .failure(let f) = r { return f.code }; return nil }
        XCTAssertEqual(code(try planNativeTimelineNest(d, .init(clips: []), engine: engine)), .emptySelection)
        XCTAssertEqual(code(try planNativeTimelineNest(d, .init(clips: addresses(d, ["clip:a1a"])), engine: engine)), .noVideoTrack)
        XCTAssertEqual(code(try planNativeTimelineNest(d, .init(clips: addresses(d, ["clip:v1a", "clip:v1a"])), engine: engine)), .duplicateClip)
        XCTAssertEqual(code(try planNativeTimelineNest(d, .init(clips: [.init(sequenceId: "sequence:main", trackId: "track:v1", clipId: "clip:none")]), engine: engine)), .clipNotFound)
        // An unselected clip between two selected ones on the target track.
        XCTAssertEqual(code(try planNativeTimelineNest(d, .init(clips: addresses(d, ["clip:v1a", "clip:v1b"])), engine: engine)), nil,
                       "the gap between them is empty, so this nests")
        var busy = d
        busy.sequence.tracks[1].clips.insert(NativeProjectClip.fresh(id: "clip:mid", assetId: "asset:v", startFrame: 150, durationFrames: 20), at: 1)
        XCTAssertEqual(code(try planNativeTimelineNest(busy, .init(clips: addresses(busy, ["clip:v1a", "clip:v1b"])), engine: engine)), .overlapsClip)
        var locked = d
        locked.sequence.tracks[1].locked = true
        XCTAssertEqual(code(try planNativeTimelineNest(locked, .init(clips: addresses(locked, ["clip:v1a"])), engine: engine)), .lockedTrack)
        var joined = d
        joined.sequence.tracks[1].clips[0].durationFrames = 150
        joined.sequence.tracks[1].clips[1].startFrame = 150
        joined.sequence.tracks[1].transitions = [NativeCutTransition(id: "transition:1", cut: (from: "clip:v1a", to: "clip:v1b"), kind: .dip, durationFrames: 10)]
        XCTAssertEqual(code(try planNativeTimelineNest(joined, .init(clips: addresses(joined, ["clip:v1a"])), engine: engine)), .transitionCrossesSelection)
    }

    func testUnnestRefusesALookOnTheNestedClipUnlessDropped() throws {
        let original = try threeTrackDocument()
        var plan = try nest(original, ["clip:v1a", "clip:v2a"]).document
        let id = plan.sequence.tracks[1].clips.first { $0.sequenceId != nil }!.id
        plan.sequence.tracks[1].clips[plan.sequence.tracks[1].clips.firstIndex { $0.id == id }!].fadeInFrames = 5
        let address = NativeProjectClipAddress(sequenceId: "sequence:main", trackId: "track:v1", clipId: id)
        guard case .failure(let refused) = try planNativeTimelineUnnest(plan, .init(address: address), engine: engine) else {
            return XCTFail("accepted a nested clip with a fade")
        }
        XCTAssertEqual(refused.code, .outerLookNotExpressible)
        XCTAssertTrue(refused.message.contains("fades"))
        guard case .success(let dropped) = try planNativeTimelineUnnest(plan, .init(address: address, outerLook: .drop), engine: engine) else {
            return XCTFail("drop refused")
        }
        XCTAssertEqual(dropped.droppedLook, ["fades"])
        XCTAssertEqual(try json(dropped.document), try json(original))
    }

    func testMovingTheNestedClipMovesTheRestoredClipsWithIt() throws {
        let original = try threeTrackDocument()
        var plan = try nest(original, ["clip:v2a", "clip:v1a"])
        let t = 1, c = plan.document.sequence.tracks[t].clips.firstIndex { $0.id == plan.nestedClipId }!
        plan.document.sequence.tracks[t].clips[c].startFrame = 200
        let address = NativeProjectClipAddress(sequenceId: "sequence:main", trackId: "track:v1", clipId: plan.nestedClipId)
        guard case .success(let back) = try planNativeTimelineUnnest(plan.document, .init(address: address), engine: engine) else {
            return XCTFail("un-nest refused")
        }
        XCTAssertEqual(back.document.sequence.tracks[0].clips.first { $0.id == "clip:v2a" }?.startFrame, 230)
        XCTAssertEqual(back.document.sequence.tracks[1].clips.first { $0.id == "clip:v1a" }?.startFrame, 200)
        plan.document.sequence.tracks[t].clips[c].durationFrames = 40
        guard case .failure(let f) = try planNativeTimelineUnnest(plan.document, .init(address: address), engine: engine) else {
            return XCTFail("accepted a trimmed nested clip")
        }
        XCTAssertEqual(f.code, .trimmedOrRetimed)
    }

    // MARK: A3 sharing and Make unique

    func sharedDocument() throws -> (NativeProjectDocument, String) {
        let plan = try nest(try threeTrackDocument(), ["clip:v1a", "clip:v2a"])
        var d = plan.document
        var copy = d.sequence.tracks[1].clips.first { $0.id == plan.nestedClipId }!
        copy.id = "clip:nest-copy"; copy.startFrame = 400
        d.sequence.tracks[1].clips.append(copy)
        return (try parseNativeProjectDocument(d, engine: engine), plan.sequenceId)
    }

    func testTwoClipsShareOneSequenceAndMakeUniqueDuplicatesIt() throws {
        let (shared, sequenceId) = try sharedDocument()
        XCTAssertEqual(shared.sequences?.count, 1, "one sequence is stored once")
        XCTAssertEqual(shared.nestedClipCount(sequenceId: sequenceId), 2)
        let address = NativeProjectClipAddress(sequenceId: "sequence:main", trackId: "track:v1", clipId: "clip:nest-copy")
        guard case .success(let unique) = try planNativeTimelineMakeUnique(shared, address: address, engine: engine) else {
            return XCTFail("make unique refused")
        }
        let d = unique.document
        XCTAssertEqual(d.sequences?.count, 2)
        XCTAssertNotEqual(unique.sequenceId, sequenceId)
        XCTAssertEqual(d.sequence.tracks[1].clips.first { $0.id == "clip:nest-copy" }?.sequenceId, unique.sequenceId)
        XCTAssertEqual(d.sequence.tracks[1].clips.first { $0.sequenceId == sequenceId }?.id, "clip:nest-1")
        let copy = d.nestedSequence(id: unique.sequenceId)!, original = d.nestedSequence(id: sequenceId)!
        XCTAssertEqual(copy.tracks.count, original.tracks.count)
        XCTAssertEqual(copy.tracks[0].clips.map(\.startFrame), original.tracks[0].clips.map(\.startFrame))
        XCTAssertTrue(Set(copy.tracks.flatMap(\.clips).map(\.id)).isDisjoint(with: original.tracks.flatMap(\.clips).map(\.id)), "inner clip ids stay unique")
        XCTAssertEqual(d.nestedClipCount(sequenceId: unique.sequenceId), 1)
        // The copy is its own: editing it leaves the shared one alone.
        guard case .failure(let again) = try planNativeTimelineMakeUnique(d, address: address, engine: engine) else {
            return XCTFail("a unique clip was duplicated again")
        }
        XCTAssertEqual(again.code, .alreadyUnique)
    }

    func testUnnestingOneOfTwoSharingClipsKeepsTheSequenceForTheOther() throws {
        let (shared, sequenceId) = try sharedDocument()
        let address = NativeProjectClipAddress(sequenceId: "sequence:main", trackId: "track:v1", clipId: "clip:nest-copy")
        guard case .success(let back) = try planNativeTimelineUnnest(shared, .init(address: address), engine: engine) else {
            return XCTFail("un-nest refused")
        }
        XCTAssertNotNil(back.document.nestedSequence(id: sequenceId))
        XCTAssertEqual(back.document.nestedClipCount(sequenceId: sequenceId), 1)
        XCTAssertFalse(back.restoredClipIds.contains("clip:v1a"), "ids stay unique while the sequence is shared")
        XCTAssertEqual(back.restoredClipIds.count, 2)
        XCTAssertTrue(back.document.assets.contains { $0.id == "asset:nest-1" })
    }
}
