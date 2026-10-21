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
// Exclusive file publication on hard-link and ordinary removable filesystems.
import Foundation

/// Hard-links `source` to `destination`; on filesystems without hard links falls back to an exclusive streamed copy.
/// A collision is never an overwrite (EEXIST is thrown as a ProjectFSError). The destination is fsynced.
public func publishFileExclusive(_ source: String, _ destination: String) throws {
    try publishFileExclusive(source, destination, link: ProjectFS.link)
}

/// publishFileExclusive with the hard-link call as a seam: `link` stands in for link(2) / CreateHardLinkW, so a test
/// can simulate a filesystem without hard links and check that the copy fallback never replaces a file either.
func publishFileExclusive(_ source: String, _ destination: String, link: (String, String) throws -> Void) throws {
    do { try link(source, destination) }
    catch let error as ProjectFSError {
        guard ["EXDEV", "EPERM", "ENOTSUP", "EOPNOTSUPP", "ENOSYS"].contains(error.code) else { throw error }
        try copyFileExclusiveStreaming(source, destination)
    }
    try ProjectFS.fsyncFile(destination)
}
