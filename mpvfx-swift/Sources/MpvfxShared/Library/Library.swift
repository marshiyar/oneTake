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
import Foundation

// The desktop bridge's library command/result shapes (types only).
// JSON crosses the bridge verbatim, so every type keeps unknown keys and input key
// order (NativeSpreadKeys) and re-encodes exactly what it decoded. Decode from an order-preserving source
// (NativeJSONValue.parse(text).decode(_:)) to keep order. See docs/IMPLEMENTATION_NOTES.md gaps.

public enum LibraryItemState: String, Codable, Sendable { case pending, ready }
public enum LibraryAssetMode: String, Codable, Sendable { case managed, linked }

/// Decodes an optional key. A present value that is null or not a `T` is kept
/// verbatim in `spread.extra`, so it re-encodes unchanged.
private func optKeep<T: Decodable>(_ c: KeyedDecodingContainer<NativeAnyCodingKey>, _ k: String, _ s: inout NativeSpreadKeys) -> T? {
    guard c.contains(NativeAnyCodingKey(k)) else { return nil }
    if let v = try? c.decode(T.self, forKey: NativeAnyCodingKey(k)) { return v }
    s.extra[k] = try? c.decode(NativeJSONValue.self, forKey: NativeAnyCodingKey(k))
    return nil
}
/// Known keys minus those carried verbatim in `extra` (see optKeep).
private func liveKnown(_ known: [String], _ s: NativeSpreadKeys) -> [String] { known.filter { s.extra[$0] == nil } }

/// A library event.
public struct LibraryEvent: Codable, Equatable {
    public var id: String, name: String
    public var spread = NativeSpreadKeys()
    static let known = ["id", "name"]
    public init(id: String, name: String) { self.id = id; self.name = name }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        id = try c.req(String.self, "id"); name = try c.req(String.self, "name")
        spread = try decodeSpread(decoder, known: Self.known)
    }
    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: Self.known) { k, c in try c.put(k == "id" ? id : name, k) }
    }
}

/// A library project.
public struct LibraryProject: Codable, Equatable {
    public var id: String, eventId: String, name: String, state: LibraryItemState
    public var spread = NativeSpreadKeys()
    static let known = ["id", "eventId", "name", "state"]
    public init(id: String, eventId: String, name: String, state: LibraryItemState) {
        self.id = id; self.eventId = eventId; self.name = name; self.state = state
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        id = try c.req(String.self, "id"); eventId = try c.req(String.self, "eventId")
        name = try c.req(String.self, "name"); state = try c.req(LibraryItemState.self, "state")
        spread = try decodeSpread(decoder, known: Self.known)
    }
    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: Self.known) { k, c in
            switch k { case "id": try c.put(id, k); case "eventId": try c.put(eventId, k); case "name": try c.put(name, k)
            default: try c.put(state, k) }
        }
    }
}

/// A library asset.
public struct LibraryAsset: Codable, Equatable {
    public var id: String, eventId: String, name: String, kind: String
    public var mode: LibraryAssetMode, state: LibraryItemState
    public var available: Bool?
    public var spread = NativeSpreadKeys()
    static let known = ["id", "eventId", "name", "kind", "mode", "state", "available"]
    public init(id: String, eventId: String, name: String, kind: String, mode: LibraryAssetMode,
                state: LibraryItemState, available: Bool? = nil) {
        self.id = id; self.eventId = eventId; self.name = name; self.kind = kind
        self.mode = mode; self.state = state; self.available = available
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        id = try c.req(String.self, "id"); eventId = try c.req(String.self, "eventId")
        name = try c.req(String.self, "name"); kind = try c.req(String.self, "kind")
        mode = try c.req(LibraryAssetMode.self, "mode"); state = try c.req(LibraryItemState.self, "state")
        var s = try decodeSpread(decoder, known: Self.known)
        available = optKeep(c, "available", &s)
        spread = s
    }
    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: liveKnown(Self.known, spread)) { k, c in
            switch k {
            case "id": try c.put(id, k); case "eventId": try c.put(eventId, k); case "name": try c.put(name, k)
            case "kind": try c.put(kind, k); case "mode": try c.put(mode, k); case "state": try c.put(state, k)
            default: try c.put(available, k)
            }
        }
    }
}

/// A library job.
public struct LibraryJob: Codable, Equatable {
    public var id: String, projectId: String, status: String, output: String, error: String
    public var spread = NativeSpreadKeys()
    static let known = ["id", "projectId", "status", "output", "error"]
    public init(id: String, projectId: String, status: String, output: String, error: String) {
        self.id = id; self.projectId = projectId; self.status = status; self.output = output; self.error = error
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        id = try c.req(String.self, "id"); projectId = try c.req(String.self, "projectId")
        status = try c.req(String.self, "status"); output = try c.req(String.self, "output"); error = try c.req(String.self, "error")
        spread = try decodeSpread(decoder, known: Self.known)
    }
    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: Self.known) { k, c in
            try c.put([("id", id), ("projectId", projectId), ("status", status), ("output", output), ("error", error)].first { $0.0 == k }!.1, k)
        }
    }
}

