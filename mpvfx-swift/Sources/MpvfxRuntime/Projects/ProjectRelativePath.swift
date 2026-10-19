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
// Project-relative paths: checks a `/`-separated path before it is joined onto a project root.
import Foundation
import MpvfxShared

public enum ProjectRelativePathProblem: String, Equatable { case notRelative = "not-relative", traversal }

/// nil when the `/`-separated path is safe to join onto a project root.
/// Host independent by construction (POSIX and Windows separators are both checked explicitly).
public func projectRelativePathProblem(_ path: String) -> ProjectRelativePathProblem? {
    if path.isEmpty || path.contains("\0") || path.contains("\\") || PosixPath.isAbsolute(path)
        || PosixPath.isWindowsAbsolute(path) || startsWithScheme(path) {
        return .notRelative
    }
    // String.split would drop empty segments; JS split keeps them.
    let segments = path.components(separatedBy: "/")
    if segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) { return .traversal }
    if PosixPath.normalize(path) != path { return .traversal }
    return nil
}

/// `/^[a-z]+:/i` (ASCII letters only, as a JS regex without the u flag).
private func startsWithScheme(_ path: String) -> Bool {
    var letters = 0
    for c in path.utf16 {
        if (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) { letters += 1; continue }
        return c == 0x3A && letters > 0
    }
    return false
}
