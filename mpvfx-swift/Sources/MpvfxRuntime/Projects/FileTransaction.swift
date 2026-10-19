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
// Crash-safe multi-file commits with an on-disk journal
// (.hyperframes/studio-transactions/<sha256(id)>.json; the folder name and layout are fixed so existing journals recover).
// The store is synchronous and serializes per project root with a lock
// (see docs/IMPLEMENTATION_NOTES.md). Whole-file target and journal writes go through `DurableWrite`.
import Foundation
import MpvfxShared

// MARK: - Types

public struct DurableFileTransactionChange: Equatable, Sendable {
    public var path: String
    public var expectedBefore: String?
    public var after: String?
    public init(path: String, expectedBefore: String?, after: String?) { self.path = path; self.expectedBefore = expectedBefore; self.after = after }
    public var jsonValue: NativeJSONValue {
        .object(["path": .string(path), "expectedBefore": expectedBefore.map(NativeJSONValue.string) ?? .null,
                 "after": after.map(NativeJSONValue.string) ?? .null])
    }
}

public enum DurableFileTransactionHistoryKind: String, Sendable { case manual, motion, timeline }

public struct DurableFileTransactionHistory: Equatable, Sendable {
    public var label: String
    public var kind: DurableFileTransactionHistoryKind
    public var coalesceKey: String?
    public var coalesceMs: Double?
    public init(label: String, kind: DurableFileTransactionHistoryKind, coalesceKey: String? = nil, coalesceMs: Double? = nil) {
        self.label = label; self.kind = kind; self.coalesceKey = coalesceKey; self.coalesceMs = coalesceMs
    }
    public var jsonValue: NativeJSONValue {
        var o: NativeJSONObject = ["label": .string(label), "kind": .string(kind.rawValue)]
        if let coalesceKey { o["coalesceKey"] = .string(coalesceKey) }
        if let coalesceMs { o["coalesceMs"] = .number(coalesceMs) }
        return .object(o)
    }
}

/// A history replay request (ProjectHistoryReplay).
public struct ProjectHistoryReplay: Equatable, Sendable {
    public enum Direction: String, Sendable { case undo, redo }
    public var entryId: String
    public var direction: Direction
    public init(entryId: String, direction: Direction) { self.entryId = entryId; self.direction = direction }
    public var jsonValue: NativeJSONValue { .object(["entryId": .string(entryId), "direction": .string(direction.rawValue)]) }
}

public struct DurableFileTransactionInput: Equatable, Sendable {
    public var id: String
    public var files: [DurableFileTransactionChange]
    public var history: DurableFileTransactionHistory?
    public var moves: [ProjectFileMove]?
    public var historyReplay: ProjectHistoryReplay?
    public init(id: String, files: [DurableFileTransactionChange], history: DurableFileTransactionHistory? = nil,
                moves: [ProjectFileMove]? = nil, historyReplay: ProjectHistoryReplay? = nil) {
        self.id = id; self.files = files; self.history = history; self.moves = moves; self.historyReplay = historyReplay
    }
    /// The object a caller passes (undefined members omitted).
    public var jsonValue: NativeJSONValue {
        var o: NativeJSONObject = ["id": .string(id), "files": .array(files.map(\.jsonValue))]
        if let history { o["history"] = history.jsonValue }
        if let moves { o["moves"] = .array(moves.map(\.jsonValue)) }
        if let historyReplay { o["historyReplay"] = historyReplay.jsonValue }
        return .object(o)
    }
}

public enum DurableFileTransactionState: String, Sendable { case prepared = "PREPARED", committed = "COMMITTED", rolledBack = "ROLLED_BACK" }

public struct DurableFileTransactionReceipt: Equatable, Sendable {
    public var id: String
    public var state: DurableFileTransactionState
    public var sequence: Int
    public var digest: String
    public var files: [DurableFileTransactionChange]
    public var history: DurableFileTransactionHistory?
    public var moves: [ProjectFileMove]?
    public var historyReplay: ProjectHistoryReplay?
    public var createdAt: String
    public var updatedAt: String
    public var journal: String
    /// publicReceipt key order.
    public var jsonObject: NativeJSONObject {
        var o: NativeJSONObject = ["id": .string(id), "state": .string(state.rawValue), "sequence": .number(Double(sequence)),
                                   "digest": .string(digest), "files": .array(files.map(\.jsonValue))]
        if let history { o["history"] = history.jsonValue }
        if let moves { o["moves"] = .array(moves.map(\.jsonValue)) }
        if let historyReplay { o["historyReplay"] = historyReplay.jsonValue }
        o["createdAt"] = .string(createdAt); o["updatedAt"] = .string(updatedAt); o["journal"] = .string(journal)
        return o
    }
    public var jsonValue: NativeJSONValue { .object(jsonObject) }
}

