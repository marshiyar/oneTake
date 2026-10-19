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
// POSIX path arithmetic on plain strings (no filesystem access): join, normalize, resolve, relative, dirname,
// basename, extname. Paths use "/" on every platform; project-relative paths are always written that way. On Windows
// absolute paths keep their root ("C:/", "//server/share/"; see MpvfxShared.HostPath) and a backslash is read as "/".
import Foundation
import MpvfxShared

public enum PosixPath {
    public static func isAbsolute(_ path: String) -> Bool { isAbsolute(path, .host) }
    static func isAbsolute(_ path: String, _ f: PathFlavor) -> Bool { HostPath.isAbsolute(path, f) }

    /// Collapses "//", "." and ".."; keeps a trailing slash; "" becomes ".".
    public static func normalize(_ path: String) -> String { normalize(path, .host) }
    static func normalize(_ path0: String, _ f: PathFlavor) -> String {
        if path0.isEmpty { return "." }
        let path = HostPath.slashes(path0, f), root = HostPath.root(path, f)
        let rest = String(path.dropFirst(root.count)), trailing = path.hasSuffix("/")
        var out = collapse(rest, allowAboveRoot: root.isEmpty).joined(separator: "/")
        if out.isEmpty && root.isEmpty { out = "." }
        if !out.isEmpty && trailing { out += "/" }
        return root + out
    }

    /// Joins the non-empty parts and normalizes the result.
    public static func join(_ paths: String...) -> String { join(paths, .host) }
    public static func join(_ paths: [String]) -> String { join(paths, .host) }
    static func join(_ paths: [String], _ f: PathFlavor) -> String {
        let parts = paths.filter { !$0.isEmpty }
        return parts.isEmpty ? "." : normalize(parts.joined(separator: "/"), f)
    }

    /// Absolute path: the parts are applied right to left until one is absolute, then `cwd`. No trailing slash.
    /// Windows: a path rooted at "/" takes the drive (or share) of `cwd`.
    public static func resolve(_ paths: String..., cwd: String = FileManager.default.currentDirectoryPath) -> String {
        resolve(paths, cwd: cwd, .host)
    }
    public static func resolve(_ paths: [String], cwd: String = FileManager.default.currentDirectoryPath) -> String {
        resolve(paths, cwd: cwd, .host)
    }
    static func resolve(_ paths: [String], cwd: String, _ f: PathFlavor) -> String {
        var resolved = "", root = ""
        for p0 in ([cwd] + paths).reversed() where !p0.isEmpty {
            let p = HostPath.slashes(p0, f)
            resolved = resolved.isEmpty ? p : p + "/" + resolved
            root = HostPath.root(p, f)
            if !root.isEmpty { break }
        }
        let rest = String(resolved.dropFirst(root.count))
        if root.count <= 1 && f == .windows {
            let cwdRoot = HostPath.root(cwd, f)
            if cwdRoot.count > 1 { root = cwdRoot } else { root = "/" }
        }
        if root.isEmpty { root = "/" }
        return root + collapse(rest, allowAboveRoot: false).joined(separator: "/")
    }

    /// The path from `from` to `to` ("" when they resolve to the same path). Windows: names compare
    /// case-insensitively, and paths on different roots give the resolved `to`.
    public static func relative(_ from: String, _ to: String, cwd: String = FileManager.default.currentDirectoryPath) -> String {
        relative(from, to, cwd: cwd, .host)
    }
    static func relative(_ from: String, _ to: String, cwd: String, _ f: PathFlavor) -> String {
        let ra = resolve([from], cwd: cwd, f), rb = resolve([to], cwd: cwd, f)
        let rootA = HostPath.root(ra, f), rootB = HostPath.root(rb, f)
        func key(_ s: String) -> String { f == .windows ? s.lowercased() : s }
        if key(rootA) != key(rootB) { return rb }
        let a = components(String(ra.dropFirst(rootA.count))), b = components(String(rb.dropFirst(rootB.count)))
        var common = 0
        while common < a.count, common < b.count, key(a[common]) == key(b[common]) { common += 1 }
        return (Array(repeating: "..", count: a.count - common) + b[common...]).joined(separator: "/")
    }

    /// Everything before the last component ("." for a bare name, the root for a root child).
    public static func dirname(_ path: String) -> String { dirname(path, .host) }
    static func dirname(_ path0: String, _ f: PathFlavor) -> String {
        if path0.isEmpty { return "." }
        let path = HostPath.slashes(path0, f), root = HostPath.root(path, f)
        if root.count > 1 {
            var rest = Substring(path.dropFirst(root.count))
            while rest.hasSuffix("/") { rest = rest.dropLast() }
            guard let slash = rest.lastIndex(of: "/") else { return root }
            var head = rest[..<slash]
            while head.hasSuffix("/") { head = head.dropLast() }
            return root + head
        }
        var p = Substring(path)
        while p.count > 1, p.hasSuffix("/") { p = p.dropLast() }
        guard let slash = p.lastIndex(of: "/") else { return "." }
        var head = p[..<slash]
        while head.count > 1, head.hasSuffix("/") { head = head.dropLast() }
        return head.isEmpty ? "/" : String(head)
    }

    /// Last path component, ignoring trailing slashes ("" for a root).
    public static func basename(_ path: String) -> String { basename(path, .host) }
    static func basename(_ path0: String, _ f: PathFlavor) -> String {
        let path = HostPath.slashes(path0, f), root = HostPath.root(path, f)
        var p = Substring(root.count > 1 ? String(path.dropFirst(root.count)) : path)
        while p.count > 1, p.hasSuffix("/") { p = p.dropLast() }
        if p == "/" { return "" }
        if let slash = p.lastIndex(of: "/") { return String(p[p.index(after: slash)...]) }
        return String(p)
    }

    /// Extension of the last component including the dot ("" for none and for dotfiles such as ".bashrc").
    public static func extname(_ path: String) -> String {
        let name = basename(path)
        guard name != "..", let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[dot...])
    }

    /// True for Windows absolute forms ("C:\x", "C:/x", "\x", "\\server\share"), which project paths must reject.
    public static func isWindowsAbsolute(_ path: String) -> Bool {
        let c = Array(path.unicodeScalars)
        guard let first = c.first else { return false }
        if first == "/" || first == "\\" { return true }
        return c.count >= 3 && first.isASCII && CharacterSet.letters.contains(first) && c[1] == ":" && (c[2] == "/" || c[2] == "\\")
    }

    static func components(_ path: String) -> [String] { path.split(separator: "/").map(String.init) }

    static func collapse(_ path: String, allowAboveRoot: Bool) -> [String] {
        var out: [String] = []
        for part in components(path) where part != "." {
            if part == ".." {
                if let last = out.last, last != ".." { out.removeLast() } else if allowAboveRoot { out.append("..") }
            } else { out.append(part) }
        }
        return out
    }
}
