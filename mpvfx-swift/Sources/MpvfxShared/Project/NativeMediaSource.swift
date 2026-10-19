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
// Media source paths in a native document: the canonical project-owned source and the asset id derived from it.
import Foundation

/// Matches JS /^[a-z][a-z\d+.-]*:/i
func nativeHasURLScheme(_ s: String) -> Bool {
    let scalars = Array(s.unicodeScalars)
    guard let first = scalars.first, first.isASCII,
          (("a"..."z").contains(first) || ("A"..."Z").contains(first)) else { return false }
    for c in scalars.dropFirst() {
        if c == ":" { return true }
        let ok = ("a"..."z").contains(c) || ("A"..."Z").contains(c) || ("0"..."9").contains(c) || c == "+" || c == "." || c == "-"
        if !ok { return false }
    }
    return false
}

/// Canonical project-owned source, or nil (JS `null`).
public func nativeMediaSource(_ source: String, projectId: String) -> String? {
    var path = source
    if nativeHasURLScheme(source) || source.hasPrefix("/api/") {
        // /^(?:mpvfx:\/\/editor)?\/api\/projects\/([^/]+)\/preview\/([^?#]+)(?:[?#].*)?$/
        var rest = Substring(source)
        if rest.hasPrefix("mpvfx://editor") { rest = rest.dropFirst("mpvfx://editor".count) }
        let prefix = "/api/projects/"
        guard rest.hasPrefix(prefix) else { return nil }
        rest = rest.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let rawProject = rest[..<slash]
        guard !rawProject.isEmpty else { return nil }
        rest = rest[rest.index(after: slash)...]
        guard rest.hasPrefix("preview/") else { return nil }
        rest = rest.dropFirst("preview/".count)
        let end = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? rest.endIndex
        let rawPath = rest[..<end]
        guard !rawPath.isEmpty else { return nil }
        guard let project = String(rawProject).removingPercentEncoding,
              let decoded = String(rawPath).removingPercentEncoding else { return nil }
        if project != projectId { return nil }
        path = decoded
    }
    path = path.replacingOccurrences(of: "\\", with: "/")
    let parts = path.components(separatedBy: "/")
    guard let last = parts.last else { return nil }
    if path.isEmpty || path.hasPrefix("/") || path.contains("\0") || parts.contains("..") || last.isEmpty || last == "." { return nil }
    let canonical = parts.filter { $0 != "" && $0 != "." }.joined(separator: "/")
    if canonical.isEmpty || nativeHasURLScheme(canonical) { return nil }
    return canonical
}

/// Only for new assets; an existing asset keeps its persisted ID on reuse.
/// Note: JS `.length` counts UTF-16 code units, so we do too.
public func nativeMediaAssetId(_ kind: NativeProjectAssetKind, canonicalSource: String) -> String {
    "native-asset:\(kind.rawValue):\(canonicalSource.utf16.count):\(canonicalSource)"
}
