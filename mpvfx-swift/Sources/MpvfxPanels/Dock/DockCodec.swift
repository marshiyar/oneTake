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

/// `<userData>/dock-layout.json`: the layout of each workspace and which one is current.
public struct DockFile: Equatable, Sendable {
    public static let defaultWorkspace = "edit"
    public var current: String
    public var workspaces: [String: DockLayout]
    public init(current: String = DockFile.defaultWorkspace, workspaces: [String: DockLayout]) {
        self.current = current; self.workspaces = workspaces
    }

    /// The current workspace's layout.
    public var layout: DockLayout? { workspaces[current] }
}

/// Why a saved layout file was not used (the editor then opens the default layout).
public enum DockLayoutError: Error, Equatable, CustomStringConvertible {
    case tooLarge(bytes: Int)
    case tooDeep
    case tooManyNodes
    case malformed(String)
    case unsupportedVersion(Int)
    case noWorkspace

    public var description: String {
        switch self {
        case .tooLarge(let n): return "The panel layout file is \(n) bytes, more than the \(DockCodec.maxBytes) allowed"
        case .tooDeep: return "The panel layout file nests deeper than \(DockCodec.maxDepth) levels"
        case .tooManyNodes: return "The panel layout file has more than \(DockCodec.maxNodes) panel groups and splits"
        case .malformed(let why): return "The panel layout file is not a layout: \(why)"
        case .unsupportedVersion(let v): return "The panel layout file is version \(v); this MpVFX reads version \(DockCodec.version)"
        case .noWorkspace: return "The panel layout file holds no usable workspace"
        }
    }
}

/// Encoding and decoding of `DockFile`. Decoding treats the bytes as hostile: size, nesting and node count are
/// bounded before and after parsing, structure errors reject the file, and content errors are repaired (each repair
/// is reported as a note).
public enum DockCodec {
    public static let version = 1
    public static let maxBytes = 256 * 1024
    /// Layout tree depth; the JSON nests about four levels per tree level, which `maxJSONDepth` bounds before parsing.
    public static let maxDepth = 12
    static let maxJSONDepth = 64
    public static let maxNodes = 256
    public static let maxWorkspaces = 16

    public struct Decoded: Equatable, Sendable {
        public var file: DockFile
        /// What was repaired ("dropped unknown panel \"x\"").
        public var notes: [String]
    }

    public static func encode(_ file: DockFile) throws -> Data {
        let raw = RawFile(version: version, current: Lenient(file.current),
                          workspaces: file.workspaces.mapValues { RawLayout($0) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(raw)
    }

    public static func decode(_ data: Data, registry: DockRegistry) -> Result<Decoded, DockLayoutError> {
        guard data.count <= maxBytes else { return .failure(.tooLarge(bytes: data.count)) }
        guard jsonDepth(data) <= maxJSONDepth else { return .failure(.tooDeep) }
        let raw: RawFile
        switch parse(data) { case .success(let r): raw = r; case .failure(let e): return .failure(e) }
        guard raw.version == version else { return .failure(.unsupportedVersion(raw.version)) }
        return sanitize(raw, registry: registry)
    }

    /// The saved file when it is usable, else the default; `error` says why the saved one was not used
    /// (nil for a missing file, which is the first launch).
    public static func load(_ data: Data?, registry: DockRegistry, fallback: DockFile) -> (file: DockFile, error: DockLayoutError?, notes: [String]) {
        guard let data else { return (fallback, nil, []) }
        switch decode(data, registry: registry) {
        case .success(let d): return (d.file, nil, d.notes)
        case .failure(let e): return (fallback, e, [])
        }
    }

    // MARK: Parsing

    static func parse(_ data: Data) -> Result<RawFile, DockLayoutError> {
        let decoder = JSONDecoder()
        do {
            let head = try decoder.decode(RawVersion.self, from: data)
            guard let v = head.version else { return .failure(.malformed("no version")) }
            guard v == version else { return .failure(.unsupportedVersion(v)) }
            return .success(try decoder.decode(RawFile.self, from: data))
        } catch let e as DecodingError {
            return .failure(.malformed(Self.describe(e)))
        } catch {
            return .failure(.malformed("\(error)"))
        }
    }

    static func describe(_ e: DecodingError) -> String {
        switch e {
        case .dataCorrupted(let c): return c.debugDescription
        case .keyNotFound(let k, _): return "missing \(k.stringValue)"
        case .typeMismatch(_, let c), .valueNotFound(_, let c): return "wrong type at \(c.codingPath.map(\.stringValue).joined(separator: "."))"
        @unknown default: return "\(e)"
        }
    }

    /// The deepest `{`/`[` nesting outside strings: rejects a nesting bomb before the parser recurses into it.
    static func jsonDepth(_ data: Data) -> Int {
        var depth = 0, deepest = 0, inString = false, escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                continue
            }
            switch byte {
            case 0x22: inString = true
            case 0x7B, 0x5B: depth += 1; deepest = max(deepest, depth)
            case 0x7D, 0x5D: depth -= 1
            default: break
            }
        }
        return deepest
    }
}
