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
// The library catalog (SQLite) and library lock, on the plain sqlite3 C API.
// Fixed SQL text, open flags, busy timeout, pragmas, transactions and error messages. Callers run these on a
// background task (LibraryService).
import Foundation
import CSQLite

public struct LibraryCatalogError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

private let SQLITE_TRANSIENT_ = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// library_node.cpp:20 Database.
final class CatalogDatabase {
    private var db: OpaquePointer?
    init(_ path: String, create: Bool) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | (create ? SQLITE_OPEN_CREATE : 0)
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            let error = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open catalog"
            if let db { sqlite3_close(db) }
            db = nil
            throw LibraryCatalogError(error)
        }
        sqlite3_busy_timeout(db, 5000)
    }
    deinit { if let db { sqlite3_close(db) } }
    func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(error)
            throw LibraryCatalogError(message)
        }
    }
    @discardableResult
    func query(_ sql: String, _ values: [String] = []) throws -> String {
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &raw, nil) == SQLITE_OK else { throw LibraryCatalogError(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(raw) }
        guard sqlite3_bind_parameter_count(raw) == Int32(values.count) else { throw LibraryCatalogError("Invalid command arguments") }
        for (i, value) in values.enumerated() {
            let rc = value.withCString { sqlite3_bind_text(raw, Int32(i + 1), $0, Int32(value.utf8.count), SQLITE_TRANSIENT_) }
            guard rc == SQLITE_OK else { throw LibraryCatalogError(String(cString: sqlite3_errmsg(db))) }
        }
        let result = sqlite3_step(raw)
        if result == SQLITE_ROW {
            guard let text = sqlite3_column_text(raw, 0) else { return "null" }
            return String(cString: text)
        }
        guard result == SQLITE_DONE else { throw LibraryCatalogError(String(cString: sqlite3_errmsg(db))) }
        return "null"
    }
}

/// library_node.cpp:59 schema (verbatim).
let LIBRARY_CATALOG_SCHEMA = """
CREATE TABLE library(id TEXT PRIMARY KEY, name TEXT NOT NULL, version INTEGER NOT NULL CHECK(version=1));
CREATE TABLE events(id TEXT PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE projects(id TEXT PRIMARY KEY, eventId TEXT NOT NULL REFERENCES events(id), name TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','ready')));
CREATE TABLE assets(id TEXT PRIMARY KEY, eventId TEXT NOT NULL REFERENCES events(id), name TEXT NOT NULL, kind TEXT NOT NULL, mode TEXT NOT NULL CHECK(mode IN ('managed','linked')), source TEXT NOT NULL, fingerprint TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','ready')));
CREATE TABLE placements(projectId TEXT NOT NULL REFERENCES projects(id), assetId TEXT NOT NULL REFERENCES assets(id), path TEXT NOT NULL, PRIMARY KEY(projectId,assetId), UNIQUE(projectId,path));
CREATE TABLE jobs(id TEXT PRIMARY KEY, projectId TEXT NOT NULL REFERENCES projects(id), snapshot TEXT NOT NULL, status TEXT NOT NULL, output TEXT NOT NULL DEFAULT '', error TEXT NOT NULL DEFAULT '');
PRAGMA user_version=1;

"""

/// library_node.cpp:68 snapshot query (verbatim).
let LIBRARY_CATALOG_SNAPSHOT = """

SELECT json_object(
 'id',(SELECT id FROM library), 'name',(SELECT name FROM library),
 'events',json((SELECT json_group_array(json_object('id',id,'name',name)) FROM events)),
 'projects',json((SELECT json_group_array(json_object('id',id,'eventId',eventId,'name',name,'state',state)) FROM projects)),
 'assets',json((SELECT json_group_array(json_object('id',id,'eventId',eventId,'name',name,'kind',kind,'mode',mode,'source',source,'fingerprint',fingerprint,'state',state)) FROM assets)),
 'placements',json((SELECT json_group_array(json_object('projectId',projectId,'assetId',assetId,'path',path)) FROM placements)),
 'jobs',json((SELECT json_group_array(json_object('id',id,'projectId',projectId,'snapshot',snapshot,'status',status,'output',output,'error',error)) FROM jobs))
)
"""

