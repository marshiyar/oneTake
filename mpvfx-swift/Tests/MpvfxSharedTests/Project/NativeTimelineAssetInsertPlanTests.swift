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
// Asset insert plans.
import XCTest
@testable import MpvfxShared

final class NativeTimelineAssetInsertPlanTests: XCTestCase {
    let engine = KeyframeEngineStandIn()
    func project() throws -> NativeProjectDocument {
        try parseNativeProjectDocument(J(##"""
        {"schemaVersion":1,"id":"project:insert","revision":4,"frameRate":{"numerator":30000,"denominator":1001},"canvas":{"width":1920,"height":1080,"background":"#000"},
         "assets":[{"id":"asset:existing","kind":"video","name":"existing.mov","durationFrames":900}],
         "sequence":{"id":"sequence:main","name":"Main","tracks":[{"id":"track:existing","kind":"video","lane":{"authoredTrack":0,"displayTrack":0},"clips":[
          {"id":"clip:existing","assetId":"asset:existing","binding":{"sourceFile":"index.html","domId":"existing","hfId":"hf-existing"},"startFrame":0,"durationFrames":60,
           "sourceInFrame":12,"playbackRate":{"numerator":2,"denominator":1},"muted":true,"staticParameters":{"visual.opacity":0.4},"effects":[{"id":"fx:1","effectId":"blur","enabled":true}],"parameterTracks":[]}]}]}}
        """##), engine: engine)
    }
    func insertion(_ f: (inout NativeTimelineAssetInsertion) -> Void = { _ in }) -> NativeTimelineAssetInsertion {
        var i = NativeTimelineAssetInsertion(assetPath: "media/new.mov", kind: .video, sourceFile: "index.html",
            binding: .init(sourceFile: "index.html", domId: "new", hfId: "hf-new"), requestedStartSeconds: (90.0 * 1001) / 30000,
            requestedDurationSeconds: (120.0 * 1001) / 30000, sourceDurationSeconds: (300.0 * 1001) / 30000, requestedTrack: 0)
        f(&i); return i
    }
    func dom(_ id: String, file: String = "index.html") -> NativeClipDomBinding { .init(sourceFile: file, domId: id) }
    func plan(_ d: NativeProjectDocument, _ i: [NativeTimelineAssetInsertion]) throws -> NativeTimelineAssetInsertPlanResult {
        try planNativeTimelineAssetInsertions(d, insertions: i, engine: engine)
    }

    func testQuantizesFractionalRate() throws {
        let r = try quantizeNativeTimelineAssetInsertion(try project(), insertion { $0.requestedStartSeconds = 3.003; $0.requestedDurationSeconds = 2.002; $0.sourceDurationSeconds = 10.01 })
        XCTAssertEqual(r.value, .init(startFrame: 90, durationFrames: 60, sourceDurationFrames: 300, compatibilityStartSeconds: 3.003, compatibilityDurationSeconds: 2.002))
    }

    func testAddsVideoAudioImageWithDefaults() throws {
        let r = try plan(try project(), [insertion(),
            insertion { $0.assetPath = "media/voice.wav"; $0.kind = .audio; $0.binding = self.dom("voice"); $0.requestedTrack = 2 },
            insertion { $0.assetPath = "media/poster.png"; $0.kind = .image; $0.binding = self.dom("poster"); $0.requestedTrack = 4 }]).value!
        XCTAssertEqual(r.insertions.map(\.assetId), ["native-asset:video:13:media/new.mov", "native-asset:audio:15:media/voice.wav", "native-asset:image:16:media/poster.png"])
        let added = r.document.sequence.tracks.flatMap(\.clips).filter { $0.id != "clip:existing" }
        XCTAssertEqual(added.count, 3)
        XCTAssertTrue(added.contains { $0.sourceInFrame == 0 && $0.playbackRate == .init(numerator: 1, denominator: 1) && !$0.muted
            && $0.staticParameters == [:] && $0.effects.isEmpty && $0.parameterTracks.isEmpty })
        XCTAssertEqual(r.document.sequence.tracks.map(\.kind), [.video, .audio, .video])
        XCTAssertEqual(r.document.sequence.tracks.map(\.lane), [.init(authoredTrack: 0, displayTrack: 0), .init(authoredTrack: 2, displayTrack: 2), .init(authoredTrack: 4, displayTrack: 4)])
    }

    func testReusesLaneAndCreatesDeterministicSparseTracks() throws {
        let sparse = insertion { $0.assetPath = "media/sparse.mov"; $0.binding = self.dom("sparse"); $0.requestedTrack = 8 }
        let first = try plan(try project(), [insertion(), sparse]).value!, reversed = try plan(try project(), [sparse, insertion()]).value!
        XCTAssertEqual(first.document, reversed.document)
        XCTAssertEqual(first.document.sequence.tracks.first { $0.lane?.authoredTrack == 8 }?.id, "native-track:8:video")
        XCTAssertEqual(first.document.sequence.tracks.filter { $0.lane?.authoredTrack == 0 }.count, 1)
    }

    func testReusesOneAssetAndGrowsSourceDuration() throws {
        let r = try plan(try project(), [insertion(), insertion { $0.binding = self.dom("new-2"); $0.requestedStartSeconds = 8; $0.sourceDurationSeconds = 20 }]).value!
        let assets = r.document.assets.filter { $0.name == "new.mov" }
        XCTAssertEqual(assets.count, 1); XCTAssertEqual(assets.first?.durationFrames, 599)
    }

    func testReusesPersistedAssetAcrossAliases() throws {
        for source in ["media/new.mov", "mpvfx://editor/api/projects/project%3Ainsert/preview/media/new.mov?revision=1"] {
            var before = try project(); before.assets[0].source = source
            let r = try plan(before, [insertion { $0.assetPath = "./media//new.mov" },
                insertion { $0.assetPath = "mpvfx://editor/api/projects/project%3Ainsert/preview/media/new.mov?revision=7"; $0.binding = self.dom("second") }]).value!
            XCTAssertEqual(r.document.assets, before.assets, source)
            XCTAssertEqual(r.insertions.map(\.assetId), ["asset:existing", "asset:existing"])
            XCTAssertEqual(r.document.sequence.tracks[0].clips.map(\.assetId), ["asset:existing", "asset:existing", "asset:existing"])
        }
    }

    func testOnePortableAssetForSameBatchAliases() throws {
        let r = try plan(try project(), [insertion { $0.assetPath = "mpvfx://editor/api/projects/project%3Ainsert/preview/media/new%20clip.mov?revision=7" },
                                         insertion { $0.assetPath = "./media/new clip.mov"; $0.binding = self.dom("second") }]).value!
        let added = Array(r.document.assets.dropFirst())
        XCTAssertEqual(added.count, 1); XCTAssertEqual(added[0].source, "media/new clip.mov"); XCTAssertEqual(added[0].name, "new clip.mov")
        XCTAssertEqual(r.insertions[0].assetId, r.insertions[1].assetId)
    }

    func testKeepsDistinctDirectoriesAndLiteralCharacters() throws {
        let paths = ["media/new.mov", "other/new.mov", "media/new%20file.mov", "media/new file.mov"]
        let r = try plan(try project(), paths.enumerated().map { i, p in insertion { $0.assetPath = p; $0.binding = self.dom("new-\(i)") } }).value!
        XCTAssertEqual(Set(r.insertions.map(\.assetId)).count, paths.count)
        XCTAssertEqual(r.document.assets.dropFirst().compactMap(\.source).sorted(by: jsCodeUnitLess), paths.sorted(by: jsCodeUnitLess))
    }

    func testRejectsTwoAssetsClaimingSameSource() throws {
        var before = try project(); before.assets[0].source = "media/new.mov"
        var dup = before.assets[0]; dup.id = "asset:duplicate"; dup.source = "./media/new.mov"; before.assets.append(dup)
        let snapshot = before
        XCTAssertEqual(try plan(before, [insertion()]).error?.code, .identityCollision); XCTAssertEqual(before, snapshot)
    }

    func testRejectsOccupiedGeneratedIdWithoutMatchingSource() throws {
        for source in ["media/different.mov", nil] as [String?] {
            var before = try project()
            before.assets.append(.init(id: "native-asset:video:13:media/new.mov", kind: .video, name: "new.mov", source: source, durationFrames: 900))
            XCTAssertEqual(try plan(before, [insertion()]).error?.code, .identityCollision)
        }
    }

    func testRejectsSourceOutsideProject() throws {
        for p in ["../outside.mov", "https://example.com/new.mov", "mpvfx://editor/api/projects/another/preview/new.mov"] {
            XCTAssertEqual(try plan(try project(), [insertion { $0.assetPath = p }]).error?.code, .invalidAssetPath, p)
        }
    }

    func testPreservesExistingState() throws {
        let before = try project()
        let r = try plan(before, [insertion()]).value!
        XCTAssertEqual(r.document.assets[0], before.assets[0])
        XCTAssertEqual(r.document.sequence.tracks[0].clips.first { $0.id == "clip:existing" }, before.sequence.tracks[0].clips[0])
        XCTAssertEqual(r.document.revision, before.revision)
    }

    func testRejectsInvalidInputsWithoutMutating() throws {
        let cases: [([NativeTimelineAssetInsertion], NativeTimelineAssetInsertPlanFailureCode)] = [
            ([], .emptyInsertionSet), ([insertion { $0.requestedStartSeconds = -1 }], .invalidTime),
            ([insertion { $0.requestedDurationSeconds = 0.001 }], .invalidDuration), ([insertion { $0.sourceDurationSeconds = 1 }], .sourceOutOfBounds),
            ([insertion { $0.requestedTrack = 1.5 }], .invalidTrack), ([insertion { $0.binding = .init(sourceFile: "index.html") }], .invalidBinding),
            ([insertion { $0.binding = self.dom("new", file: "other.html") }], .bindingSourceMismatch),
            ([insertion { $0.binding = self.dom("existing") }], .bindingCollision), ([insertion(), insertion()], .bindingCollision),
            // Other kinds are not media kinds; `.element` exercises the runtime guard.
            ([insertion { $0.kind = .element }], .unsupportedKind)]
        for (ins, code) in cases {
            let before = try project()
            XCTAssertEqual(try plan(before, ins).error?.code, code); XCTAssertEqual(before, try project())
        }
    }

    func testInsertsAudioOntoExistingVideoTrack() throws {
        let r = try plan(try project(), [insertion { $0.assetPath = "media/voice.wav"; $0.kind = .audio; $0.binding = self.dom("voice"); $0.requestedTrack = 0 }]).value!
        XCTAssertEqual(r.document.sequence.tracks.count, 1)
        let t = r.document.sequence.tracks[0]
        XCTAssertEqual(t.id, "track:existing"); XCTAssertEqual(t.kind, .mixed); XCTAssertEqual(t.lane, .init(authoredTrack: 0, displayTrack: 0)); XCTAssertEqual(t.clips.count, 2)
    }

    func testInsertsVideoAndAudioIntoOneNewRow() throws {
        let r = try plan(try project(), [insertion { $0.requestedTrack = 8; $0.binding = self.dom("new-video") },
            insertion { $0.requestedTrack = 8; $0.kind = .audio; $0.assetPath = "voice.wav"; $0.binding = self.dom("new-audio") }]).value!
        let tracks = r.document.sequence.tracks.filter { $0.lane?.authoredTrack == 8 }
        XCTAssertEqual(tracks.count, 1); XCTAssertEqual(tracks[0].kind, .mixed); XCTAssertEqual(tracks[0].clips.count, 2)
    }

    func testRejectsDeterministicTrackCollision() throws {
        var base = try project()
        base.sequence.tracks.append(.init(id: "native-track:8:video", kind: .video, lane: .init(authoredTrack: 7, displayTrack: 7), clips: []))
        let colliding = try parseNativeProjectDocument(base, engine: engine)
        XCTAssertEqual(try plan(colliding, [insertion { $0.requestedTrack = 8 }]).error?.code, .identityCollision)
    }
}
