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

/// A link to a project style; overrides name the fields read from `clip.text`, including explicit nil/defaults.
public struct NativeTextStyleLink: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var kind: String = "text-style"
    public var styleId = ""
    public var overrides: [String] = []
    /// A decoded empty key remains present; a missing key and newly authored empty overrides stay omitted.
    private var preservesEmptyOverrides = false
    public var spread = NativeSpreadKeys()
    public var isSupported: Bool { version == 1 && kind == "text-style" }

    public init(styleId: String, overrides: [String] = []) {
        self.styleId = styleId
        self.overrides = overrides
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        let record = try NativeTextStyleRecord(decoder, container: container, fields: ["styleId", "overrides"])
        version = record.version
        kind = record.kind
        spread = record.spread
        if isSupported {
            styleId = try container.req(String.self, "styleId")
            overrides = try container.opt([String].self, "overrides") ?? []
            preservesEmptyOverrides = container.contains(NativeAnyCodingKey("overrides")) && overrides.isEmpty
        }
    }

    public func encode(to encoder: Encoder) throws {
        let record = NativeTextStyleRecord(version: version, kind: kind, spread: spread)
        try record.encode(to: encoder, fields: ["styleId", "overrides"]) { key, container in
            switch key {
            case "styleId": try container.put(styleId, key)
            default: try container.put(preservesEmptyOverrides || !overrides.isEmpty ? overrides : nil, key)
            }
        }
    }
}
