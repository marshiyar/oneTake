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

/// The shared version/kind contract and ordered-key codec. Unknown versions retain all type-specific payload keys.
internal struct NativeTextStyleRecord {
    internal let version: Int
    internal let kind: String
    internal let spread: NativeSpreadKeys

    internal init(
        _ decoder: Decoder, container: KeyedDecodingContainer<NativeAnyCodingKey>,
        persistent: [String] = [], fields: [String]
    ) throws {
        version = try container.req(Int.self, "v")
        kind = try container.req(String.self, "kind")
        let keys = Self.keys(version: version, kind: kind, persistent: persistent, fields: fields)
        spread = try decodeSpread(decoder, known: keys)
    }

    internal init(version: Int, kind: String, spread: NativeSpreadKeys) {
        self.version = version
        self.kind = kind
        self.spread = spread
    }

    internal func encode(
        to encoder: Encoder, persistent: [String] = [], fields: [String],
        field: (String, inout KeyedEncodingContainer<NativeAnyCodingKey>) throws -> Void
    ) throws {
        let keys = Self.keys(version: version, kind: kind, persistent: persistent, fields: fields)
        try encodeSpread(encoder, spread, known: keys) { key, container in
            switch key {
            case "v": try container.put(version, key)
            case "kind": try container.put(kind, key)
            default: try field(key, &container)
            }
        }
    }

    private static func keys(version: Int, kind: String, persistent: [String], fields: [String]) -> [String] {
        ["v", "kind"] + persistent + (version == 1 && kind == "text-style" ? fields : [])
    }
}
