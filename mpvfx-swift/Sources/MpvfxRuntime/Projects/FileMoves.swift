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
// File moves inside a project (rename, delete to the recovery folder), checked against the version the caller
// saw. Publishing a file exclusively lives in Media/PublishFile.swift.
import Foundation
import MpvfxShared

/// One file move (ProjectFileMove).
public struct ProjectFileMove: Equatable, Sendable {
    public var from: String, to: String, expectedVersion: String
    public init(from: String, to: String, expectedVersion: String) { self.from = from; self.to = to; self.expectedVersion = expectedVersion }
    /// JSON in its fixed key order.
    public var jsonValue: NativeJSONValue { .object(["from": .string(from), "to": .string(to), "expectedVersion": .string(expectedVersion)]) }
}

/// `Error` with a message. `.conflict`: a file is not what the caller last saw (edited elsewhere), so nothing was
/// written; callers branch on `kind`, never on the message, which is free to change.
public struct ProjectsError: Error, Equatable, CustomStringConvertible {
    public enum Kind: Sendable { case failure, conflict }
    public let message: String
    public let kind: Kind
    public init(_ message: String, kind: Kind = .failure) { self.message = message; self.kind = kind }
    public var description: String { message }
}

/// Message of any error (`error.message`, else its description).
public func projectsErrorMessage(_ error: Error) -> String {
    switch error {
    case let e as ProjectsError: return e.message
    case let e as ProjectFSError: return e.message
    default: return "\(error)"
    }
}

enum FileMoveDigests {
    static let limit = 256
    static let lock = NSLock()
    nonisolated(unsafe) static var cache: [String: String] = [:]
    nonisolated(unsafe) static var order: [String] = []
    /// Test counter: number of full hashes computed (fileMoves.versionCache.test counts createHash calls).
    nonisolated(unsafe) static var hashCount = 0

    static func get(_ k: String) -> String? { lock.withLock { cache[k] } }
    /// cacheDigest: re-inserting moves a key to the newest position; oldest evicted past the limit.
    static func put(_ k: String, _ v: String) {
        lock.withLock {
            if cache[k] != nil { order.removeAll { $0 == k } }
            cache[k] = v; order.append(k)
            if order.count > limit { cache[order.removeFirst()] = nil }
        }
    }
}

let RACY_WINDOW_NS: Int128 = 100_000_000
let COARSE_RACY_WINDOW_NS: Int128 = 2_000_000_000

func wallClockNs() -> Int128 { Int128((Date().timeIntervalSince1970 * 1000).rounded(.down)) * 1_000_000 }

/// isRacy.
func isRacy(_ info: FileInfo, _ hashStartedNs: Int128) -> Bool {
    let newest = info.mtimeNs > info.ctimeNs ? info.mtimeNs : info.ctimeNs
    let wholeSeconds = info.mtimeNs % 1_000_000_000 == 0 && info.ctimeNs % 1_000_000_000 == 0
    return newest + (wholeSeconds ? COARSE_RACY_WINDOW_NS : RACY_WINDOW_NS) >= hashStartedNs
}

let unsafeMovePath = "Unsafe media move path: a project-relative file path is required"

/// validateMovePath. Takes untyped JSON (a non-string path is refused).
@discardableResult
public func validateMovePath(_ value: NativeJSONValue?) throws -> String {
    guard case .string(let path)? = value else { throw ProjectsError(unsafeMovePath) }
    return try validateMovePath(path)
}

@discardableResult
public func validateMovePath(_ path: String) throws -> String {
    // `/[\\\0-\x1f]/`
    if path.isEmpty || PosixPath.isAbsolute(path) || path.utf16.contains(where: { $0 == 0x5C || $0 <= 0x1F })
        || path.components(separatedBy: "/").contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
        throw ProjectsError(unsafeMovePath)
    }
    let parts = path.components(separatedBy: "/")
    if jsToLowerCase(parts[0]) == ".hyperframes" &&
        !(parts.count >= 4 && parts[0] == ".hyperframes" && parts[1] == "deleted-media" && isTransactionId(parts[2])) {
        throw ProjectsError("Reserved media move path")
    }
    return path
}

