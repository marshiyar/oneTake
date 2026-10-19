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
// Native project documents on disk: create, open and save `<project>/.studio/project.json`.
// Saves are journaled through DurableFileTransactionStore (crash-safe, conflict-checked against the
// content this process last read or wrote), so a save never silently overwrites an external edit.
import Foundation
import MpvfxShared

/// The document text of an open project and where it lives.
public struct OpenedProjectDocument: Equatable, Sendable {
    public var id: String
    public var directory: String
    public var content: String
    public init(id: String, directory: String, content: String) { self.id = id; self.directory = directory; self.content = content }
}

public struct ProjectDocumentError: Error, Equatable, CustomStringConvertible, Sendable {
    public enum Kind: String, Sendable { case notAProject, alreadyExists, invalidDocument, conflict }
    public var kind: Kind
    public var message: String
    public init(_ kind: Kind, _ message: String) { self.kind = kind; self.message = message }
    public var description: String { message }
}

public enum ProjectDocuments {
    /// The starter document of every new project (the standalone project, a library project, `ProjectDocumentStore.create`):
    /// 1920x1080 at 30 fps, black canvas, empty main sequence named `name`.
    public static func starterDocument(id: String, name: String) throws -> String {
        let doc = try NativeJSONValue.parse("""
        {"schemaVersion":1,"mediaEngine":"native","id":\(jsJSONStringify(.string(id))),"revision":0,\
        "frameRate":{"numerator":30,"denominator":1},"canvas":{"width":1920,"height":1080,"background":"#000000"},"assets":[],\
        "sequence":{"id":"sequence:main","name":\(jsJSONStringify(.string(name))),"durationFrames":150,"tracks":[]}}
        """)
        return try serializeNativeProjectDocument(doc)
    }

    /// Writes the starter document to `<projectRoot>/.studio/project.json` (`projectRoot` must exist) as one journaled
    /// transaction that expects no document there. Returns the document written, or nil when a document already
    /// exists: that document is kept as it is. A creation interrupted by a crash is rolled back first.
    public static func createStarter(projectRoot: String, id: String, name: String, durableWrite: DurableWrite) throws -> String? {
        let content = try starterDocument(id: id, name: name)
        let transactions = DurableFileTransactionStore(.init(projectRoot: projectRoot, durableWrite: durableWrite))
        _ = try transactions.recover()
        for attempt in 0..<2 {
            let txn = "create-\(UUID().uuidString.lowercased())"
            do {
                try transactions.commit(DurableFileTransactionInput(id: txn, files: [
                    DurableFileTransactionChange(path: NATIVE_PROJECT_DOCUMENT_PATH, expectedBefore: nil, after: content),
                ]))
            } catch let e as ProjectsError where e.kind == .conflict {
                // Refused before the rename: recovery settles a journal left PREPARED and the settled journal is
                // removed. A different document is a conflict there and is kept; identical starter bytes another
                // creator wrote meanwhile look like this transaction's own write and are rolled away, so the
                // starter is written once more.
                _ = try transactions.recover()
                _ = try transactions.acknowledge(txn)
                if attempt == 0, !ProjectFS.exists(PosixPath.join(projectRoot, NATIVE_PROJECT_DOCUMENT_PATH)) { continue }
                return nil
            }
            _ = try? transactions.acknowledge(txn)
            return content
        }
        return nil
    }

    /// A project directory from a path the user picked: the directory itself, its `.studio` folder,
    /// or the `project.json` inside it.
    public static func projectDirectory(for path: String) throws -> String {
        var dir = PosixPath.resolve(path)
        if PosixPath.basename(dir) == "project.json", PosixPath.basename(PosixPath.dirname(dir)) == ".studio" {
            dir = PosixPath.dirname(PosixPath.dirname(dir))
        } else if PosixPath.basename(dir) == ".studio" {
            dir = PosixPath.dirname(dir)
        }
        guard let info = try? ProjectFS.statInfo(PosixPath.join(dir, NATIVE_PROJECT_DOCUMENT_PATH)), info.isFile else {
            throw ProjectDocumentError(.notAProject, "\(path) is not an MpVFX project (no \(NATIVE_PROJECT_DOCUMENT_PATH))")
        }
        return try ProjectFS.realpath(dir)
    }

    /// Validates document text and returns its id.
    public static func validate(_ content: String) throws -> NativeProjectDocument {
        do { return try parseNativeProjectDocument(try NativeJSONValue.parse(content)) }
        catch { throw ProjectDocumentError(.invalidDocument, "The project document is invalid: \(error)") }
    }
}

/// One open project. Not thread-safe by itself: callers serialize saves (the transaction store also
/// holds a per-root lock, so two stores on one directory cannot interleave a commit).
public final class ProjectDocumentStore: @unchecked Sendable {
    public let directory: String
    private let stateLock = NSRecursiveLock()
    private var _id: String
    private var _savedContent: String
    public var id: String { stateLock.withLock { _id } }
    /// What is on disk as far as this store knows: the last content read or committed. Waits for an
    /// in-flight save, so a reader never mistakes this store's own write for an external edit.
    public var savedContent: String { stateLock.withLock { _savedContent } }
    private let transactions: DurableFileTransactionStore
    private let durableWrite: DurableWrite
    var durableWriter: DurableWrite { durableWrite }

