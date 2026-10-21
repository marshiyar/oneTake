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
// Caption import and export for an open project: an SRT file into the document's caption track (one journaled save),
// and the caption track out to an SRT file (one durable write).
import Foundation
import MpvfxShared

/// The document after an import, already saved; the editor loads it.
public struct ProjectCaptionImport: Equatable, Sendable {
    public var content: String
    public var cueCount: Int
    public init(content: String, cueCount: Int) { self.content = content; self.cueCount = cueCount }
}

/// The SRT file could not be read (missing, a folder, no permission).
public struct CaptionFileError: Error, Equatable, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public extension ProjectDocumentStore {
    /// Reads the SRT file at `path` and replaces the caption track of `content` (the editor's document) with its cues,
    /// saving the result. All or nothing: a file that does not read in full throws (`CaptionFileError`,
    /// `SRTReadError`) before anything is written, and the save itself is the store's journaled commit.
    func importCaptions(fromSRT path: String, content: String) throws -> ProjectCaptionImport {
        let cues = try SRTReader.read(try readCaptionFile(path))
        var document = try ProjectDocuments.validate(content)
        document.sequence.captions = NativeCaptionTrack(id: document.sequence.captions?.id ?? NATIVE_CAPTION_TRACK_DEFAULT_ID, cues: cues)
        let next = try serializeNativeProjectDocument(document)
        try save(next)
        return ProjectCaptionImport(content: next, cueCount: cues.count)
    }

    /// Writes the caption track of `content` as SRT at `path` (durable write); returns the number of cues written.
    /// Throws `CaptionExportError(.noCaptions)` when the document has none.
    func exportCaptions(toSRT path: String, content: String) throws -> Int {
        let document = try ProjectDocuments.validate(content)
        guard let cues = document.sequence.captions?.cues, !cues.isEmpty else {
            throw CaptionExportError(.noCaptions, "The project has no captions to export")
        }
        try SRTWriter.write(cues, to: path, durableWrite: durableWriter)
        return cues.count
    }
}

/// At most `SRTReader.maxBytes + 1` bytes of the file, so a huge file is refused by the reader without reading it all.
func readCaptionFile(_ path: String) throws -> Data {
    let name = (path as NSString).lastPathComponent
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
        throw CaptionFileError("\(name) was not found, or it is a folder")
    }
    do {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        let data: Data?
        do { data = try handle.read(upToCount: SRTReader.maxBytes + 1) } catch { try handle.close(); throw error }
        try handle.close()
        guard let data else { return Data() }   // nil: the file is empty
        return data
    } catch {
        throw CaptionFileError("\(name) could not be read: \(error.localizedDescription)")
    }
}
