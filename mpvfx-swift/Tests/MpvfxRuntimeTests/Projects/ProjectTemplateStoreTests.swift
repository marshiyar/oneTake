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
// Project templates on disk (#332): save as template without media, list, delete, and a new project from a template.
import Foundation
import XCTest
@testable import MpvfxShared
@testable import MpvfxRuntime

final class ProjectTemplateStoreTests: XCTestCase {
    var root = ""
    var project = ""
    var store: ProjectTemplateStore!

    override func setUpWithError() throws {
        root = try makeTempDir("templates-")
        project = root + "/Weekly Show"
        try FileManager.default.createDirectory(atPath: project + "/.studio", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: project + "/luts", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: project + "/renders", withIntermediateDirectories: true)
        for (name, text) in [("intro.mov", "media"), ("outro.mov", "media"), ("logo.mov", "media"), ("warm.cube", "LUT"),
                             ("luts/cool.CUBE", "LUT"), ("renders/old.cube", "not a lut of the project"), ("notes.txt", "notes")] {
            try Data(text.utf8).write(to: URL(fileURLWithPath: "\(project)/\(name)"))
        }
        store = ProjectTemplateStore(userData: root + "/userData", durableWrite: TestDurableWrite())
    }
    override func tearDown() { if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }; super.tearDown() }

    func document() throws -> NativeProjectDocument {
        try parseNativeProjectDocument(try NativeJSONValue.parse("""
        {"schemaVersion":1,"mediaEngine":"native","id":"project:weekly","revision":7,"frameRate":{"numerator":30,"denominator":1},
         "canvas":{"width":1920,"height":1080,"background":"#101010"},
         "assets":[{"id":"asset:intro","kind":"video","name":"intro.mov","source":"intro.mov","durationFrames":300},
                   {"id":"asset:outro","kind":"video","name":"outro.mov","source":"outro.mov","durationFrames":300},
                   {"id":"asset:logo","kind":"video","name":"logo.mov","source":"logo.mov","durationFrames":300},
                   {"id":"asset:title","kind":"element","name":"Title","durationFrames":90}],
         "sequence":{"id":"sequence:main","name":"Weekly Show","tracks":[{"id":"track:video-1","kind":"video","clips":[
           {"id":"clip:intro","assetId":"asset:intro","startFrame":0,"durationFrames":90,"sourceInFrame":10,"effects":[],"parameterTracks":[],"placeholder":{"v":1,"index":1,"label":"Intro"}},
           {"id":"clip:outro","assetId":"asset:outro","startFrame":90,"durationFrames":60,"sourceInFrame":0,"effects":[],"parameterTracks":[],"placeholder":{"v":1,"index":2}},
           {"id":"clip:logo","assetId":"asset:logo","startFrame":150,"durationFrames":30,"sourceInFrame":0,"effects":[],"parameterTracks":[]},
           {"id":"clip:title","assetId":"asset:title","startFrame":0,"durationFrames":90,"sourceInFrame":0,"effects":[],"parameterTracks":[],
            "text":{"content":"Episode","fontFamily":"Avenir Next"}}]}]}}
        """))
    }

    func files(_ dir: String) -> [String] {
        let walker = FileManager.default.enumerator(atPath: dir)
        return (walker?.allObjects as? [String] ?? []).filter { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: "\(dir)/\(path)", isDirectory: &isDirectory) && !isDirectory.boolValue
        }.sorted()
    }

    // A2
    func testSavingWritesTheFolderWithoutAnyMediaFile() throws {
        let template = try store.save(projectDirectory: project, document: try document(), name: "  Weekly  ", description: " Our show ")
        XCTAssertEqual(template.name, "Weekly")
        XCTAssertEqual(template.description, "Our show")
        XCTAssertEqual(files(store.directory + "/" + template.id), [".studio/project.json", "luts/cool.CUBE", "template.json", "warm.cube"],
                       "the document, the LUTs and the metadata: no media, no renders, no notes")
        XCTAssertEqual(files(store.directory), [template.id + "/.studio/project.json", template.id + "/luts/cool.CUBE",
                                                template.id + "/template.json", template.id + "/warm.cube"], "nothing else was left in templates/")
        XCTAssertEqual(try String(contentsOfFile: "\(store.directory)/\(template.id)/warm.cube", encoding: .utf8), "LUT")
    }

    func testThePlaceholdersReferenceNoFileAndTheTemplateRemembersItsSlotsAndFonts() throws {
        let template = try store.save(projectDirectory: project, document: try document(), name: "Weekly")
        XCTAssertEqual(template.slots, [ProjectTemplateSlot(index: 1, label: "Intro", kind: "video", durationFrames: 90),
                                        ProjectTemplateSlot(index: 2, label: nil, kind: "video", durationFrames: 60)])
        XCTAssertEqual(template.fonts, ["Avenir Next"])
        XCTAssertEqual(template.missingFonts { $0 != "Avenir Next" }, ["Avenir Next"])
        XCTAssertEqual(template.missingFonts { _ in true }, [])
        let saved = try ProjectDocuments.validate(try String(contentsOfFile: "\(store.directory)/\(template.id)/.studio/project.json", encoding: .utf8))
        XCTAssertEqual(saved.assets.first { $0.id == "asset:intro" }?.source, nil)
        XCTAssertEqual(saved.assets.first { $0.id == "asset:outro" }?.source, nil)
        XCTAssertEqual(saved.assets.first { $0.id == "asset:logo" }?.source, "logo.mov", "an unmarked clip keeps its reference")
        XCTAssertEqual(saved.unfilledPlaceholderNumbers, [1, 2])
        XCTAssertEqual(saved.id, template.id)
        XCTAssertEqual(try document().assets.first?.source, "intro.mov", "the open project's document is not touched")
    }

    func testListingIsByNameAndLeavesUnreadableFoldersAlone() throws {
        try store.save(projectDirectory: project, document: try document(), name: "beta")
        let alpha = try store.save(projectDirectory: project, document: try document(), name: "Alpha")
        try FileManager.default.createDirectory(atPath: store.directory + "/broken", withIntermediateDirectories: true)
        try Data("{".utf8).write(to: URL(fileURLWithPath: store.directory + "/broken/template.json"))
        XCTAssertEqual(store.list().map(\.name), ["Alpha", "beta"])
        try store.delete(id: alpha.id)
        XCTAssertEqual(store.list().map(\.name), ["beta"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory + "/broken/template.json"))
        XCTAssertThrowsError(try store.delete(id: "broken"), "only a template folder is ever removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory + "/broken"))
    }

    func testANameIsRequired() throws {
        XCTAssertThrowsError(try store.save(projectDirectory: project, document: try document(), name: "  "))
        XCTAssertEqual(store.list(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory), "nothing was created")
    }

    // A3
    func testANewProjectFromATemplateHasTheTemplatesClipsWithTheNewAssets() throws {
        let template = try store.save(projectDirectory: project, document: try document(), name: "Weekly")
        let target = root + "/projects/Episode 12"
        let content = try store.createProject(templateId: template.id, name: "Episode 12", at: target) { directory in
            XCTAssertEqual(directory, target)
            try Data("one".utf8).write(to: URL(fileURLWithPath: directory + "/ep12-intro.mov"))
            try Data("two".utf8).write(to: URL(fileURLWithPath: directory + "/ep12-outro.mov"))
            return [1: NativeProjectAsset(id: "asset:ep12-intro", kind: .video, name: "ep12-intro.mov", source: "ep12-intro.mov", durationFrames: 900),
                    2: NativeProjectAsset(id: "asset:ep12-outro", kind: .video, name: "ep12-outro.mov", source: "ep12-outro.mov", durationFrames: 900)]
        }
        let made = try ProjectDocuments.validate(content)
        XCTAssertEqual(try ProjectDocuments.validate(try String(contentsOfFile: target + "/.studio/project.json", encoding: .utf8)), made)
        var expected = try document().sequence.tracks[0].clips
        expected[0].assetId = "asset:ep12-intro"; expected[0].placeholder = nil
        expected[1].assetId = "asset:ep12-outro"; expected[1].placeholder = nil
        XCTAssertEqual(made.sequence.tracks[0].clips, expected)
        XCTAssertEqual(made.unfilledPlaceholderNumbers, [])
        XCTAssertEqual(made.assets.map(\.id), ["asset:logo", "asset:title", "asset:ep12-intro", "asset:ep12-outro"])
        XCTAssertNotEqual(made.id, template.id)
        XCTAssertNotEqual(made.id, "project:weekly")
        XCTAssertEqual(made.revision, 0)
        XCTAssertEqual(made.sequence.name, "Episode 12")
        XCTAssertEqual(files(target).filter { !$0.hasPrefix(".hyperframes/") }, [".studio/project.json", "ep12-intro.mov", "ep12-outro.mov", "luts/cool.CUBE", "warm.cube"])
        XCTAssertEqual(store.list().map(\.id), [template.id], "the template is unchanged")
    }

    func testFillingLaterLeavesTheSlotsMarked() throws {
        let template = try store.save(projectDirectory: project, document: try document(), name: "Weekly")
        let target = root + "/projects/Later"
        let content = try store.createProject(templateId: template.id, name: "Later", at: target)
        XCTAssertEqual(try ProjectDocuments.validate(content).unfilledPlaceholderNumbers, [1, 2])
    }

    func testARefusedFillRemovesTheNewFolder() throws {
        let template = try store.save(projectDirectory: project, document: try document(), name: "Weekly")
        let target = root + "/projects/Short"
        XCTAssertThrowsError(try store.createProject(templateId: template.id, name: "Short", at: target) { _ in
            [1: NativeProjectAsset(id: "asset:short", kind: .video, name: "short.mov", source: "short.mov", durationFrames: 20)]
        }) { error in
            XCTAssertEqual((error as? NativeProjectClipFailure)?.message, "Replacement media is too short: missing 80 source frames")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
    }

    func testAnExistingFolderIsNeverUsed() throws {
        let template = try store.save(projectDirectory: project, document: try document(), name: "Weekly")
        try FileManager.default.createDirectory(atPath: root + "/projects/Taken", withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: URL(fileURLWithPath: root + "/projects/Taken/keep.txt"))
        XCTAssertThrowsError(try store.createProject(templateId: template.id, name: "Taken", at: root + "/projects/Taken"))
        XCTAssertEqual(try String(contentsOfFile: root + "/projects/Taken/keep.txt", encoding: .utf8), "keep")
    }
}
