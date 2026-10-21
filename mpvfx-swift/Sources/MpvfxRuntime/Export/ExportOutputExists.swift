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
// Issue #24: the export's final move publishes the staged file without replacing anything at the output path.
// startExport checks once, before rendering, that the output is absent; a file created there while the render ran
// must survive, so the move is publishFileExclusive (link(2) / CreateHardLinkW, which fail with EEXIST, or an
// exclusive copy on filesystems without hard links) and the staged file is removed with its staging folder.
import Foundation

/// A file appeared at the export's output path while it rendered; the export left it untouched and failed.
public struct ExportOutputExistsError: Error, Equatable, CustomStringConvertible {
    public let path: String
    public init(path: String) { self.path = path }
    public var message: String {
        "A file named \(PosixPath.basename(path)) appeared in the export folder while exporting. It was left unchanged; choose another name and export again."
    }
    public var description: String { message }
}

/// Moves the finished export from `staged` to `outputPath` without replacing a file there: ExportOutputExistsError
/// when one exists, MediaToolError for any other failure. The caller removes `staged` (it sits in the staging folder).
/// `link` is the hard-link call; tests pass one that fails like a filesystem without hard links (issue #82).
func publishExport(_ staged: String, to outputPath: String,
                   link: (String, String) throws -> Void = ProjectFS.link) throws {
    do { try publishFileExclusive(staged, outputPath, link: link) }
    catch let e as ProjectFSError where e.code == "EEXIST" { throw ExportOutputExistsError(path: outputPath) }
    catch { throw MediaToolError("Could not move the export into place: \(exportErrorMessage(error))") }
}