public struct CorruptDurableFileTransactionReceipt: Equatable, Sendable {
    public var id: String?
    public var journal: String
    public var error: String
    public var jsonObject: NativeJSONObject {
        ["id": id.map(NativeJSONValue.string) ?? .null, "state": .string("CORRUPT"), "journal": .string(journal), "error": .string(error)]
    }
}

public enum DurableFileTransactionStatus: Equatable, Sendable {
    case receipt(DurableFileTransactionReceipt)
    case corrupt(CorruptDurableFileTransactionReceipt)
    public var stateName: String { if case .receipt(let r) = self { return r.state.rawValue }; return "CORRUPT" }
    public var receipt: DurableFileTransactionReceipt? { if case .receipt(let r) = self { return r }; return nil }
    public var journal: String { switch self { case .receipt(let r): return r.journal; case .corrupt(let c): return c.journal } }
    public var id: String? { switch self { case .receipt(let r): return r.id; case .corrupt(let c): return c.id } }
    public var jsonObject: NativeJSONObject { switch self { case .receipt(let r): return r.jsonObject; case .corrupt(let c): return c.jsonObject } }
    public var jsonValue: NativeJSONValue { .object(jsonObject) }
}

public struct DurableFileTransactionRecovery: Equatable, Sendable {
    public enum Action: String, Sendable {
        case rolledBack = "rolled-back", alreadyCommitted = "already-committed", alreadyRolledBack = "already-rolled-back"
        case conflict, corrupt
    }
    public var status: DurableFileTransactionStatus
    public var action: Action
    public var conflicts: [String]?
    public var jsonValue: NativeJSONValue {
        var o = status.jsonObject
        o["action"] = .string(action.rawValue)
        if let conflicts { o["conflicts"] = .array(conflicts.map(NativeJSONValue.string)) }
        return .object(o)
    }
}

struct StoredJournal: Equatable {
    var id: String
    var state: DurableFileTransactionState
    var sequence: Int
    var digest: String
    var normalized: DurableFileTransactionInput
    var createdAt: String
    var updatedAt: String
    var checksum: String = ""

    /// journalBody: the fields in this exact order, undefined members omitted.
    func bodyObject() -> NativeJSONObject {
        var o: NativeJSONObject = ["formatVersion": .number(1), "id": .string(id), "state": .string(state.rawValue),
                                   "sequence": .number(Double(sequence)), "digest": .string(digest),
                                   "files": .array(normalized.files.map(\.jsonValue))]
        if let h = normalized.history { o["history"] = h.jsonValue }
        if let m = normalized.moves { o["moves"] = .array(m.map(\.jsonValue)) }
        if let r = normalized.historyReplay { o["historyReplay"] = r.jsonValue }
        o["createdAt"] = .string(createdAt); o["updatedAt"] = .string(updatedAt)
        return o
    }
    func body() -> String { jsJSONStringify(.object(bodyObject())) }
    /// sealJournal.
    func sealed() -> StoredJournal { var j = self; j.checksum = sha256Hex(body()); return j }
    /// JSON.stringify(journal) as written to disk.
    func serialized() -> String { var o = bodyObject(); o["checksum"] = .string(checksum); return jsJSONStringify(.object(o)) }

    func publicReceipt() -> DurableFileTransactionReceipt {
        DurableFileTransactionReceipt(id: id, state: state, sequence: sequence, digest: digest, files: normalized.files,
                                      history: normalized.history, moves: normalized.moves, historyReplay: normalized.historyReplay,
                                      createdAt: createdAt, updatedAt: updatedAt, journal: journalName(id))
    }
}

// MARK: - Pure helpers

let JOURNAL_PARENT = ".hyperframes"
let TEMPORARY_SUFFIX = ".studio-transaction.tmp"
let JOURNAL_DIRECTORY = "studio-transactions"
let ROLLED_BACK_RETENTION_MS = 7.0 * 24 * 60 * 60 * 1000
let COMMITTED_RETENTION_MS = 30.0 * 24 * 60 * 60 * 1000

func journalName(_ id: String) -> String { "\(sha256Hex(id)).json" }

/// canonicalTransaction.
func canonicalTransaction(_ input: DurableFileTransactionInput) -> String { jsJSONStringify(input.jsonValue) }

let unsafeIdMessage = "Unsafe transaction id: use 1-128 ASCII letters, digits, dots, underscores, colons, or hyphens"

func validateId(_ id: String) throws { if !isTransactionId(id) { throw ProjectsError(unsafeIdMessage) } }

