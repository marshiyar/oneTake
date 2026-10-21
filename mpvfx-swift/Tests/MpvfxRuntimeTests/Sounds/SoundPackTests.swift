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
// Sound packs: the reader and validator (one typed issue per rule, a bad item hides only itself, a newer pack is only
// listed), the durable install, and the catalogue's search. Every pack is written by our own code in a temp folder;
// the shipped placeholder pack is read from `sounds/`.
import Foundation
import XCTest
import MpvfxShared
@testable import MpvfxRuntime

/// A pack folder built on disk, item by item, so each test breaks exactly one thing.
final class PackFixture {
    let folder: String
    var items: [[String: Any]] = []
    var header: [String: Any] = [
        "v": 1, "id": "fixture", "name": "Fixture pack", "version": "1.0.0",
        "licence": ["id": "test", "title": "Test licence", "file": "LICENCE.txt", "summary": "For tests."],
    ]

    init(parent: String, name: String = "fixture") throws {
        folder = parent + "/\(name).mpvfxsounds"
        try FileManager.default.createDirectory(atPath: folder + "/audio", withIntermediateDirectories: true)
        try Data("licence text".utf8).write(to: URL(fileURLWithPath: folder + "/LICENCE.txt"))
    }

    /// Writes a tone and returns the item dictionary describing it.
    @discardableResult
    func addTone(_ id: String, seconds: Double = 0.5, kind: String = "effect", moods: [String] = [], tags: [String] = [],
                 file: String? = nil) throws -> [String: Any] {
        let rate = 22_050
        let data = TestMedia.wav(TestMedia.tone(seconds: seconds, rate: rate), rate: rate, channels: 1)
        let relative = file ?? "audio/\(id).wav"
        try data.write(to: URL(fileURLWithPath: folder + "/" + relative))
        let item: [String: Any] = ["id": id, "title": "Title \(id)", "kind": kind, "moods": moods, "tags": tags, "file": relative,
                                   "sha256": sha256Hex(data), "durationMs": Int((seconds * 1000).rounded()), "sampleRate": rate, "channels": 1]
        items.append(item)
        return item
    }

    func write() throws {
        var document = header
        document["items"] = items
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: folder + "/pack.json"))
    }
}

final class SoundPackTests: XCTestCase {
    var root = ""
    override func setUpWithError() throws { root = try makeMediaTempDir("mpvfx-sound-packs-") }
    override func tearDown() { try? FileManager.default.removeItem(atPath: root); super.tearDown() }

