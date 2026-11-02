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
// Project templates (#332): a project saved without its media, whose marked clips (placeholders) a new project fills.
// A template is a folder under `<userData>/templates/<id>/` holding `template.json` (name, description, its slots and
// fonts), `.studio/project.json` (the document, placeholders referencing no file) and the project's `.cube` LUTs.
// Text and shapes live in the document itself.
import Foundation
import MpvfxShared

/// One placeholder of a template, as the "new from template" sheet lists it.
public struct ProjectTemplateSlot: Codable, Equatable, Sendable {
    public var index: Int
    public var label: String?
    /// `video`, `audio` or `image`: what the slot takes.
    public var kind: String
    /// The slot's length on the timeline, in project frames.
    public var durationFrames: Double
}

/// A template's `template.json`.
public struct ProjectTemplate: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var v: Int = ProjectTemplate.currentVersion
    public var id: String
    public var name: String
    public var description: String?
    /// Seconds since 1970.
    public var createdAt: Double
    public var slots: [ProjectTemplateSlot]
    /// The font families the template's text uses, so a missing one can be named when the template is used.
    public var fonts: [String]

    /// The template's fonts that `isInstalled` does not know.
    public func missingFonts(isInstalled: (String) -> Bool) -> [String] { fonts.filter { !isInstalled($0) } }
}

public struct ProjectTemplateError: Error, Equatable, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// The user's templates. Every write goes through the durable write path; a template folder appears whole or not at all.
public struct ProjectTemplateStore: Sendable {
    /// `<userData>/templates`.
    public let directory: String
    let durableWrite: DurableWrite

    public init(userData: String, durableWrite: DurableWrite) {
        directory = PosixPath.join(userData, "templates")
        self.durableWrite = durableWrite
    }

    func folder(_ id: String) -> String { PosixPath.join(directory, id) }