/// JSON.stringify of a JS value (for error texts); nil for undefined.
private func jsonText(_ v: NativeJSONValue?) -> String { v.map { jsJSONStringify($0) } ?? "undefined" }

/// normalizeTargetPath over an untyped value.
func normalizeTargetPath(_ value: NativeJSONValue?) throws -> String {
    guard case .string(let path)? = value else {
        switch value {
        case nil, .null?, .bool(false)?: break
        case .number(let n)? where n == 0 || n.isNaN: break
        case .array?: throw ProjectsError(#"The "path" argument must be of type string. Received an instance of Array"#)
        default: throw ProjectsError("path.includes is not a function")
        }
        throw ProjectsError("Unsafe transaction target: \(jsonText(value)) must be a relative path")
    }
    switch projectRelativePathProblem(path) {
    case .notRelative?: throw ProjectsError("Unsafe transaction target: \(jsonText(.string(path))) must be a relative path")
    case .traversal?: throw ProjectsError("Unsafe transaction target: \(jsonText(.string(path))) contains traversal")
    case nil: break
    }
    if jsToLowerCase(path.components(separatedBy: "/")[0]) == JOURNAL_PARENT {
        throw ProjectsError("Reserved transaction target: \(jsonText(.string(path))) is inside .hyperframes")
    }
    return path
}

private func badString(_ s: String) -> Bool { jsTrim(s).isEmpty || s.utf16.count > 512 || s.contains("\0") }

/// normalizeHistory.
func normalizeHistory(_ history: NativeJSONValue?) throws -> DurableFileTransactionHistory? {
    guard let history else { return nil }
    guard case .object(let value) = history else { throw ProjectsError("Transaction history metadata must be an object") }
    let allowed: Set<String> = ["label", "kind", "coalesceKey", "coalesceMs"]
    let unexpected = value.keys.filter { !allowed.contains($0) }
    if !unexpected.isEmpty {
        throw ProjectsError("Transaction history metadata contains unexpected fields: \(unexpected.joined(separator: ", "))")
    }
    guard case .string(let label)? = value["label"], !badString(label) else {
        throw ProjectsError("Transaction history label must be a non-empty string of at most 512 characters")
    }
    guard case .string(let k)? = value["kind"], let kind = DurableFileTransactionHistoryKind(rawValue: k) else {
        throw ProjectsError("Transaction history kind must be manual, motion, or timeline")
    }
    var coalesceKey: String? = nil
    if let v = value["coalesceKey"] {
        guard case .string(let s) = v, !badString(s) else {
            throw ProjectsError("Transaction history coalesceKey must be a non-empty string of at most 512 characters")
        }
        coalesceKey = s
    }
    var coalesceMs: Double? = nil
    if let v = value["coalesceMs"] {
        guard case .number(let n) = v, n.isFinite, n >= 0 else {
            throw ProjectsError("Transaction history coalesceMs must be a finite non-negative number")
        }
        coalesceMs = n
    }
    return DurableFileTransactionHistory(label: label, kind: kind, coalesceKey: coalesceKey, coalesceMs: coalesceMs)
}

/// Stable sort (JS Array.prototype.sort is stable) with a three-way comparator.
func jsStableSorted<T>(_ items: [T], _ compare: (T, T) -> Int) -> [T] {
    items.enumerated().sorted { a, b in
        let c = compare(a.element, b.element)
        return c != 0 ? c < 0 : a.offset < b.offset
    }.map(\.element)
}

/// normalizeInput over an untyped input object.
func normalizeInput(_ input: NativeJSONValue) throws -> DurableFileTransactionInput {
    guard case .string(let id)? = input["id"] else { throw ProjectsError(unsafeIdMessage) }
    try validateId(id)
    let moves = try normalizeFileMoves(input["moves"])
    guard case .array(let rawFiles)? = input["files"], !(rawFiles.isEmpty && (moves?.isEmpty ?? true)) else {
        throw ProjectsError("A durable file transaction requires at least one target")
    }
    var seen = Set<String>()
    var files: [DurableFileTransactionChange] = []
    for file in rawFiles {
        func side(_ k: String) -> (ok: Bool, value: String?) {
            switch file[k] { case .string(let s)?: return (true, s); case .null?: return (true, nil); default: return (false, nil) }
        }
        let before = side("expectedBefore"), after = side("after")
        guard case .object = file, before.ok, after.ok else {
            throw ProjectsError("Every transaction target requires exact expectedBefore and after content")
        }
        let path = try normalizeTargetPath(file["path"])
        if seen.contains(path) { throw ProjectsError("Duplicate transaction target: \(path)") }
        seen.insert(path)
        files.append(DurableFileTransactionChange(path: path, expectedBefore: before.value, after: after.value))
    }
    files = jsStableSorted(files) { jsLocaleCompare($0.path, $1.path) }
    for move in moves ?? [] {
        for path in [move.from, move.to] {
            if seen.contains(path) { throw ProjectsError("Duplicate transaction target: \(path)") }
            seen.insert(path)
        }
    }
    let history = try normalizeHistory(input["history"])
    var historyReplay: ProjectHistoryReplay? = nil
    if let replay = input["historyReplay"] {
        guard case .object(let r) = replay, case .string(let entryId)? = r["entryId"], isTransactionId(entryId),
              case .string(let d)? = r["direction"], let direction = ProjectHistoryReplay.Direction(rawValue: d),
              r.keys.allSatisfy({ $0 == "entryId" || $0 == "direction" }) else {
            throw ProjectsError("Transaction historyReplay requires an entryId and undo/redo direction")
        }
        if history != nil { throw ProjectsError("Transaction history and historyReplay must be mutually exclusive") }
        historyReplay = ProjectHistoryReplay(entryId: entryId, direction: direction)
    }
    return DurableFileTransactionInput(id: id, files: files, history: history, moves: moves, historyReplay: historyReplay)
}

/// isWithin (POSIX).
func transactionIsWithin(_ root: String, _ candidate: String) -> Bool {
    let offset = PosixPath.relative(root, candidate)
    return offset.isEmpty || (!PosixPath.isAbsolute(offset) && offset != ".." && !offset.hasPrefix("../"))
}

/// parseJournal.
func parseJournal(_ raw: String, _ filename: String) throws -> StoredJournal {
    guard let candidate = try? NativeJSONValue.parse(raw) else { throw ProjectsError("Journal is not valid JSON") }
    switch candidate { case .object, .array: break; default: throw ProjectsError("Journal must be an object") }
    guard candidate["formatVersion"] == .number(1),
          case .string(let id)? = candidate["id"], isTransactionId(id),
          case .string(let st)? = candidate["state"], let state = DurableFileTransactionState(rawValue: st),
          case .number(let seq)? = candidate["sequence"], jsIsSafeInteger(seq), seq >= 1,
          case .string(let digest)? = candidate["digest"],
          case .string(let createdAt)? = candidate["createdAt"],
          case .string(let updatedAt)? = candidate["updatedAt"],
          case .string(let checksum)? = candidate["checksum"],
          case .array? = candidate["files"],
          filename == journalName(id) else {
        throw ProjectsError("Journal schema is invalid")
    }
    var inputObject: NativeJSONObject = ["id": .string(id)]
    for k in ["files", "history", "moves", "historyReplay"] { if let v = candidate[k] { inputObject[k] = v } }
    let normalized = try normalizeInput(.object(inputObject))
    let journal = StoredJournal(id: id, state: state, sequence: Int(seq), digest: digest, normalized: normalized,
                                createdAt: createdAt, updatedAt: updatedAt, checksum: checksum)
    if checksum != sha256Hex(journal.body()) { throw ProjectsError("Journal checksum is invalid") }
    if digest != sha256Hex(canonicalTransaction(normalized)) { throw ProjectsError("Journal transaction digest is invalid") }
    return journal
}

/// Date.prototype.toISOString.
func jsISOString(_ date: Date) -> String {
    let ms = (date.timeIntervalSince1970 * 1000).rounded()
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let d = Date(timeIntervalSince1970: ms / 1000)
    let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
    let milli = Int(ms - (ms / 1000).rounded(.down) * 1000)
    return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!, milli)
}