/// `/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/` (ID_PATTERN, shared with FileTransaction).
func isTransactionId(_ s: String) -> Bool {
    let u = Array(s.utf16)
    guard (1...128).contains(u.count) else { return false }
    func alnum(_ c: UInt16) -> Bool { (0x30...0x39).contains(c) || (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c) }
    return alnum(u[0]) && u.dropFirst().allSatisfy { alnum($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x3A || $0 == 0x2D }
}

/// resolveMovePath: rejects symlinked parents and non-file targets.
/// `durableWrite` is required when `createParents` is true (it syncs each created folder's parent).
public func resolveMovePath(_ root: String, _ path: String, createParents: Bool = false, durableWrite: DurableWrite? = nil) throws -> String {
    try validateMovePath(path)
    let parts = path.components(separatedBy: "/")
    var parent = root
    for part in parts.dropLast() {
        let next = PosixPath.join(parent, part)
        var info = try ProjectFS.entry(next)
        if info == nil && createParents {
            do { try ProjectFS.mkdir(next) } catch let e as ProjectFSError where e.code == "EEXIST" {}
            if let durableWrite { try ProjectFS.syncDirectory(parent, durableWrite) }
            info = try ProjectFS.entry(next)
        }
        guard let info else { return PosixPath.join(root, path) }
        if info.isSymbolicLink || !info.isDirectory { throw ProjectsError("Unsafe media move parent: \(path)") }
        parent = next
    }
    let target = PosixPath.join(root, path)
    if let info = try ProjectFS.entry(target), !info.isFile || info.isSymbolicLink {
        throw ProjectsError("Unsafe media move target: \(path)")
    }
    return target
}

/// binaryFileVersion: SHA-256 hex of the file's bytes, read incrementally; nil when missing.
public func binaryFileVersion(_ root: String, _ path: String) throws -> String? {
    let target = try resolveMovePath(root, path)
    let file: NativeFile
    do { file = try NativeFile.openRead(target, noFollow: true) } catch where isMissing(error) { return nil }
    defer { file.close() }
    func fstatInfo() throws -> FileInfo { try file.info(path: target) }
    let hashStartedNs = wallClockNs()
    let before = try fstatInfo()
    if !before.isFile { throw ProjectsError("Unsafe media move target: \(path)") }
    let fingerprint = before.fingerprint
    var digest = FileMoveDigests.get(fingerprint)
    if digest == nil {
        FileMoveDigests.lock.withLock { FileMoveDigests.hashCount += 1 }
        var hasher = SHA256Hasher()
        try file.forEachChunk(path: target) { hasher.update($0) }
        digest = hasher.finalizeHex()
    }
    let after = try fstatInfo()
    let current = try ProjectFS.entry(target)
    guard let current, current.isFile, !current.isSymbolicLink,
          after.fingerprint == fingerprint, current.fingerprint == fingerprint else {
        throw ProjectsError("Media \(path) changed before commit", kind: .conflict)
    }
    if !isRacy(before, hashStartedNs) { FileMoveDigests.put(fingerprint, digest!) }
    return digest
}

/// normalizeFileMoves over untyped JSON. nil for undefined.
public func normalizeFileMoves(_ moves: NativeJSONValue?) throws -> [ProjectFileMove]? {
    guard let moves else { return nil }
    guard case .array(let list) = moves else { throw ProjectsError("Transaction moves must be an array") }
    return try list.map { move in
        // `!move || typeof move.expectedVersion !== "string" || !/^[a-f0-9]{64}$/.test(...)`
        guard case .string(let v)? = move["expectedVersion"], v.utf8.count == 64,
              v.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
            throw ProjectsError("Media move requires an exact SHA256 expectedVersion")
        }
        return ProjectFileMove(from: try validateMovePath(move["from"]), to: try validateMovePath(move["to"]), expectedVersion: v)
    }
}

public enum FileMoveState: String { case before, linked, copied, after }

/// inspectFileMove.
public func inspectFileMove(_ root: String, _ move: ProjectFileMove) throws -> FileMoveState {
    let from = try binaryFileVersion(root, move.from)
    let to = try binaryFileVersion(root, move.to)
    if from == move.expectedVersion && to == nil { return .before }
    if from == nil && to == move.expectedVersion { return .after }
    if from == move.expectedVersion && to == move.expectedVersion {
        let a = try ProjectFS.lstatInfo(PosixPath.join(root, move.from))
        let b = try ProjectFS.lstatInfo(PosixPath.join(root, move.to))
        if a.ino == b.ino && a.dev == b.dev { return .linked }
        return .copied
    }
    throw ProjectsError("Media move \(move.from) → \(move.to) changed before commit or recovery", kind: .conflict)
}

// publishFileExclusive lives in Media/PublishFile.swift.

public enum FileMoveDirection { case forward, rollback }

/// applyFileMove.
public func applyFileMove(_ root: String, _ move: ProjectFileMove, _ direction: FileMoveDirection,
                          durableWrite: DurableWrite, afterLink: (() throws -> Void)? = nil) throws {
    let state = try inspectFileMove(root, move)
    if (direction == .forward && state == .after) || (direction == .rollback && state == .before) { return }
    let source = direction == .forward ? move.from : move.to
    let destination = direction == .forward ? move.to : move.from
    let from = try resolveMovePath(root, source)
    let to = try resolveMovePath(root, destination, createParents: true, durableWrite: durableWrite)
    if state != .linked && state != .copied {
        try publishFileExclusive(from, to)
        try ProjectFS.syncDirectory(PosixPath.dirname(to), durableWrite)
        try afterLink?()
    }
    let published = try inspectFileMove(root, move)
    if published != .linked && published != .copied { throw ProjectsError("Media move \(source) changed before commit", kind: .conflict) }
    try ProjectFS.unlink(from)
    try ProjectFS.syncDirectory(PosixPath.dirname(from), durableWrite)
}