    static var shippedSounds: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("sounds").path
    }

    func pack(_ build: (PackFixture) throws -> Void) throws -> SoundPackReport {
        let fixture = try PackFixture(parent: root)
        try build(fixture)
        try fixture.write()
        return SoundPackReader.read(folder: fixture.folder)
    }

    func codes(_ report: SoundPackReport) -> [SoundPackIssue.Code] { report.issues.map(\.code) }

    // MARK: A1 the placeholder pack

    func testA1ThePlaceholderPackValidatesWithNoIssue() {
        let report = SoundPackReader.read(folder: Self.shippedSounds + "/placeholder.mpvfxsounds")
        XCTAssertEqual(report.issues, [])
        XCTAssertEqual(report.state, .ready)
        XCTAssertEqual(report.items.count, 8)
        XCTAssertEqual(report.licence?.id, "placeholder-owned")
        XCTAssertTrue(report.items.allSatisfy { $0.durationMs < 10_000 && $0.title.hasPrefix("Placeholder ") })
    }

    func testA1PlaceholderItemsAreFoundByKindMoodLengthBandAndText() {
        let catalogue = SoundCatalogue(bundledFolder: Self.shippedSounds, userFolder: root + "/user")
        catalogue.reloadNow()
        XCTAssertEqual(catalogue.search(SoundQuery()).count, 8)
        XCTAssertEqual(catalogue.search(SoundQuery(kind: .effect)).count, 4)
        XCTAssertEqual(catalogue.search(SoundQuery(kind: .music)).count, 3)
        XCTAssertEqual(catalogue.search(SoundQuery(kind: .ambience)).map(\.item.id), ["dark-drone"])
        XCTAssertEqual(catalogue.search(SoundQuery(mood: .calm)).map(\.item.id), ["calm-pad"])
        XCTAssertEqual(catalogue.search(SoundQuery(lengthBand: .under10s)).count, 8)
        XCTAssertEqual(catalogue.search(SoundQuery(lengthBand: .over3min)), [])
        XCTAssertEqual(catalogue.search(SoundQuery(text: "chime")).map(\.item.id), ["soft-chime"])
        XCTAssertEqual(catalogue.search(SoundQuery(text: "sweep")).count, 2)
        XCTAssertEqual(catalogue.search(SoundQuery(text: "sweep down")).map(\.item.id), ["sweep-down"])
        XCTAssertEqual(catalogue.search(SoundQuery(text: "nothing like this")), [])
    }

    func testThePlaceholderPackIsCurrentWithItsGenerator() throws {
        let sounds = Self.shippedSounds + "/placeholder.mpvfxsounds"
        let data = try Data(contentsOf: URL(fileURLWithPath: sounds + "/pack.json"))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("placeholder-owned"))
        let total = try FileManager.default.subpathsOfDirectory(atPath: sounds).reduce(0) { sum, path in
            sum + ((try FileManager.default.attributesOfItem(atPath: sounds + "/" + path)[.size] as? Int) ?? 0)
        }
        XCTAssertLessThan(total, 2_000_000, "the placeholder pack stays under 2 MB")
    }

    func testLengthBandsSplitAtTenSecondsOneMinuteAndThreeMinutes() {
        XCTAssertEqual(SoundLengthBand(durationMs: 9_999), .under10s)
        XCTAssertEqual(SoundLengthBand(durationMs: 10_000), .from10sTo1min)
        XCTAssertEqual(SoundLengthBand(durationMs: 59_999), .from10sTo1min)
        XCTAssertEqual(SoundLengthBand(durationMs: 60_000), .from1minTo3min)
        XCTAssertEqual(SoundLengthBand(durationMs: 180_000), .from1minTo3min)
        XCTAssertEqual(SoundLengthBand(durationMs: 180_001), .over3min)
    }

    // MARK: A2 each rule has its typed issue

    func testA2ADuplicateIdHidesTheLaterItemOnly() throws {
        let report = try pack { f in try f.addTone("a"); try f.addTone("b"); f.items.append(f.items[0]) }
        XCTAssertEqual(report.items.map(\.id), ["a", "b"])
        XCTAssertEqual(codes(report), [.duplicateId])
        XCTAssertEqual(report.issues.first?.packId, "fixture")
        XCTAssertEqual(report.issues.first?.itemId, "a")
    }

    func testA2AMissingItemIdIsAnIssueAndTheOtherItemsStay() throws {
        let report = try pack { f in try f.addTone("a"); try f.addTone("b"); f.items[0].removeValue(forKey: "id") }
        XCTAssertEqual(report.items.map(\.id), ["b"])
        XCTAssertEqual(codes(report), [.missingField])
    }

    func testA2AMissingFileIsAnIssueForThatItem() throws {
        let report = try pack { f in
            try f.addTone("a"); try f.addTone("b")
            try FileManager.default.removeItem(atPath: f.folder + "/audio/a.wav")
        }
        XCTAssertEqual(report.items.map(\.id), ["b"])
        XCTAssertEqual(codes(report), [.fileMissing])
        XCTAssertEqual(report.issues.first?.itemId, "a")
        XCTAssertEqual(report.state, .ready)
    }

    func testA2AShaMismatchHidesTheItem() throws {
        let report = try pack { f in
            try f.addTone("a"); try f.addTone("b")
            f.items[0]["sha256"] = String(repeating: "0", count: 64)
        }
        XCTAssertEqual(report.items.map(\.id), ["b"])
        XCTAssertEqual(codes(report), [.hashMismatch])
    }

    func testA2ADurationThatDiffersByMoreThan50MsIsAnIssueAndWithin50MsPasses() throws {
        let tooFar = try pack { f in try f.addTone("a", seconds: 0.5); f.items[0]["durationMs"] = 600 }
        XCTAssertEqual(codes(tooFar), [.durationMismatch])
        XCTAssertEqual(tooFar.items, [])
        let near = try pack { f in try f.addTone("a", seconds: 0.5); f.items[0]["durationMs"] = 540 }
        XCTAssertEqual(near.issues, [])
        XCTAssertEqual(near.items.count, 1)
    }

    func testA2AFormatTheImportTableRefusesIsAnIssue() throws {
        let report = try pack { f in
            try f.addTone("ok")
            try f.addTone("text", file: "audio/notes.txt")
            try f.addTone("garbage")
            try Data("not audio at all".utf8).write(to: URL(fileURLWithPath: f.folder + "/audio/garbage.wav"))
            f.items[2]["sha256"] = sha256Hex(Data("not audio at all".utf8))
        }
        XCTAssertEqual(report.items.map(\.id), ["ok"])
        XCTAssertEqual(codes(report), [.formatRefused, .formatRefused])
        XCTAssertEqual(report.issues.compactMap(\.itemId), ["text", "garbage"])
    }

    func testA2InvalidItemValuesAreTypedIssuesNeverClamped() throws {
        let report = try pack { f in
            for id in ["kind", "channels", "bpm", "loopable", "sha", "moods"] { try f.addTone(id) }
            f.items[0]["kind"] = "jingle"
            f.items[1]["channels"] = 99
            f.items[2]["bpm"] = 5
            f.items[3]["loopable"] = "yes"
            f.items[4]["sha256"] = "xyz"
            f.items[5]["moods"] = "calm"
        }
        XCTAssertEqual(report.items, [])
        XCTAssertEqual(codes(report), Array(repeating: .invalidValue, count: 6))
    }

    func testUnknownMoodsAreKeptAsTagsAndKnownOnesAsMoods() throws {
        let report = try pack { f in try f.addTone("a", moods: ["calm", "nostalgic"], tags: ["soft"]) }
        XCTAssertEqual(report.items.first?.moods, [.calm])
        XCTAssertEqual(report.items.first?.tags, ["soft", "nostalgic"])
    }

    func testAPackWithoutPackJsonOrWithBrokenJsonIsInvalidWithAnIssue() throws {
        let empty = root + "/empty.mpvfxsounds"
        try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
        let missing = SoundPackReader.read(folder: empty)
        XCTAssertEqual(missing.state, .invalid)
        XCTAssertEqual(missing.issues.map(\.code), [.unreadablePackFile])
        XCTAssertEqual(missing.issues.first?.packId, "empty")
        try Data("{ not json".utf8).write(to: URL(fileURLWithPath: empty + "/pack.json"))
        XCTAssertEqual(SoundPackReader.read(folder: empty).issues.map(\.code), [.malformedPackFile])
        try Data("[1,2]".utf8).write(to: URL(fileURLWithPath: empty + "/pack.json"))
        XCTAssertEqual(SoundPackReader.read(folder: empty).issues.map(\.code), [.malformedPackFile])
    }

    func testAPackWithoutALicenceTextHidesItsItems() throws {
        let report = try pack { f in
            try f.addTone("a")
            try FileManager.default.removeItem(atPath: f.folder + "/LICENCE.txt")
        }
        XCTAssertEqual(report.state, .invalid)
        XCTAssertEqual(codes(report), [.licenceMissing])
        XCTAssertEqual(report.items, [])
    }

    func testDeferredChecksSkipTheHashAndVerifyCatchesItAtFirstUse() throws {
        let fixture = try PackFixture(parent: root)
        try fixture.addTone("a")
        fixture.items[0]["sha256"] = String(repeating: "f", count: 64)
        try fixture.write()
        let deferred = SoundPackReader.read(folder: fixture.folder, checks: .deferred)
        XCTAssertEqual(deferred.issues, [])
        let item = try XCTUnwrap(deferred.items.first)
        XCTAssertEqual(SoundPackReader.verify(item, inPack: "fixture").map(\.code), [.hashMismatch])
    }

    // MARK: A3 a newer pack is listed and untouched

    func testA3AV2PackIsListedAsNewerItsItemsHiddenAndItsFilesUnchanged() throws {
        let fixture = try PackFixture(parent: root)
        try fixture.addTone("a")
        fixture.header["v"] = 2
        fixture.header["somethingNew"] = ["x": 1]
        fixture.items[0]["kind"] = "a kind from the future"
        try fixture.write()
        let before = try snapshot(fixture.folder)
        let report = SoundPackReader.read(folder: fixture.folder)
        XCTAssertEqual(report.state, .newerVersion(2))
        XCTAssertEqual(report.items, [])
        XCTAssertEqual(codes(report), [.newerVersion])
        XCTAssertEqual(report.name, "Fixture pack")
        XCTAssertEqual(try snapshot(fixture.folder), before)

        let catalogue = SoundCatalogue(bundledFolder: nil, userFolder: root)
        catalogue.reloadNow()
        XCTAssertEqual(catalogue.snapshot.packs.map(\.state), [.newerVersion(2)])
        XCTAssertEqual(catalogue.search(SoundQuery()), [])
        XCTAssertEqual(try snapshot(fixture.folder), before)
    }

    func snapshot(_ folder: String) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: folder) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: folder + "/" + path, isDirectory: &isDirectory), !isDirectory.boolValue {
                out[path] = try Data(contentsOf: URL(fileURLWithPath: folder + "/" + path))
            }
        }
        return out
    }

    // MARK: A4 paths outside the pack are refused

    func testA4PathTraversalAndAbsolutePathsAreRefused() throws {
        let hostile = ["../../etc/passwd", "audio/../../outside.wav", "/etc/passwd", "audio\\..\\x.wav", "C:/Windows/x.wav", "", "audio/\u{0}x.wav"]
        for file in hostile {
            let report = try pack { f in try f.addTone("good"); try f.addTone("bad"); f.items[1]["file"] = file }
            XCTAssertEqual(report.items.map(\.id), ["good"], file)
            XCTAssertEqual(report.issues.count, 1, file)
            XCTAssertEqual(report.issues.first?.itemId, "bad", file)
            XCTAssertTrue([.fileOutsidePack, .invalidValue].contains(report.issues[0].code), file)
        }
    }

    #if !os(Windows)
    func testA4ASymbolicLinkLeavingThePackIsRefused() throws {
        let outside = root + "/outside.wav"
        try TestMedia.wav(TestMedia.tone(seconds: 0.5, rate: 22_050), rate: 22_050, channels: 1).write(to: URL(fileURLWithPath: outside))
        let report = try pack { f in
            try f.addTone("a")
            try FileManager.default.createSymbolicLink(atPath: f.folder + "/audio/link.wav", withDestinationPath: outside)
            f.items[0]["file"] = "audio/link.wav"
        }
        XCTAssertEqual(codes(report), [.fileOutsidePack])
        XCTAssertEqual(report.items, [])
    }
    #endif

    // MARK: A5 install

    func testA5InstallCopiesThePackIntoTheUserFolderAndTheCatalogueListsIt() async throws {
        let fixture = try PackFixture(parent: root + "-src")
        defer { try? FileManager.default.removeItem(atPath: root + "-src") }
        try fixture.addTone("a", kind: "music", moods: ["calm"]); try fixture.write()
        let user = root + "/sound-packs"
        let catalogue = SoundCatalogue(bundledFolder: nil, userFolder: user)
        let report = try await catalogue.install(from: fixture.folder, durableWrite: TestDurableWrite())
        XCTAssertEqual(report.issues, [])
        XCTAssertEqual(report.folder, user + "/fixture.mpvfxsounds")
        XCTAssertEqual(try snapshot(fixture.folder), try snapshot(user + "/fixture.mpvfxsounds"))
        XCTAssertEqual(catalogue.search(SoundQuery(mood: .calm)).map(\.item.id), ["a"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: user), ["fixture.mpvfxsounds"])
    }

    func testA5AnInterruptedCopyLeavesNoHalfPackListed() throws {
        let fixture = try PackFixture(parent: root + "-src")
        defer { try? FileManager.default.removeItem(atPath: root + "-src") }
        try fixture.addTone("a"); try fixture.addTone("b"); try fixture.write()
        struct Interrupted: Error {}
        let user = root + "/sound-packs"
        XCTAssertThrowsError(try SoundPackInstaller.install(from: fixture.folder, into: user, durableWrite: TestDurableWrite(),
                                                            afterCopy: { throw Interrupted() })) { error in
            XCTAssertEqual((error as? SoundPackInstallError)?.reason, .copyFailed)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: user), [], "staging is removed")
        let catalogue = SoundCatalogue(bundledFolder: nil, userFolder: user)
        catalogue.reloadNow()
        XCTAssertEqual(catalogue.snapshot.packs, [])
    }

    func testA5ALeftoverStagingFolderIsNeverListed() throws {
        let user = root + "/sound-packs"
        try FileManager.default.createDirectory(atPath: user + "/.installing-abc123/audio", withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: URL(fileURLWithPath: user + "/.installing-abc123/pack.json"))
        let catalogue = SoundCatalogue(bundledFolder: nil, userFolder: user)
        catalogue.reloadNow()
        XCTAssertEqual(catalogue.snapshot.packs, [])
    }

    func testInstallingTheSamePackTwiceIsRefusedAndKeepsTheFirst() throws {
        let fixture = try PackFixture(parent: root + "-src")
        defer { try? FileManager.default.removeItem(atPath: root + "-src") }
        try fixture.addTone("a"); try fixture.write()
        let user = root + "/sound-packs"
        try SoundPackInstaller.install(from: fixture.folder, into: user, durableWrite: TestDurableWrite())
        let before = try snapshot(user + "/fixture.mpvfxsounds")
        XCTAssertThrowsError(try SoundPackInstaller.install(from: fixture.folder, into: user, durableWrite: TestDurableWrite())) {
            XCTAssertEqual(($0 as? SoundPackInstallError)?.reason, .alreadyInstalled)
        }
        XCTAssertEqual(try snapshot(user + "/fixture.mpvfxsounds"), before)
    }

    func testInstallingAFolderThatIsNotAPackIsRefusedWithItsIssues() throws {
        let junk = root + "-junk"
        try FileManager.default.createDirectory(atPath: junk, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: junk) }
        XCTAssertThrowsError(try SoundPackInstaller.install(from: junk, into: root + "/sound-packs", durableWrite: TestDurableWrite())) {
            let error = $0 as? SoundPackInstallError
            XCTAssertEqual(error?.reason, .notAPack)
            XCTAssertEqual(error?.issues.map(\.code), [.unreadablePackFile])
        }
    }

    #if !os(Windows)
    func testInstallRefusesAPackHoldingASymbolicLink() throws {
        let fixture = try PackFixture(parent: root + "-src")
        defer { try? FileManager.default.removeItem(atPath: root + "-src") }
        try fixture.addTone("a"); try fixture.write()
        try FileManager.default.createSymbolicLink(atPath: fixture.folder + "/audio/extra.wav", withDestinationPath: "/etc/hostname")
        let user = root + "/sound-packs"
        XCTAssertThrowsError(try SoundPackInstaller.install(from: fixture.folder, into: user, durableWrite: TestDurableWrite())) {
            XCTAssertEqual(($0 as? SoundPackInstallError)?.reason, .unsupportedEntry)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: user), [])
    }
    #endif

    // MARK: catalogue

    func testAPackIdUsedTwiceHidesTheLaterPack() throws {
        let bundled = root + "/bundled", user = root + "/user"
        for parent in [bundled, user] {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
            let fixture = try PackFixture(parent: parent, name: parent == bundled ? "fixture" : "copy")
            try fixture.addTone("a"); try fixture.write()
        }
        let catalogue = SoundCatalogue(bundledFolder: bundled, userFolder: user)
        catalogue.reloadNow()
        XCTAssertEqual(catalogue.snapshot.packs.count, 2)
        XCTAssertEqual(catalogue.snapshot.entries.count, 1)
        XCTAssertEqual(catalogue.snapshot.packs.last?.issues.map(\.code), [.duplicatePack])
    }

    func testSearchMatchesTitleTagsMoodAndPackNameAndFiltersCombine() throws {
        let fixture = try PackFixture(parent: root + "/bundled")
        try fixture.addTone("rain", kind: "ambience", moods: ["calm"], tags: ["weather"])
        try fixture.addTone("thunder", kind: "effect", moods: ["dark"], tags: ["weather", "storm"])
        try fixture.write()
        let catalogue = SoundCatalogue(bundledFolder: root + "/bundled", userFolder: root + "/user")
        catalogue.reloadNow()
        XCTAssertEqual(catalogue.search(SoundQuery(text: "weather")).count, 2)
        XCTAssertEqual(catalogue.search(SoundQuery(text: "STORM")).map(\.item.id), ["thunder"])
        XCTAssertEqual(catalogue.search(SoundQuery(text: "fixture pack")).count, 2)
        XCTAssertEqual(catalogue.search(SoundQuery(text: "weather", kind: .ambience, mood: .calm, lengthBand: .under10s)).map(\.item.id), ["rain"])
        XCTAssertEqual(catalogue.search(SoundQuery(text: "weather", kind: .ambience, mood: .dark)), [])
    }

    func testReloadRunsOffTheCallerAndPublishesTheIndex() async throws {
        let catalogue = SoundCatalogue(bundledFolder: Self.shippedSounds, userFolder: root + "/user")
        XCTAssertEqual(catalogue.snapshot.entries.count, 0)
        let index = await catalogue.reload()
        XCTAssertEqual(index.entries.count, 8)
        XCTAssertEqual(catalogue.snapshot, index)
    }
}
