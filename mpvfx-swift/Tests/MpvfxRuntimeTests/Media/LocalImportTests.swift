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
// Local media import. Inputs are real media written by
// our own code, since import probes every picture and sound file with the media engine; the codec table moved to
// ImportFormatsTests.
import Foundation
import XCTest
@testable import MpvfxRuntime

final class LocalImportTests: XCTestCase {
    private var roots: [String] = []
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(atPath: $0) }; super.tearDown() }
    private func fixture() throws -> (root: String, projectRoot: String) {
        let root = try makeMediaTempDir("mpvfx-native-import-"); roots.append(root)
        try FileManager.default.createDirectory(atPath: root + "/project", withIntermediateDirectories: false)
        return (root, root + "/project")
    }
    private func run(_ projectRoot: String, _ paths: [String], directory: String? = nil) throws -> LocalMediaImportResult {
        try importLocalMedia(projectRoot: projectRoot, paths: paths, directory: directory, durableWrite: TestDurableWrite())
    }
    private func ls(_ path: String) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: path).sorted() }
    private func writePNG(_ path: String, _ rgb: (UInt8, UInt8, UInt8)) throws {
        try TestMedia.png(TestMedia.solid(rgb, width: 2, height: 2), width: 2, height: 2).write(to: URL(fileURLWithPath: path))
    }

    func testCopiesFilesAboveTheOld500MiBLimitWithoutReadingTheirBytesIntoMemory() throws {
        let (root, projectRoot) = try fixture()
        let source = root + "/large.wav", size: UInt64 = 501 * 1024 * 1024
        // A WAV header for 16-bit mono PCM whose data chunk fills the (sparse) rest of the file.
        var header = [UInt8](TestMedia.wav([], rate: 48_000, channels: 1))
        header.replaceSubrange(4..<8, with: TestMedia.le32(UInt32(size - 8)))
        header.replaceSubrange(40..<44, with: TestMedia.le32(UInt32(size - 44)))
        FileManager.default.createFile(atPath: source, contents: Data(header))
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: source))
        try handle.truncate(atOffset: size)
        try handle.seek(toOffset: size - 3); try handle.write(contentsOf: Data("end".utf8)); try handle.close()
        XCTAssertEqual(try run(projectRoot, [source]), LocalMediaImportResult(files: ["large.wav"], invalid: []))
        let copied = projectRoot + "/large.wav"
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: copied)[.size] as? NSNumber)?.uint64Value, size)
        let reader = try FileHandle(forReadingFrom: URL(fileURLWithPath: copied))
        try reader.seek(toOffset: size - 3)
        XCTAssertEqual(String(decoding: try reader.read(upToCount: 3) ?? Data(), as: UTF8.self), "end"); try reader.close()
        XCTAssertEqual(try ls(projectRoot), ["large.wav"])
    }

    func testPreservesUnicodeNamesAvoidsCollisionsAndReportsEachFailedMemberOfABatch() throws {
        let (root, projectRoot) = try fixture()
        let name = "Khé¿ (demo).png", source = root + "/" + name
        try writePNG(source, (0, 255, 0))
        FileManager.default.createFile(atPath: root + "/empty.png", contents: Data())
        try FileManager.default.createDirectory(atPath: projectRoot + "/assets", withIntermediateDirectories: false)
        try "existing".write(toFile: projectRoot + "/assets/" + name, atomically: false, encoding: .utf8)
        let result = try run(projectRoot, [source, root + "/missing.mov", root + "/empty.png", source], directory: "assets")
        XCTAssertEqual(result.files, ["assets/Khé¿ (demo) (2).png", "assets/Khé¿ (demo) (3).png"])
        XCTAssertEqual(result.invalid.map(\.name), ["missing.mov", "empty.png"])
        XCTAssertEqual(try String(contentsOfFile: projectRoot + "/assets/" + name, encoding: .utf8), "existing")
        XCTAssertFalse(try ls(projectRoot + "/assets").contains { $0.hasPrefix(".mpvfx") })
    }

    func testRejectsTraversalReservedDirectoriesAndSymlinkedDestinations() throws {
        let (root, projectRoot) = try fixture()
        let source = root + "/a.png"
        try writePNG(source, (255, 0, 0))
        for directory in ["../escape", ".studio", "assets/../../escape", "node_modules"] {
            XCTAssertThrowsError(try run(projectRoot, [source], directory: directory), directory)
        }
        try FileManager.default.createSymbolicLink(atPath: projectRoot + "/escape", withDestinationPath: root)
        let result = try run(projectRoot, [source], directory: "escape")
        XCTAssertEqual(result.files, []); XCTAssertEqual(result.invalid.count, 1)
    }

    /// A file whose contents are not what its name says is refused and nothing is left in the project.
    func testRejectsAFileTheEngineCannotReadAndKeepsAGoodOne() throws {
        let (root, projectRoot) = try fixture()
        try "not a movie".write(toFile: root + "/bad.mp4", atomically: false, encoding: .utf8)
        let frame = TestMedia.solid((255, 0, 0), width: 8, height: 8)
        try TestMedia.writeMOV(root + "/good.mov", frames: [frame, frame], width: 8, height: 8)
        let result = try run(projectRoot, [root + "/bad.mp4", root + "/good.mov"])
        XCTAssertEqual(result.files, ["good.mov"])
        XCTAssertEqual(result.invalid.map(\.name), ["bad.mp4"])
        XCTAssertEqual(try ls(projectRoot), ["good.mov"])
    }
}