/// Date.parse for the toISOString format the store writes; NaN otherwise (see docs/IMPLEMENTATION_NOTES.md).
func jsDateParseISO(_ s: String) -> Double {
    let u = Array(s.utf8)
    guard u.count == 24, u[4] == 0x2D, u[7] == 0x2D, u[10] == 0x54, u[13] == 0x3A, u[16] == 0x3A, u[19] == 0x2E, u[23] == 0x5A else { return .nan }
    func num(_ a: Int, _ b: Int) -> Int? { Int(String(decoding: u[a..<b], as: UTF8.self)) }
    guard let y = num(0, 4), let mo = num(5, 7), let d = num(8, 10), let h = num(11, 13), let mi = num(14, 16),
          let se = num(17, 19), let ms = num(20, 23), (1...12).contains(mo), (1...31).contains(d), h <= 24, mi <= 59, se <= 59 else { return .nan }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    guard let date = cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: se)),
          cal.component(.day, from: date) == d || h == 24 else { return .nan }
    return (date.timeIntervalSince1970 * 1000).rounded() + Double(ms)
}

// MARK: - Store

public struct DurableFileTransactionStoreOptions {
    public var projectRoot: String
    public var durableWrite: DurableWrite
    public var afterPrepared: ((DurableFileTransactionReceipt) throws -> Void)?
    public var afterTargetWrite: ((Int, DurableFileTransactionChange) throws -> Void)?
    public var afterCommitted: ((DurableFileTransactionReceipt) throws -> Void)?
    public var afterMoveLink: ((Int, ProjectFileMove) throws -> Void)?
    public var afterMove: ((Int, ProjectFileMove) throws -> Void)?
    public var now: (() -> Date)?
    public init(projectRoot: String, durableWrite: DurableWrite,
                afterPrepared: ((DurableFileTransactionReceipt) throws -> Void)? = nil,
                afterTargetWrite: ((Int, DurableFileTransactionChange) throws -> Void)? = nil,
                afterCommitted: ((DurableFileTransactionReceipt) throws -> Void)? = nil,
                afterMoveLink: ((Int, ProjectFileMove) throws -> Void)? = nil,
                afterMove: ((Int, ProjectFileMove) throws -> Void)? = nil,
                now: (() -> Date)? = nil) {
        self.projectRoot = projectRoot; self.durableWrite = durableWrite; self.afterPrepared = afterPrepared
        self.afterTargetWrite = afterTargetWrite; self.afterCommitted = afterCommitted; self.afterMoveLink = afterMoveLink
        self.afterMove = afterMove; self.now = now
    }
}