    /// The templates on disk, by name. A folder whose `template.json` cannot be read is left alone and not listed.
    public func list() -> [ProjectTemplate] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.compactMap { try? metadata($0) }
            .sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }

    func metadata(_ id: String) throws -> ProjectTemplate {
        let data = try ProjectFS.readData(PosixPath.join(folder(id), "template.json"))
        let template = try JSONDecoder().decode(ProjectTemplate.self, from: data)
        guard template.v == ProjectTemplate.currentVersion, template.id == id else {
            throw ProjectTemplateError("Template \(id) was written by another version of the editor")
        }
        return template
    }

    /// Saves `document` (the open project's, in `projectDirectory`) as a template. Media files are not copied: the
    /// placeholders' assets lose their file, and only the project's `.cube` LUTs come along. The folder is built beside
    /// the others and moved into place, so a failure leaves nothing behind.
    @discardableResult
    public func save(projectDirectory: String, document: NativeProjectDocument, name: String, description: String? = nil,
                     now: Date = Date()) throws -> ProjectTemplate {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ProjectTemplateError("Enter a name for the template") }
        let note = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID().uuidString.lowercased()
        let template = ProjectTemplate(id: id, name: title, description: (note?.isEmpty ?? true) ? nil : note,
                                       createdAt: now.timeIntervalSince1970, slots: Self.slots(document), fonts: Self.fonts(document))
        let staging = PosixPath.join(directory, ".saving-\(UUID().uuidString.lowercased())")
        do {
            try ProjectFS.mkdirRecursive(PosixPath.join(staging, ".studio"))
            try write(try serializeNativeProjectDocument(Self.withoutPlaceholderMedia(document, id: id, name: title)),
                      to: PosixPath.join(staging, NATIVE_PROJECT_DOCUMENT_PATH))
            for lut in Self.luts(in: projectDirectory) {
                let target = PosixPath.join(staging, lut)
                try ProjectFS.mkdirRecursive(PosixPath.dirname(target))
                try FileManager.default.copyItem(atPath: PosixPath.join(projectDirectory, lut), toPath: target)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try write(String(decoding: try encoder.encode(template), as: UTF8.self) + "\n", to: PosixPath.join(staging, "template.json"))
            try FileManager.default.moveItem(atPath: staging, toPath: folder(id))
            try? durableWrite.syncDirectory(directory)
        } catch {
            try? FileManager.default.removeItem(atPath: staging)
            throw error
        }
        return template
    }

    public func delete(id: String) throws {
        _ = try metadata(id)   // only a template folder is ever removed
        try FileManager.default.removeItem(atPath: folder(id))
    }

    /// Creates the project folder `directory` (which must not exist) from a template: its document with a new id, its
    /// LUTs, and the placeholders `fill` supplies media for. `fill` runs once the folder exists, so it can copy the
    /// media in, and returns each filled placeholder's asset by number; placeholders it leaves out stay marked. If any
    /// step fails, the folder is removed. Returns the document written.
    @discardableResult
    public func createProject(templateId: String, name: String, at directory: String,
                              fill: (_ projectDirectory: String) throws -> [Int: NativeProjectAsset] = { _ in [:] }) throws -> String {
        _ = try metadata(templateId)
        let source = folder(templateId)
        let template = try ProjectDocuments.validate(try ProjectFS.readUTF8(PosixPath.join(source, NATIVE_PROJECT_DOCUMENT_PATH)))
        guard !ProjectFS.exists(directory) else { throw ProjectTemplateError("\(directory) already exists") }
        do {
            try ProjectFS.mkdirRecursive(directory)
            for lut in Self.luts(in: source) {
                let target = PosixPath.join(directory, lut)
                try ProjectFS.mkdirRecursive(PosixPath.dirname(target))
                try FileManager.default.copyItem(atPath: PosixPath.join(source, lut), toPath: target)
            }
            var document = try template.fillingPlaceholders(try fill(directory))
            document.id = UUID().uuidString.lowercased()
            document.revision = 0
            document.sequence.name = name
            let content = try serializeNativeProjectDocument(document)
            let transactions = DurableFileTransactionStore(.init(projectRoot: directory, durableWrite: durableWrite))
            try transactions.commit(DurableFileTransactionInput(id: "create-\(UUID().uuidString.lowercased())", files: [
                DurableFileTransactionChange(path: NATIVE_PROJECT_DOCUMENT_PATH, expectedBefore: nil, after: content),
            ]))
            return content
        } catch {
            try? FileManager.default.removeItem(atPath: directory)
            throw error
        }
    }

    private func write(_ text: String, to path: String) throws {
        try durableWrite.write(Data(text.utf8), to: path, tempName: ".tmp-\(UUID().uuidString.lowercased())", preserveMode: false, beforeRename: {})
    }

    // MARK: What a template holds

    /// The placeholders in number order.
    static func slots(_ document: NativeProjectDocument) -> [ProjectTemplateSlot] {
        let assets = Dictionary(document.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return document.sequence.tracks.flatMap(\.clips).compactMap { clip -> ProjectTemplateSlot? in
            guard let number = clip.placeholder?.number else { return nil }
            return ProjectTemplateSlot(index: number, label: clip.placeholder?.label, kind: assets[clip.assetId]?.kind.rawValue ?? "video",
                                       durationFrames: clip.durationFrames)
        }.sorted { $0.index < $1.index }
    }

    /// The font families of the document's text clips, sorted.
    static func fonts(_ document: NativeProjectDocument) -> [String] {
        Array(Set(document.sequence.tracks.flatMap(\.clips).compactMap { $0.text?.fontFamily }.filter { !$0.isEmpty })).sorted()
    }

    /// The document as a template stores it: placeholder assets reference no file (unless an unmarked clip uses the
    /// same asset), and it has the template's id.
    static func withoutPlaceholderMedia(_ document: NativeProjectDocument, id: String, name: String) -> NativeProjectDocument {
        var d = document
        let clips = d.sequence.tracks.flatMap(\.clips)
        let marked = Set(clips.filter { $0.placeholder?.isCurrentVersion == true }.map(\.assetId))
        let shared = Set(clips.filter { $0.placeholder?.isCurrentVersion != true }.map(\.assetId))
        for i in d.assets.indices where marked.contains(d.assets[i].id) && !shared.contains(d.assets[i].id) { d.assets[i].source = nil }
        d.id = id
        d.revision = 0
        return d
    }

    /// Project-relative paths of the `.cube` LUTs under `root`, hidden folders and the renders folder left out.
    static func luts(in root: String) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
        var found: [String] = []
        for case let relative as String in walker {
            let top = relative.split(separator: "/").first.map(String.init) ?? relative
            if top.hasPrefix(".") || top == "renders" { walker.skipDescendants(); continue }
            if relative.lowercased().hasSuffix(".cube") { found.append(relative) }
        }
        return found.sorted()
    }
}
