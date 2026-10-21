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
// Media import policy: which file extensions and MIME types import as video, audio or image.
import Foundation

/// The media kinds of SUPPORTED_MEDIA_IMPORT_EXTENSIONS, in the table's key order.
public enum MediaImportKind: String, CaseIterable, Codable, Sendable { case video, audio, image, font, lut }

/// SUPPORTED_MEDIA_IMPORT_EXTENSIONS (ordered: kind order and extension order are part of the contract).
/// An array of pairs rather than KeyValuePairs, which is not Sendable.
public let SUPPORTED_MEDIA_IMPORT_EXTENSIONS: [(key: MediaImportKind, value: [String])] = [
    (.video, ["mp4", "m4v", "mov", "webm"]),
    (.audio, ["mp3", "wav", "ogg", "m4a", "aac"]),
    (.image, ["jpg", "jpeg", "png", "gif", "webp", "avif", "svg", "ico"]),
    (.font, ["woff", "woff2", "ttf", "ttc", "otf", "eot"]),
    (.lut, ["cube"]),
]

public func supportedMediaImportExtensions(_ kind: MediaImportKind) -> [String] {
    SUPPORTED_MEDIA_IMPORT_EXTENSIONS.first { $0.key == kind }!.value
}

private let MIME_BY_EXTENSION: [String: String] = [
    "mp4": "video/mp4", "m4v": "video/mp4", "mov": "video/quicktime", "webm": "video/webm", "mkv": "video/x-matroska",
    "avi": "video/x-msvideo", "mxf": "video/mxf", "mts": "video/mp2t", "m2ts": "video/mp2t", "ts": "video/mp2t",
    "mp3": "audio/mpeg", "wav": "audio/wav", "ogg": "audio/ogg", "m4a": "audio/mp4", "aac": "audio/aac",
    "flac": "audio/flac", "opus": "audio/ogg",
    "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "webp": "image/webp",
    "avif": "image/avif", "svg": "image/svg+xml", "ico": "image/x-icon",
    "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "ttc": "font/collection", "otf": "font/otf",
    "eot": "application/vnd.ms-fontobject",
    "cube": "text/plain; charset=utf-8",
]

/// The extension lists have no duplicate extensions, so a dictionary is an exact lookup.
/// (A plain JS object lookup `MIME_BY_EXTENSION[extension]` would also hit Object.prototype keys such as
/// "constructor"; that cannot reach a result here because KIND_BY_EXTENSION, a Map, is checked first in
/// inspectMediaImportFile. preferredMediaImportMimeType is the exception: docs/IMPLEMENTATION_NOTES.md.)
private let KIND_BY_EXTENSION: [String: MediaImportKind] = Dictionary(uniqueKeysWithValues:
    SUPPORTED_MEDIA_IMPORT_EXTENSIONS.flatMap { kind, exts in exts.map { ($0, kind) } })

private let MAIN_LIBRARY_KINDS: [MediaImportKind] = [.video, .audio, .image, .font]

public enum MediaImportRejectionReason: String, Codable {
    case emptyFile = "empty-file", unsupportedExtension = "unsupported-extension", mimeTypeMismatch = "mime-type-mismatch"
}

public enum MediaImportInspection: Equatable {
    case accepted(kind: MediaImportKind, extension: String, preferredMimeType: String)
    case rejected(reason: MediaImportRejectionReason)
}

/// `MediaImportFileLike` { name, type, size } (the subset of a picked file the policy reads).
public protocol MediaImportFileLike {
    var name: String { get }
    var type: String { get }
    var size: Double { get }
}

public struct MediaImportFile: MediaImportFileLike, Equatable {
    public var name: String; public var type: String; public var size: Double
    public init(name: String, type: String, size: Double) { self.name = name; self.type = type; self.size = size }
}

/// JS String.prototype.toLowerCase (full Unicode, locale-independent) on the extension.
// jsToLowerCase lives in JSStringParity.swift (ECMA-262 toLowerCase incl. Final_Sigma).

private func extensionFromPath(_ path: String) -> String? {
    // Import names are filesystem paths. A literal '?' or '#' is part of the name.
    // UTF-16 offsets, as JS lastIndexOf/slice use (a '.' followed by a combining mark is still found).
    let clean = Array(path.utf16).map { $0 == 0x5C ? 0x2F : $0 }   // replace(/\\/g, "/")
    let slash = clean.lastIndex(of: 0x2F).map { $0 + 1 } ?? 0
    let name = Array(clean[slash...])
    guard let dot = name.lastIndex(of: 0x2E), dot > 0, dot != name.count - 1 else { return nil }
    return jsToLowerCase(String(decoding: name[(dot + 1)...], as: UTF16.self))
}

public func classifyMediaImportPath(_ path: String) -> MediaImportKind? {
    guard let ext = extensionFromPath(path), !ext.isEmpty else { return nil }
    return KIND_BY_EXTENSION[ext]
}

public func isImportableMediaPath(_ path: String) -> Bool {
    let kind = classifyMediaImportPath(path)
    return kind == .video || kind == .audio || kind == .image
}

public func preferredMediaImportMimeType(_ path: String) -> String? {
    guard let ext = extensionFromPath(path), !ext.isEmpty else { return nil }
    return MIME_BY_EXTENSION[ext]
}

private func mimeMatchesKind(_ mimeType: String, _ kind: MediaImportKind) -> Bool {
    let lowered = jsToLowerCase(jsTrim(mimeType))
    let mime = lowered.components(separatedBy: ";").first ?? ""   // split(";", 1)[0]
    if mime.isEmpty || mime == "application/octet-stream" { return true }
    switch kind {
    case .video: return mime.hasPrefix("video/") || mime == "application/x-matroska" || mime == "application/mxf"
    case .audio: return mime.hasPrefix("audio/")
    case .image: return mime.hasPrefix("image/")
    case .font:
        return mime.hasPrefix("font/") || mime.hasPrefix("application/font") || mime.hasPrefix("application/x-font-")
            || mime == "application/vnd.ms-fontobject"
    case .lut: return mime == "text/plain" || mime == "application/x-cube"
    }
}

public func inspectMediaImportFile(_ file: MediaImportFileLike) -> MediaImportInspection {
    if file.size == 0 { return .rejected(reason: .emptyFile) }   // JS `=== 0`: -0 too
    let ext = extensionFromPath(file.name)
    guard let ext, !ext.isEmpty, let kind = KIND_BY_EXTENSION[ext] else { return .rejected(reason: .unsupportedExtension) }
    if !mimeMatchesKind(file.type, kind) { return .rejected(reason: .mimeTypeMismatch) }
    return .accepted(kind: kind, extension: ext, preferredMimeType: MIME_BY_EXTENSION[ext] ?? "application/octet-stream")
}

public struct MediaImportPartition<T> {
    public var accepted: [(file: T, kind: MediaImportKind, extension: String)]
    public var rejected: [(file: T, reason: MediaImportRejectionReason)]
}

public func partitionMediaImportFiles<S: Sequence>(_ files: S) -> MediaImportPartition<S.Element> where S.Element: MediaImportFileLike {
    var result = MediaImportPartition<S.Element>(accepted: [], rejected: [])
    for file in files {
        switch inspectMediaImportFile(file) {
        case let .accepted(kind, ext, _): result.accepted.append((file, kind, ext))
        case let .rejected(reason): result.rejected.append((file, reason))
        }
    }
    return result
}