/// DurableFileTransactionStore. Tests can substitute it.
public protocol DurableFileTransactionStoreProtocol: AnyObject {
    func commit(_ input: NativeJSONValue) throws -> DurableFileTransactionReceipt
    func recover() throws -> [DurableFileTransactionRecovery]
    func status(_ id: String) throws -> DurableFileTransactionStatus?
    func listReceipts() throws -> [DurableFileTransactionStatus]
    func listPending() throws -> [DurableFileTransactionReceipt]
    func listCommittedPendingHistory() throws -> [DurableFileTransactionReceipt]
    func acknowledge(_ id: String) throws -> Bool
}

/// sharedOperationQueues: one lock per configured root, shared by every store instance.
private enum SharedOperationLocks {
    static let lock = NSLock()
    nonisolated(unsafe) static var locks: [String: NSLock] = [:]
    static func lock(for root: String) -> NSLock { lock.withLock { if let l = locks[root] { return l }; let l = NSLock(); locks[root] = l; return l } }
}

public final class DurableFileTransactionStore: DurableFileTransactionStoreProtocol, @unchecked Sendable {
    private let options: DurableFileTransactionStoreOptions
    public let configuredRoot: String
    private let now: () -> Date
    private let rootLock = NSLock()
    private var rootResult: Result<String, Error>?

    /// createDurableFileTransactionStore.
    public init(_ options: DurableFileTransactionStoreOptions) {
        self.options = options
        self.configuredRoot = PosixPath.resolve([options.projectRoot])
        self.now = options.now ?? { Date() }
    }

    private func projectRoot() throws -> String {
        try rootLock.withLock {
            if rootResult == nil { rootResult = Result { try ProjectFS.realpath(configuredRoot) } }
            return try rootResult!.get()
        }
    }

    private func journalDirectory(create: Bool) throws -> String? {
        let root = try projectRoot()
        let parent = PosixPath.join(root, JOURNAL_PARENT)
        let directory = PosixPath.join(parent, JOURNAL_DIRECTORY)
        let unsafeParent = "Unsafe .hyperframes directory; refusing durable transaction journal access"
        let unsafeDir = "Unsafe studio transaction journal directory"
        if create {
            let parentEntry = try ProjectFS.entry(parent)
            if let p = parentEntry, p.isSymbolicLink || !p.isDirectory { throw ProjectsError(unsafeParent) }
            if parentEntry == nil { try ProjectFS.mkdir(parent) }
            let directoryEntry = try ProjectFS.entry(directory)
            if let d = directoryEntry, d.isSymbolicLink || !d.isDirectory { throw ProjectsError(unsafeDir) }
            if directoryEntry == nil { try ProjectFS.mkdir(directory) }
            let real = try ProjectFS.realpath(directory)
            if !transactionIsWithin(root, real) { throw ProjectsError("Transaction journal escaped project root") }
            return real
        }
        guard let p = try ProjectFS.entry(parent) else { return nil }
        if p.isSymbolicLink || !p.isDirectory { throw ProjectsError(unsafeParent) }
        guard let d = try ProjectFS.entry(directory) else { return nil }
        if d.isSymbolicLink || !d.isDirectory { throw ProjectsError(unsafeDir) }
        return directory
    }

