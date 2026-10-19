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
// Local import: OS-level copying of user-picked files into a project.
import Foundation
import MpvfxShared

public struct LocalMediaImportResult: Codable, Equatable {
    public struct Invalid: Codable, Equatable { public var name: String; public var reason: String }
    public var files: [String] = []
    public var invalid: [Invalid] = []
}

/// Copies each file into the project after checking it against the import formats (ImportFormats: refused
/// extensions first, then the engine's probe of the staged copy for video, audio and stills).
public func importLocalMedia(projectRoot: String, paths: [String], directory: String? = nil, durableWrite: DurableWrite) throws -> LocalMediaImportResult {
    let root = try ProjectFS.realpath(projectRoot)
    let directory = directory ?? ""
    if !directory.isEmpty {
        let parts = directory.components(separatedBy: "/")
        if parts.contains(where: { $0.hasPrefix(".") }) || ["node_modules", "renders"].contains(parts[0]) {
            throw MediaToolError("Invalid import directory")
        }
    }
    var result = LocalMediaImportResult()
    for source in paths {
        let name = PosixPath.basename(source)
        var staging: String?
        do {
            let info = try ProjectFS.statInfo(source)
            if let refusal = ImportFormats.refusal(forName: name) { throw MediaToolError(refusal) }
            guard info.isFile, info.size > 0, let kind = ImportFormats.kind(of: name) else { throw MediaToolError("Unsupported or empty media file") }
            let relative = directory.isEmpty ? name : PosixPath.join(directory, name)
            let destination = try resolveMovePath(root, relative, createParents: true, durableWrite: durableWrite)
            staging = try makeTemporaryDirectory(PosixPath.join(PosixPath.dirname(destination), ".mpvfx-import-"))
            let staged = PosixPath.join(staging!, name)
            try copyFileExclusiveStreaming(source, staged)
            let after = try ProjectFS.statInfo(source)
            if info.size != after.size || info.mtimeNs != after.mtimeNs || info.ino != after.ino || info.dev != after.dev {
                throw MediaToolError("Source file changed during import; try again")
            }
            try ImportFormats.validate(staged, name: name, as: kind)
            let ext = Array(PosixPath.extname(name).utf16)
            let stem = String(decoding: Array(relative.utf16).dropLast(ext.count), as: UTF16.self)
            var index = 0
            while true {
                let candidate = index == 0 ? relative : "\(stem) (\(index + 1))\(String(decoding: ext, as: UTF16.self))"
                let target = try resolveMovePath(root, candidate, createParents: true, durableWrite: durableWrite)
                do {
                    try publishFileExclusive(staged, target)
                    result.files.append(candidate)
                    break
                } catch let e as ProjectFSError where e.code == "EEXIST" {}
                index += 1
            }
        } catch {
            result.invalid.append(.init(name: name, reason: importErrorMessage(error)))
        }
        if let staging { try? FileManager.default.removeItem(atPath: staging) }
    }
    return result
}

/// Node `error.message`. Filesystem errors use Node's "CODE: syscall, 'path'" shape without the strerror text.
func importErrorMessage(_ error: Error) -> String {
    switch error {
    case let e as MediaToolError: return e.message
    case let e as ProjectsError: return e.message
    case let e as ProjectFSError: return "\(e.code): \(e.syscall) '\(e.path)'"
    default: return "Import failed"
    }
}

/// fs.mkdtemp(prefix): prefix + 6 random characters (created 0700 on POSIX).
func makeTemporaryDirectory(_ prefix: String) throws -> String { try ProjectFS.makeTemporaryDirectory(prefix) }