/// A library as the views list shows it.
public struct LibraryView: Codable, Equatable {
    public var id: String, name: String, path: String
    public var events: [LibraryEvent], projects: [LibraryProject], assets: [LibraryAsset], jobs: [LibraryJob]
    public var spread = NativeSpreadKeys()
    static let known = ["id", "name", "path", "events", "projects", "assets", "jobs"]
    public init(id: String, name: String, path: String, events: [LibraryEvent] = [], projects: [LibraryProject] = [],
                assets: [LibraryAsset] = [], jobs: [LibraryJob] = []) {
        self.id = id; self.name = name; self.path = path
        self.events = events; self.projects = projects; self.assets = assets; self.jobs = jobs
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        id = try c.req(String.self, "id"); name = try c.req(String.self, "name"); path = try c.req(String.self, "path")
        events = try c.req([LibraryEvent].self, "events"); projects = try c.req([LibraryProject].self, "projects")
        assets = try c.req([LibraryAsset].self, "assets"); jobs = try c.req([LibraryJob].self, "jobs")
        spread = try decodeSpread(decoder, known: Self.known)
    }
    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: Self.known) { k, c in
            switch k {
            case "id": try c.put(id, k); case "name": try c.put(name, k); case "path": try c.put(path, k)
            case "events": try c.put(events, k); case "projects": try c.put(projects, k)
            case "assets": try c.put(assets, k); default: try c.put(jobs, k)
            }
        }
    }
}

/// A library command (discriminated on `type`).
public struct LibraryCommand: Codable, Equatable {
    public enum Kind: Equatable {
        case list, create, open
        case event(libraryId: String, name: String)
        case project(libraryId: String, eventId: String, name: String)
        case `import`(libraryId: String, eventId: String, mode: LibraryAssetMode, projectId: String?)
        case attach(libraryId: String, projectId: String, assetId: String)
        case reveal(libraryId: String)
        case relink(libraryId: String, assetId: String)
        case saveOutput(libraryId: String, jobId: String)
    }
    public var kind: Kind
    public var spread = NativeSpreadKeys()
    public init(_ kind: Kind) { self.kind = kind }

    public var type: String {
        switch kind {
        case .list: return "list"; case .create: return "create"; case .open: return "open"; case .event: return "event"
        case .project: return "project"; case .import: return "import"; case .attach: return "attach"
        case .reveal: return "reveal"; case .relink: return "relink"; case .saveOutput: return "saveOutput"
        }
    }
    /// Known keys in declaration order for this member of the union.
    var fields: [(String, String?)] {
        switch kind {
        case .list, .create, .open: return [("type", type)]
        case .event(let l, let n): return [("type", type), ("libraryId", l), ("name", n)]
        case .project(let l, let e, let n): return [("type", type), ("libraryId", l), ("eventId", e), ("name", n)]
        case .import(let l, let e, let m, let p):
            return [("type", type), ("libraryId", l), ("eventId", e), ("mode", m.rawValue), ("projectId", p)]
        case .attach(let l, let p, let a): return [("type", type), ("libraryId", l), ("projectId", p), ("assetId", a)]
        case .reveal(let l): return [("type", type), ("libraryId", l)]
        case .relink(let l, let a): return [("type", type), ("libraryId", l), ("assetId", a)]
        case .saveOutput(let l, let j): return [("type", type), ("libraryId", l), ("jobId", j)]
        }
    }
    public struct UnknownType: Error, Equatable { public let type: String }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        let t = try c.req(String.self, "type")
        func s(_ k: String) throws -> String { try c.req(String.self, k) }
        var sp = NativeSpreadKeys()
        switch t {
        case "list": kind = .list
        case "create": kind = .create
        case "open": kind = .open
        case "event": kind = .event(libraryId: try s("libraryId"), name: try s("name"))
        case "project": kind = .project(libraryId: try s("libraryId"), eventId: try s("eventId"), name: try s("name"))
        case "import":
            kind = .import(libraryId: try s("libraryId"), eventId: try s("eventId"),
                           mode: try c.req(LibraryAssetMode.self, "mode"), projectId: nil)
        case "attach": kind = .attach(libraryId: try s("libraryId"), projectId: try s("projectId"), assetId: try s("assetId"))
        case "reveal": kind = .reveal(libraryId: try s("libraryId"))
        case "relink": kind = .relink(libraryId: try s("libraryId"), assetId: try s("assetId"))
        case "saveOutput": kind = .saveOutput(libraryId: try s("libraryId"), jobId: try s("jobId"))
        default: throw UnknownType(type: t)
        }
        // Keys that aren't fields of this member (e.g. libraryId on "list") are carried as unknown keys.
        sp = try decodeSpread(decoder, known: fields.map(\.0))
        if case .import(let l, let e, let m, _) = kind {
            let p: String? = optKeep(c, "projectId", &sp)
            kind = .import(libraryId: l, eventId: e, mode: m, projectId: p)
        }
        spread = sp
    }
    public func encode(to encoder: Encoder) throws {
        let f = fields
        try encodeSpread(encoder, spread, known: liveKnown(f.map(\.0), spread)) { k, c in try c.put(f.first { $0.0 == k }!.1, k) }
    }
}

/// A library command result.
public struct LibraryResult: Codable, Equatable {
    public var libraries: [LibraryView]
    public var projectId: String?, path: String?, errors: [String]?
    public var spread = NativeSpreadKeys()
    static let known = ["libraries", "projectId", "path", "errors"]
    public init(libraries: [LibraryView], projectId: String? = nil, path: String? = nil, errors: [String]? = nil) {
        self.libraries = libraries; self.projectId = projectId; self.path = path; self.errors = errors
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        libraries = try c.req([LibraryView].self, "libraries")
        var s = try decodeSpread(decoder, known: Self.known)
        projectId = optKeep(c, "projectId", &s); path = optKeep(c, "path", &s); errors = optKeep(c, "errors", &s)
        spread = s
    }
    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: liveKnown(Self.known, spread)) { k, c in
            switch k {
            case "libraries": try c.put(libraries, k); case "projectId": try c.put(projectId, k)
            case "path": try c.put(path, k); default: try c.put(errors, k)
            }
        }
    }
}