    /// atomicReplace. The compare-and-swap check runs in `beforeRename`, after the
    /// temporary is durable and immediately before it replaces the target.
    private func atomicReplace(_ path: String, _ content: String?, allowedCurrent: [String?]? = nil) throws {
        let assertCurrent = {
            if let allowedCurrent, !allowedCurrent.contains(try ProjectFS.readExact(path)) {
                throw ProjectsError("Transaction target \(path) changed before commit or recovery", kind: .conflict)
            }
        }
        guard let content else {
            try assertCurrent()
            try ProjectFS.rmForce(path)
            try ProjectFS.syncDirectory(PosixPath.dirname(path), options.durableWrite)
            return
        }
        try options.durableWrite.write(Data(content.utf8), to: path, tempName: ".\(UUID().uuidString.lowercased())\(TEMPORARY_SUFFIX)",
                                       preserveMode: true, beforeRename: assertCurrent)
    }

    private func writeJournal(_ journal: StoredJournal) throws {
        let directory = try journalDirectory(create: true)!
        try atomicReplace(PosixPath.join(directory, journalName(journal.id)), journal.serialized())
    }

    private func readJournalFile(_ directory: String, _ filename: String) -> DurableFileTransactionStatus {
        do {
            let path = PosixPath.join(directory, filename)
            let e = try ProjectFS.lstatInfo(path)
            if e.isSymbolicLink || !e.isFile { throw ProjectsError("Journal is not a regular owned file") }
            return .receipt(try parseJournal(try ProjectFS.readUTF8(path), filename).publicReceipt())
        } catch {
            return .corrupt(CorruptDurableFileTransactionReceipt(id: nil, journal: filename, error: projectsErrorMessage(error)))
        }
    }

    public func status(_ id: String) throws -> DurableFileTransactionStatus? {
        try validateId(id)
        guard let directory = try journalDirectory(create: false) else { return nil }
        let filename = journalName(id)
        if try ProjectFS.entry(PosixPath.join(directory, filename)) == nil { return nil }
        switch readJournalFile(directory, filename) {
        case .corrupt(var c): c.id = id; return .corrupt(c)
        case let r: return r
        }
    }

    public func listReceipts() throws -> [DurableFileTransactionStatus] {
        guard let directory = try journalDirectory(create: false) else { return [] }
        let names = jsStableSorted(try ProjectFS.readdir(directory).filter { $0.hasSuffix(".json") }, jsLocaleCompare)
        return names.map { readJournalFile(directory, $0) }
    }

    public func listPending() throws -> [DurableFileTransactionReceipt] {
        try listReceipts().compactMap { $0.receipt?.state == .prepared ? $0.receipt : nil }
    }
    public func listCommittedPendingHistory() throws -> [DurableFileTransactionReceipt] {
        try listReceipts().compactMap { $0.receipt?.state == .committed ? $0.receipt : nil }
    }

    /// validateTarget.
    private func validateTarget(_ root: String, _ path: String) throws -> String {
        let target = PosixPath.resolve([root, path])
        if !transactionIsWithin(root, target) { throw ProjectsError("Unsafe transaction target escaped project: \(path)") }
        let realParent: String
        do { realParent = try ProjectFS.realpath(PosixPath.dirname(target)) }
        catch where isMissing(error) { throw ProjectsError("Transaction target parent does not exist: \(path)") }
        if !transactionIsWithin(root, realParent) { throw ProjectsError("Unsafe transaction target parent escapes project: \(path)") }
        if let e = try ProjectFS.entry(target) {
            if e.isSymbolicLink { throw ProjectsError("Unsafe transaction target is a symbolic link: \(path)") }
            if !e.isFile { throw ProjectsError("Transaction target is not a regular file: \(path)") }
        }
        return target
    }

    /// ensureTargetParent.
    private func ensureTargetParent(_ root: String, _ path: String) throws {
        let parent = PosixPath.dirname(PosixPath.resolve([root, path]))
        if !transactionIsWithin(root, parent) { throw ProjectsError("Unsafe transaction target escaped project: \(path)") }
        var ancestor = parent
        while true {
            do {
                let real = try ProjectFS.realpath(ancestor)
                if !transactionIsWithin(root, real) { throw ProjectsError("Unsafe transaction target parent escapes project: \(path)") }
                break
            } catch {
                if !isMissing(error) || ancestor == root { throw error }
                ancestor = PosixPath.dirname(ancestor)
            }
        }
        if ancestor != parent { try ProjectFS.mkdirRecursive(parent) }
    }

    private func applyContents(_ journal: StoredJournal, files: [DurableFileTransactionChange], useBefore: Bool) throws {
        let root = try projectRoot()
        let resolved = try files.map { ($0, try validateTarget(root, $0.path)) }
        for (change, target) in resolved {
            try atomicReplace(target, useBefore ? change.expectedBefore : change.after, allowedCurrent: [change.expectedBefore, change.after])
        }
    }

