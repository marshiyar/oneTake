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
// Root prefixes of absolute paths on the host. POSIX: "/". Windows: "C:/", "//server/share/" and "/" (the current
// drive's root), with "\" read as "/". The runtime keeps every path in "/" form; Win32 accepts it.
import Foundation

public enum PathFlavor: Sendable {
    case posix, windows
    #if os(Windows)
    public static let host = PathFlavor.windows
    #else
    public static let host = PathFlavor.posix
    #endif
}

public enum HostPath {
    /// `path` with "\" turned into "/" (Windows flavor only; POSIX names may contain "\").
    public static func slashes(_ path: String, _ flavor: PathFlavor = .host) -> String {
        flavor == .windows ? path.replacingOccurrences(of: "\\", with: "/") : path
    }

    /// Root prefix in "/" form: "" for a relative path, "/", and for Windows "C:/" (drive letter upper-cased) or
    /// "//server/share/". A drive-relative "C:x" has no root.
    public static func root(_ path: String, _ flavor: PathFlavor = .host) -> String {
        guard flavor == .windows else { return path.hasPrefix("/") ? "/" : "" }
        let p = slashes(path, flavor)
        let u = Array(p.unicodeScalars)
        if u.count >= 3, u[0].isASCII, CharacterSet.letters.contains(u[0]), u[1] == ":", u[2] == "/" {
            return String(u[0]).uppercased() + ":/"
        }
        if p.hasPrefix("//") {
            let parts = p.dropFirst(2).split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty { return "//\(parts[0])/\(parts[1])/" }
        }
        return p.hasPrefix("/") ? "/" : ""
    }

    public static func isAbsolute(_ path: String, _ flavor: PathFlavor = .host) -> Bool { !root(path, flavor).isEmpty }
}
