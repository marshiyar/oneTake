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
// Issue #82: the export's final move (publishExport) never replaces a file at the output path, on a filesystem
// with hard links (link(2) / CreateHardLinkW, so these run on Linux, macOS and Windows) and on one without them
// (FAT, exFAT, some network shares). A filesystem without hard links is simulated through publishExport's `link`
// seam, which fails the way such a filesystem does; the exclusive copy fallback then runs for real.
import Foundation
import XCTest
@testable import MpvfxRuntime

final class ExportPublishNoHardLinkTests: XCTestCase {
    private var root = ""
    override func setUpWithError() throws { root = try makeMediaTempDir("export-publish-no-link-") }
    override func tearDown() {
        if !root.isEmpty { try? FileManager.default.removeItem(atPath: root) }
        super.tearDown()
    }

    private let staged = Data("the finished export".utf8)
    private let users = Data("the user's own file".utf8)

    /// A staged export in its own folder, as startExport leaves it before the final move.
    private func stage() throws -> String {
        let dir = PosixPath.join(root, "staging")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = PosixPath.join(dir, "out.mov")
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: staged))
        return path
    }

    /// The error a filesystem without hard links returns for `code`. Only `code` selects the fallback.
    private func noHardLinks(_ code: String) -> (String, String) throws -> Void {
        { from, _ in throw ProjectFSError(code: code, syscall: "link", path: from, errno: 0) }
    }

    /// Acceptance 2 (every OS, Windows included): with real hard links, a file already at the output path is kept
    /// byte for byte and the publish fails with ExportOutputExistsError.
    func testWithHardLinksAnExistingOutputIsKeptAndThePublishFailsWithTheTypedError() throws {
        let source = try stage(), output = PosixPath.join(root, "raced.mov")
        XCTAssertTrue(FileManager.default.createFile(atPath: output, contents: users))
        XCTAssertThrowsError(try publishExport(source, to: output)) { error in
            XCTAssertEqual(error as? ExportOutputExistsError, ExportOutputExistsError(path: output))
        }
        XCTAssertEqual(FileManager.default.contents(atPath: output), users, "the file at the output path is untouched")
        XCTAssertEqual(FileManager.default.contents(atPath: source), staged, "the staged export is left for cleanup")
    }

    /// Acceptance 3: without hard links, a file already at the output path is still never replaced, whichever
    /// error the filesystem gives for the missing hard link.
    func testWithoutHardLinksAnExistingOutputIsKeptAndThePublishFailsWithTheTypedError() throws {
        let source = try stage()
        for code in ["EXDEV", "EPERM", "ENOTSUP", "EOPNOTSUPP", "ENOSYS"] {
            let output = PosixPath.join(root, "raced-\(code).mov")
            XCTAssertTrue(FileManager.default.createFile(atPath: output, contents: users))
            let link = CountingLink(noHardLinks(code))
            XCTAssertThrowsError(try publishExport(source, to: output, link: link.callAsFunction)) { error in
                XCTAssertEqual(error as? ExportOutputExistsError, ExportOutputExistsError(path: output), code)
            }
            XCTAssertEqual(link.calls, 1, "\(code): the simulated filesystem was asked for a hard link")
            XCTAssertEqual(FileManager.default.contents(atPath: output), users, "\(code): the user's file is untouched")
        }
        XCTAssertEqual(FileManager.default.contents(atPath: source), staged)
    }

    /// Acceptance 3: without hard links, an absent output still receives the export, through the exclusive copy.
    func testWithoutHardLinksAnAbsentOutputReceivesACopyOfTheExport() throws {
        let source = try stage(), output = PosixPath.join(root, "copied.mov")
        let link = CountingLink(noHardLinks("ENOTSUP"))
        try publishExport(source, to: output, link: link.callAsFunction)
        XCTAssertEqual(link.calls, 1)
        XCTAssertEqual(FileManager.default.contents(atPath: output), staged)
    }

    /// A link failure that does not mean "no hard links here" is reported, typed, and nothing is copied.
    func testAnyOtherLinkFailureIsReportedAndNothingIsCopied() throws {
        let source = try stage(), output = PosixPath.join(root, "failed.mov")
        XCTAssertThrowsError(try publishExport(source, to: output, link: noHardLinks("EIO"))) { error in
            guard let e = error as? MediaToolError else { return XCTFail("expected MediaToolError, got \(error)") }
            XCTAssertTrue(e.message.hasPrefix("Could not move the export into place: "), e.message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output))
    }
}

/// Counts the hard-link attempts a publish makes, so a test proves it went through the simulated filesystem.
private final class CountingLink {
    private let body: (String, String) throws -> Void
    private(set) var calls = 0
    init(_ body: @escaping (String, String) throws -> Void) { self.body = body }
    func callAsFunction(_ from: String, _ to: String) throws {
        calls += 1
        try body(from, to)
    }
}