    /// recoverReceipt.
    private func recoverReceipt(_ receipt: DurableFileTransactionReceipt) throws -> DurableFileTransactionRecovery {
        let directory = try journalDirectory(create: false)!
        let journal = try parseJournal(try ProjectFS.readUTF8(PosixPath.join(directory, receipt.journal)), receipt.journal)
        switch journal.state {
        case .prepared:
            let root = try projectRoot()
            var conflicts: [String] = []
            for file in journal.normalized.files {
                let current = try ProjectFS.readExact(try validateTarget(root, file.path))
                if current != file.expectedBefore && current != file.after { conflicts.append(file.path) }
            }
            for move in journal.normalized.moves ?? [] { _ = try inspectFileMove(root, move) }
            try applyContents(journal, files: journal.normalized.files.filter { !conflicts.contains($0.path) }, useBefore: true)
            for move in (journal.normalized.moves ?? []).reversed() { try applyFileMove(root, move, .rollback, durableWrite: options.durableWrite) }
            var updated = journal
            updated.state = .rolledBack
            updated.updatedAt = jsISOString(now())
            updated = updated.sealed()
            try writeJournal(updated)
            return conflicts.isEmpty
                ? DurableFileTransactionRecovery(status: .receipt(updated.publicReceipt()), action: .rolledBack)
                : DurableFileTransactionRecovery(status: .receipt(updated.publicReceipt()), action: .conflict, conflicts: conflicts)
        case .committed:
            return DurableFileTransactionRecovery(status: .receipt(journal.publicReceipt()), action: .alreadyCommitted)
        case .rolledBack:
            return DurableFileTransactionRecovery(status: .receipt(journal.publicReceipt()), action: .alreadyRolledBack)
        }
    }

    private func runExclusive<T>(_ operation: () throws -> T) throws -> T {
        let l = SharedOperationLocks.lock(for: configuredRoot)
        l.lock(); defer { l.unlock() }
        return try operation()
    }

    public func recover() throws -> [DurableFileTransactionRecovery] {
        try runExclusive {
            let receipts = jsStableSorted(try listReceipts()) { l, r in
                switch (l, r) {
                case (.corrupt, .corrupt): return jsLocaleCompare(l.journal, r.journal)
                case (.corrupt, _): return 1
                case (_, .corrupt): return -1
                case (.receipt(let a), .receipt(let b)):
                    return a.sequence != b.sequence ? (a.sequence < b.sequence ? -1 : 1) : jsLocaleCompare(a.journal, b.journal)
                }
            }
            try removeStaleTemporaries(receipts)
            var results: [DurableFileTransactionRecovery] = []
            for status in receipts {
                guard case .receipt(let receipt) = status else {
                    results.append(DurableFileTransactionRecovery(status: status, action: .corrupt)); continue
                }
                do { results.append(try recoverReceipt(receipt)) }
                catch {
                    results.append(DurableFileTransactionRecovery(
                        status: .corrupt(CorruptDurableFileTransactionReceipt(id: receipt.id, journal: receipt.journal, error: projectsErrorMessage(error))),
                        action: .corrupt))
                }
            }
            try pruneSettledJournals(results)
            return results
        }
    }

    /// removeStaleTemporaries. Removes leftover temporaries
    /// (`.<uuid>.studio-transaction.tmp`), the name this store passes to DurableWrite.
    private func removeStaleTemporaries(_ receipts: [DurableFileTransactionStatus]) throws {
        guard let directory = try journalDirectory(create: false) else { return }
        let root = try projectRoot()
        var folders: [String] = [directory]
        for case .receipt(let r) in receipts {
            for file in r.files {
                let parent = PosixPath.dirname(PosixPath.resolve([root, file.path]))
                if transactionIsWithin(root, parent) && !folders.contains(parent) { folders.append(parent) }
            }
        }
        for folder in folders {
            guard let names = try? ProjectFS.readdir(folder) else { continue }
            for name in names where isStaleTemporaryName(name) {
                let path = PosixPath.join(folder, name)
                if let e = try ProjectFS.entry(path), e.isFile, !e.isSymbolicLink { try ProjectFS.rmForce(path) }
            }
        }
    }

    private func pruneSettledJournals(_ results: [DurableFileTransactionRecovery]) throws {
        guard let directory = try journalDirectory(create: false) else { return }
        let current = (now().timeIntervalSince1970 * 1000).rounded()
        var removed = false
        for result in results {
            guard case .receipt(let r) = result.status else { continue }
            let age = current - jsDateParseISO(r.updatedAt)
            let limit: Double? = r.state == .rolledBack ? ROLLED_BACK_RETENTION_MS : r.state == .committed ? COMMITTED_RETENTION_MS : nil
            guard let limit, age > limit else { continue }
            try ProjectFS.rmForce(PosixPath.join(directory, r.journal))
            removed = true
        }
        if removed { try ProjectFS.syncDirectory(directory, options.durableWrite) }
    }

