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
// Startup check for the system SQLite the library catalog needs. Only features library_node.cpp actually uses
// are checked, each by USING it on an in-memory database (never sqlite3_compileoption_used). The version number is
// only a floor: 3.24.0 is the first release with UPSERT (ON CONFLICT ... DO UPDATE, library_node.cpp:95).
import Foundation
import CSQLite

public struct SQLiteRequirementError: Error, Equatable, CustomStringConvertible {
    public let feature: String
    public let detail: String
    public var description: String {
        "The system SQLite library is missing \(feature), which the media library catalog requires (\(detail))."
    }
}

public enum SQLiteRequirements {
    public static let minimumVersionNumber: Int32 = 3_024_000
    public static let minimumVersion = "3.24.0"

    /// Each probe mirrors a construct from library_node.cpp (file:line in the label).
    static let probes: [(feature: String, sql: String, expect: String?)] = [
        ("CHECK constraints and TEXT PRIMARY KEY (:60-65)",
         "CREATE TABLE t(id TEXT PRIMARY KEY, s TEXT NOT NULL CHECK(s IN ('a','b')), o TEXT NOT NULL DEFAULT '')", nil),
        ("foreign keys (PRAGMA foreign_keys, REFERENCES; :62-65, :80)",
         "PRAGMA foreign_keys=ON; CREATE TABLE p(id TEXT PRIMARY KEY); CREATE TABLE c(pid TEXT NOT NULL REFERENCES p(id))", nil),
        ("PRAGMA synchronous=FULL (:80)", "PRAGMA synchronous=FULL", nil),
        ("PRAGMA user_version (:66, :87)", "PRAGMA user_version=1", nil),
        ("BEGIN IMMEDIATE transactions (:82, :88)", "BEGIN IMMEDIATE; COMMIT;", nil),
        ("UPSERT, INSERT ... ON CONFLICT DO UPDATE (:95)",
         "CREATE TABLE u(a TEXT, b TEXT, v TEXT, PRIMARY KEY(a,b)); INSERT INTO u VALUES('1','2','x'); INSERT INTO u VALUES('1','2','y') ON CONFLICT(a,b) DO UPDATE SET v=excluded.v", nil),
        ("JSON functions json() (:71-75)", "SELECT json('{}')", "{}"),
        ("JSON functions json_object() (:69)", "SELECT json_object('a','b')", #"{"a":"b"}"#),
        ("JSON aggregate json_group_array() (:71-75)",
         "SELECT json((SELECT json_group_array(json_object('id',x)) FROM (SELECT 'k' AS x)))", #"[{"id":"k"}]"#),
    ]

    /// Runs the version floor and every probe; throws naming the first missing feature.
    public static func verify() throws {
        let number = sqlite3_libversion_number()
        if number < minimumVersionNumber {
            throw SQLiteRequirementError(feature: "version \(minimumVersion) or newer",
                                         detail: "found \(String(cString: sqlite3_libversion()))")
        }
        let db = try CatalogDatabase(":memory:", create: true)
        for probe in probes {
            for statement in probe.sql.components(separatedBy: "; ") where probe.expect == nil {
                do { try db.exec(statement) } catch { throw SQLiteRequirementError(feature: probe.feature, detail: "\(error)") }
            }
            if let expect = probe.expect {
                let got: String
                do { got = try db.query(probe.sql) } catch { throw SQLiteRequirementError(feature: probe.feature, detail: "\(error)") }
                if got != expect { throw SQLiteRequirementError(feature: probe.feature, detail: "returned \(got), expected \(expect)") }
            }
        }
    }

    private static let state = NSLock()
    nonisolated(unsafe) private static var result: Result<Void, Error>?
    /// verify() once per process; the catalog calls this before every command so a missing feature always fails clearly.
    public static func verifyOnce() throws {
        let r = state.withLock { () -> Result<Void, Error> in
            if let result { return result }
            let fresh = Result { try verify() }
            result = fresh
            return fresh
        }
        try r.get()
    }
}