/// library_node.cpp:78 the one-statement commands (verbatim), each run with the caller's arguments. A rename changes
/// only the name column, never an id, so every reference to the event or project stays valid.
let LIBRARY_CATALOG_STATEMENTS: [String: String] = [
    "event": "INSERT INTO events VALUES(?1,?2)",
    "project": "INSERT INTO projects VALUES(?1,?2,?3,'pending')",
    "projectReady": "UPDATE projects SET state='ready' WHERE id=?1",
    "renameEvent": "UPDATE events SET name=?2 WHERE id=?1",
    "renameProject": "UPDATE projects SET name=?2 WHERE id=?1",
    "asset": "INSERT INTO assets VALUES(?1,?2,?3,?4,?5,?6,?7,'pending')",
    "assetReady": "UPDATE assets SET state='ready' WHERE id=?1",
    "relink": "UPDATE assets SET source=?2 WHERE id=?1 AND mode='linked'",
    "attach": "INSERT INTO placements VALUES(?1,?2,?3) ON CONFLICT(projectId,assetId) DO UPDATE SET path=excluded.path",
    "job": "INSERT INTO jobs(id,projectId,snapshot,status) VALUES(?1,?2,?3,'rendering')",
    "jobFinish": "UPDATE jobs SET status=?2,output=?3,error=?4 WHERE id=?1",
]
let LIBRARY_CATALOG_RECOVER =
    "UPDATE jobs SET status='interrupted',error='Application closed before export completion; export again from the saved snapshot' WHERE status='rendering';"

public enum LibraryCatalog {
    /// library_node.cpp:78 command. Returns the catalog snapshot JSON text. N-API argument checks (:118 embedded NUL,
    /// :129 more than 16 arguments) are applied here too.
    public static func command(_ path: String, _ action: String, _ args: [String]) throws -> String {
        if args.count > 16 { throw LibraryCatalogError("Too many arguments") }
        if ([path, action] + args).contains(where: { $0.utf8.contains(0) }) { throw LibraryCatalogError("Embedded NUL is not permitted") }
        try SQLiteRequirements.verifyOnce()
        let d = try CatalogDatabase(path, create: action == "create")
        try d.exec("PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL;")
        if action == "create" {
            try d.exec("BEGIN IMMEDIATE;")
            try d.exec(LIBRARY_CATALOG_SCHEMA)
            try d.query("INSERT INTO library VALUES(?1,?2,1)", args)
            try d.exec("COMMIT;")
        } else {
            if try d.query("PRAGMA user_version") != "1" { throw LibraryCatalogError("Unsupported library catalog version") }
            try d.exec("BEGIN IMMEDIATE;")
            if let statement = LIBRARY_CATALOG_STATEMENTS[action] { try d.query(statement, args) }
            else if action == "recover" { try d.exec(LIBRARY_CATALOG_RECOVER) }
            else if action != "read" { throw LibraryCatalogError("Unknown library command") }
            else if !args.isEmpty { throw LibraryCatalogError("Invalid read arguments") }
            try d.exec("COMMIT;")
        }
        return try d.query(LIBRARY_CATALOG_SNAPSHOT)
    }
}

/// library_node.cpp:153 Lock: one exclusive, non-blocking lock on `.mpvfx-lock` that refuses a symbolic link: flock on
/// an O_NOFOLLOW descriptor (POSIX), a share-mode-0 handle that is not a reparse point (Windows). Released by `close()`
/// or deinit.
public final class LibraryLock: @unchecked Sendable {
    private let lock = NSLock()
    private var file: NativeFile?
    public init(_ path: String) throws {
        if path.utf8.contains(0) { throw LibraryCatalogError("Embedded NUL is not permitted") }
        do { file = try NativeFile.lockExclusive(path) } catch {
            throw LibraryCatalogError("Library is already open in another process or is not writable")
        }
    }
    public func close() { lock.withLock { file?.close(); file = nil } }
    deinit { close() }
}