    /// Typed convenience for `commit(_ input: NativeJSONValue)`.
    @discardableResult
    public func commit(_ input: DurableFileTransactionInput) throws -> DurableFileTransactionReceipt { try commit(input.jsonValue) }

    /// commit (raw input, validated as untyped JSON).
    @discardableResult
    public func commit(_ rawInput: NativeJSONValue) throws -> DurableFileTransactionReceipt {
        try runExclusive {
            let input = try normalizeInput(rawInput)
            let digest = sha256Hex(canonicalTransaction(input))
            var prior = try status(input.id)
            if case .corrupt(let c)? = prior { throw ProjectsError("Transaction \(input.id) has a corrupt journal: \(c.error)") }
            if let p = prior?.receipt, p.digest != digest { throw ProjectsError("Transaction id \(input.id) already belongs to a different payload") }
            if let p = prior?.receipt, p.state == .committed { return p }
            if let p = prior?.receipt, p.state == .prepared {
                _ = try recoverReceipt(p)
                prior = try status(input.id)
            }
            let root = try projectRoot()
            for file in input.files where file.expectedBefore == nil { try ensureTargetParent(root, file.path) }
            let resolved = try input.files.map { ($0, try validateTarget(root, $0.path)) }
            var mismatches: [String] = []
            for (file, target) in resolved where try ProjectFS.readExact(target) != file.expectedBefore { mismatches.append(file.path) }
            if !mismatches.isEmpty { throw ProjectsError("Transaction target \(mismatches.joined(separator: ", ")) changed before commit", kind: .conflict) }
            for move in input.moves ?? [] where try inspectFileMove(root, move) != .before {
                throw ProjectsError("Media move \(move.from) changed before commit", kind: .conflict)
            }
            let createdNow = jsISOString(now())
            let sequence = try listReceipts().reduce(0) { m, r in r.receipt.map { Swift.max(m, $0.sequence) } ?? m } + 1
            let prepared = StoredJournal(id: input.id, state: .prepared, sequence: sequence, digest: digest, normalized: input,
                                         createdAt: prior?.receipt?.createdAt ?? createdNow, updatedAt: createdNow).sealed()
            try writeJournal(prepared)
            try options.afterPrepared?(prepared.publicReceipt())
            for (file, target) in resolved where try ProjectFS.readExact(target) != file.expectedBefore {
                throw ProjectsError("Transaction target \(file.path) changed before commit", kind: .conflict)
            }
            for (index, move) in (input.moves ?? []).enumerated() {
                try applyFileMove(root, move, .forward, durableWrite: options.durableWrite, afterLink: { try self.options.afterMoveLink?(index, move) })
                try options.afterMove?(index, move)
            }
            for (index, (file, target)) in resolved.enumerated() {
                _ = try validateTarget(root, file.path)
                try atomicReplace(target, file.after, allowedCurrent: [file.expectedBefore])
                try options.afterTargetWrite?(index, file)
            }
            var committed = prepared
            committed.state = .committed
            committed.updatedAt = jsISOString(now())
            committed = committed.sealed()
            try writeJournal(committed)
            let receipt = committed.publicReceipt()
            try options.afterCommitted?(receipt)
            return receipt
        }
    }

    public func acknowledge(_ id: String) throws -> Bool {
        try runExclusive {
            guard let receipt = try status(id) else { return false }
            switch receipt {
            case .corrupt: throw ProjectsError("Cannot acknowledge corrupt transaction \(id)")
            case .receipt(let r) where r.state == .prepared: throw ProjectsError("Cannot acknowledge PREPARED transaction \(id) before recovery")
            case .receipt(let r):
                let directory = try journalDirectory(create: false)!
                try ProjectFS.unlink(PosixPath.join(directory, r.journal))
                try ProjectFS.syncDirectory(directory, options.durableWrite)
                return true
            }
        }
    }
}

/// `/^\.[0-9a-f-]{36}\.studio-transaction\.tmp$/`.
func isStaleTemporaryName(_ name: String) -> Bool {
    let u = Array(name.utf8), suffix = Array(".studio-transaction.tmp".utf8)
    guard u.count == 1 + 36 + suffix.count, u[0] == 0x2E, Array(u.suffix(suffix.count)) == suffix else { return false }
    return u[1..<37].allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) || $0 == 0x2D }
}
