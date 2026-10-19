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
// The project's media as the assets panel shows it: every media and font file in the project folder,
// grouped by category, with the optional `.media/manifest.jsonl` facts (description, duration, size),
// whether the open document uses it, and a search over name and description.
import Foundation
import MpvfxShared

public enum ProjectMediaCategory: String, CaseIterable, Sendable {
    case audio, images, video, fonts
    /// Panel order.
    public static let order: [ProjectMediaCategory] = [.audio, .images, .video, .fonts]
}

public struct ProjectMediaEntry: Equatable, Sendable {
    /// Project-relative path.
    public var path: String
    public var name: String
    public var category: ProjectMediaCategory
    public var size: Int64
    /// Modification time, seconds since 1970.
    public var modified: Double
    /// True when a document asset points at this file.
    public var used: Bool
    public var description: String?
    public var duration: Double?
    public var width: Double?
    public var height: Double?
}

/// Generated, recovery or tool directories that never hold the user's media.
let PROJECT_MEDIA_EXCLUDED_DIRECTORIES: Set<String> = [
    ".studio", ".build", ".git", ".thumbnails", ".transcode-cache", ".media", ".waveform-cache",
    "renders", "dist", "desktop-dist", "out",
]

public enum ProjectMediaCatalog {
    public static func category(of name: String) -> ProjectMediaCategory? {
        guard let kind = ImportFormats.kind(of: name) else { return nil }
        switch kind {
        case .audio: return .audio
        case .image: return .images
        case .video: return .video
        case .font: return .fonts
        case .lut: return nil
        }
    }

    /// `.media/manifest.jsonl`: one JSON object per line keyed by `path`; unreadable lines are skipped.
    public static func manifest(_ projectDir: String) -> [String: NativeJSONObject] {
        guard let text = try? String(contentsOfFile: PosixPath.join(projectDir, ".media/manifest.jsonl"), encoding: .utf8) else { return [:] }
        var out: [String: NativeJSONObject] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let rec = (try? NativeJSONValue.parse(String(line)))?.objectValue, let path = rec["path"]?.stringValue, !path.isEmpty else { continue }
            out[path] = rec
        }
        return out
    }

    /// Relative paths of every media/font file under the project (symlinks and excluded folders skipped).
    public static func mediaFiles(_ projectDir: String) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        func walk(_ relative: String) {
            let abs = relative.isEmpty ? projectDir : PosixPath.join(projectDir, relative)
            guard let names = try? fm.contentsOfDirectory(atPath: abs) else { return }
            for name in names.sorted() {
                if name.hasPrefix(".mpvfx-") { continue }   // in-flight import/attach staging
                let rel = relative.isEmpty ? name : relative + "/" + name
                guard let info = try? ProjectFS.lstatInfo(PosixPath.join(projectDir, rel)) else { continue }
                if info.isDirectory {
                    if relative.isEmpty && (PROJECT_MEDIA_EXCLUDED_DIRECTORIES.contains(name.lowercased()) || name.lowercased() == JOURNAL_PARENT) { continue }
                    if name.hasPrefix(".") { continue }
                    walk(rel)
                } else if info.isFile, category(of: name) != nil {
                    out.append(rel)
                }
            }
        }
        walk("")
        return out
    }

    /// The panel listing. `query` matches file names and manifest descriptions, case-insensitively.
    /// Within each category used files come first, then by path.
    public static func list(_ projectDir: String, document: NativeProjectDocument?, query: String? = nil) -> [ProjectMediaEntry] {
        let manifest = manifest(projectDir)
        let used = Set(document?.assets.compactMap { $0.source.map { PosixPath.normalize($0) } } ?? [])
        let q = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        var entries: [ProjectMediaEntry] = []
        for path in mediaFiles(projectDir) {
            let name = PosixPath.basename(path)
            let rec = manifest[path]
            let description = rec?["description"]?.stringValue
            if !q.isEmpty && !name.lowercased().contains(q) && !(description?.lowercased().contains(q) ?? false) { continue }
            let info = try? ProjectFS.statInfo(PosixPath.join(projectDir, path))
            func num(_ k: String) -> Double? { if case .number(let n)? = rec?[k] { return n }; return nil }
            entries.append(ProjectMediaEntry(path: path, name: name, category: category(of: name)!, size: Int64(info?.size ?? 0),
                                             modified: Double(info?.mtimeNs ?? 0) / 1e9, used: used.contains(path),
                                             description: description, duration: num("duration"), width: num("width"), height: num("height")))
        }
        let rank = Dictionary(uniqueKeysWithValues: ProjectMediaCategory.order.enumerated().map { ($1, $0) })
        return entries.sorted {
            if $0.category != $1.category { return rank[$0.category]! < rank[$1.category]! }
            if $0.used != $1.used { return $0.used }
            return $0.path < $1.path
        }
    }
}
