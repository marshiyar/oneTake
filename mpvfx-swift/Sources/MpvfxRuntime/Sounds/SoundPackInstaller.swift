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
// Installs a sound pack by choosing its folder: the folder is copied file by file into a staging folder inside
// `<userData>/sound-packs/` (each file and folder synced), checked there as a whole, and only then renamed to
// `<id>.mpvfxsounds`. Anything that goes wrong leaves no folder the catalogue lists: staging folders start with a dot.
import Foundation

public struct SoundPackInstallError: Error, Equatable, CustomStringConvertible, Sendable {
    public enum Reason: Equatable, Sendable {
        case notAPack, alreadyInstalled, unsupportedEntry, copyFailed, verificationFailed
    }
    public var reason: Reason
    public var message: String
    public var issues: [SoundPackIssue] = []
    public var description: String { message }
}

public enum SoundPackInstaller {
    static let stagingPrefix = ".installing-"
    /// A staging folder older than this is the leftover of an install that died; the next install removes it.
    static let staleStagingSeconds: Double = 24 * 3600

    /// Copies the pack at `source` into `soundPacksDir` and returns the installed pack's report. `afterCopy` runs once
    /// every file is copied and before the pack is checked and published (tests interrupt the install there).
    @discardableResult
    public static func install(from source: String, into soundPacksDir: String, durableWrite: DurableWrite,
                               afterCopy: () throws -> Void = {}) throws -> SoundPackReport {
        let first = SoundPackReader.read(folder: source, checks: .full)
        guard first.state != .invalid else {
            throw SoundPackInstallError(reason: .notAPack, message: "This folder is not a sound pack: \(first.issues.first?.message ?? "pack.json is unreadable").",
                                        issues: first.issues)
        }
        try ProjectFS.mkdirRecursive(soundPacksDir)
        removeStaleStaging(in: soundPacksDir)
        let final = PosixPath.join(soundPacksDir, "\(first.id).\(soundPackFolderExtension)")
        if try ProjectFS.entry(final) != nil {
            throw SoundPackInstallError(reason: .alreadyInstalled, message: "A sound pack named \"\(first.id)\" is already installed.")
        }
        let staging = try ProjectFS.makeTemporaryDirectory(PosixPath.join(soundPacksDir, stagingPrefix))
        do {
            try copyTree(from: source, to: staging, durableWrite: durableWrite)
            try afterCopy()
            let staged = SoundPackReader.read(folder: staging, checks: .full)
            guard staged.state == first.state, staged.items.count == first.items.count else {
                throw SoundPackInstallError(reason: .verificationFailed, message: "The copy of \"\(first.id)\" does not match the original; nothing was installed.",
                                            issues: staged.issues)
            }
            try ProjectFS.syncDirectory(staging, durableWrite)
            try ProjectFS.rename(staging, final)
            try ProjectFS.syncDirectory(soundPacksDir, durableWrite)
        } catch {
            discard(staging)
            throw wrap(error, packId: first.id)
        }
        return SoundPackReader.read(folder: final, checks: .full)
    }

    private static func wrap(_ error: Error, packId: String) -> Error {
        if error is SoundPackInstallError { return error }
        let detail = (error as? ProjectFSError).map { "\($0.code) on \(PosixPath.basename($0.path))" } ?? "\(error)"
        return SoundPackInstallError(reason: .copyFailed, message: "Installing \"\(packId)\" failed (\(detail)); nothing was installed.")
    }

    /// Copies folders and regular files only; a symbolic link or special file in a pack is refused.
    private static func copyTree(from source: String, to destination: String, durableWrite: DurableWrite) throws {
        for name in try ProjectFS.readdir(source).sorted() {
            let from = PosixPath.join(source, name), to = PosixPath.join(destination, name)
            guard let info = try ProjectFS.entry(from) else { continue }
            if info.isDirectory {
                try ProjectFS.mkdir(to)
                try copyTree(from: from, to: to, durableWrite: durableWrite)
                try ProjectFS.syncDirectory(to, durableWrite)
            } else if info.isFile {
                try copyFileExclusiveStreaming(from, to)
                try ProjectFS.fsyncFile(to)
            } else {
                throw SoundPackInstallError(reason: .unsupportedEntry, message: "\"\(name)\" is a link or special file; a sound pack holds only folders and files.")
            }
        }
    }

    private static func removeStaleStaging(in directory: String) {
        let now = Date().timeIntervalSince1970
        do {
            for name in try ProjectFS.readdir(directory) where name.hasPrefix(stagingPrefix) {
                let path = PosixPath.join(directory, name)
                guard let info = try ProjectFS.entry(path), info.isDirectory else { continue }
                if now - Double(info.mtimeNs) / 1e9 > staleStagingSeconds { discard(path) }
            }
        } catch {
            // Tidying is best effort: a folder that can't be listed here fails the install itself at the next step.
            return
        }
    }

    /// Removes a staging folder; a failure leaves a dot-folder the catalogue never lists and the next install retries.
    private static func discard(_ path: String) {
        do { try FileManager.default.removeItem(atPath: path) } catch { return }
    }
}