    private init(directory: String, id: String, content: String, transactions: DurableFileTransactionStore, durableWrite: DurableWrite) {
        self.directory = directory; self._id = id; self._savedContent = content
        self.transactions = transactions; self.durableWrite = durableWrite
    }

    public var opened: OpenedProjectDocument { OpenedProjectDocument(id: id, directory: directory, content: savedContent) }

    /// Creates `directory` (which must not exist, or be an empty directory) holding a starter document.
    public static func create(at directory: String, name: String, id: String = UUID().uuidString.lowercased(),
                              durableWrite: DurableWrite) throws -> ProjectDocumentStore {
        let dir = PosixPath.resolve(directory)
        if let info = try? ProjectFS.statInfo(dir) {
            guard info.isDirectory, (try ProjectFS.readdir(dir)).isEmpty else {
                throw ProjectDocumentError(.alreadyExists, "\(dir) already exists")
            }
        } else {
            try ProjectFS.mkdirRecursive(dir)
        }
        guard let content = try ProjectDocuments.createStarter(projectRoot: dir, id: id, name: name, durableWrite: durableWrite) else {
            throw ProjectDocumentError(.alreadyExists, "\(dir) already holds a project")
        }
        let transactions = DurableFileTransactionStore(.init(projectRoot: dir, durableWrite: durableWrite))
        return ProjectDocumentStore(directory: try ProjectFS.realpath(dir), id: id, content: content,
                                    transactions: transactions, durableWrite: durableWrite)
    }

    /// Opens an existing project (see `ProjectDocuments.projectDirectory`). An interrupted save left by a
    /// crash is rolled back first, so the document read is always a complete one.
    public static func open(_ path: String, durableWrite: DurableWrite) throws -> ProjectDocumentStore {
        let dir = try ProjectDocuments.projectDirectory(for: path)
        let transactions = DurableFileTransactionStore(.init(projectRoot: dir, durableWrite: durableWrite))
        _ = try transactions.recover()
        let content = try ProjectFS.readUTF8(PosixPath.join(dir, NATIVE_PROJECT_DOCUMENT_PATH))
        let document = try ProjectDocuments.validate(content)
        return ProjectDocumentStore(directory: dir, id: document.id, content: content, transactions: transactions, durableWrite: durableWrite)
    }

    /// Writes `content` as the new document. No-op when it equals what is saved. Throws `.conflict` when
    /// the file changed on disk since it was last read or saved here (nothing is written then).
    public func save(_ content: String) throws {
        stateLock.lock(); defer { stateLock.unlock() }
        if content == savedContent { return }
        let document = try ProjectDocuments.validate(content)
        let txn = "save-\(UUID().uuidString.lowercased())"
        do {
            try transactions.commit(DurableFileTransactionInput(id: txn, files: [
                DurableFileTransactionChange(path: NATIVE_PROJECT_DOCUMENT_PATH, expectedBefore: savedContent, after: content),
            ]))
        } catch let e as ProjectsError where e.kind == .conflict {
            throw ProjectDocumentError(.conflict, "The project file was changed outside MpVFX; it was not overwritten.")
        }
        _ = try? transactions.acknowledge(txn)
        _savedContent = content
        _id = document.id
    }

    /// One journaled edit that writes `content` (which may equal what is saved) together with file moves,
    /// e.g. a media rename or delete with the document's references updated. All or nothing.
    @discardableResult
    public func commit(_ content: String, moves: [ProjectFileMove], label: String) throws -> DurableFileTransactionReceipt {
        stateLock.lock(); defer { stateLock.unlock() }
        let document = try ProjectDocuments.validate(content)
        let txn = "edit-\(UUID().uuidString.lowercased())"
        let files = content == savedContent ? [] : [
            DurableFileTransactionChange(path: NATIVE_PROJECT_DOCUMENT_PATH, expectedBefore: savedContent, after: content),
        ]
        let receipt: DurableFileTransactionReceipt
        do {
            receipt = try transactions.commit(DurableFileTransactionInput(id: txn, files: files,
                history: DurableFileTransactionHistory(label: label, kind: .manual), moves: moves.isEmpty ? nil : moves))
        } catch let e as ProjectsError where e.kind == .conflict {
            throw ProjectDocumentError(.conflict, "The project changed outside MpVFX; nothing was changed.")
        }
        _ = try? transactions.acknowledge(txn)
        _savedContent = content
        _id = document.id
        return receipt
    }

    /// Re-read the document from disk (after a conflict the user chose to take the disk version).
    @discardableResult
    public func reload() throws -> String {
        stateLock.lock(); defer { stateLock.unlock() }
        let content = try ProjectFS.readUTF8(PosixPath.join(directory, NATIVE_PROJECT_DOCUMENT_PATH))
        _id = try ProjectDocuments.validate(content).id
        _savedContent = content
        return content
    }
}
