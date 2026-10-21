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

/// A named, versioned typography record. Words belong to each clip; `text.content` is ignored.
/// Future versions/kinds retain their complete JSON and are not rendered.
public struct NativeTextStyle: Codable, Equatable, Sendable {
    /// The typography fields that can be overridden independently of a project style.
    public static let fields: [String] = [
        "fontFamily", "fontSize", "fontWeight", "color", "align", "letterSpacing",
        "lineHeight", "textTransform", "fontStyle", "look",
    ]

    public var version: Int = 1
    public var kind: String = "text-style"
    public var id: String
    public var name = ""
    public var text: NativeClipText?
    public var spread = NativeSpreadKeys()
    public var isSupported: Bool { version == 1 && kind == "text-style" }
    public init(id: String, name: String, text: NativeClipText) {
        self.id = id
        self.name = name
        self.text = text
        self.text?.content = ""
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        let record = try NativeTextStyleRecord(
            decoder,
            container: container,
            fields: ["name", "text"],
            persistent: ["id"]
        )
        version = record.version
        kind = record.kind
        spread = record.spread
        id = try container.req(String.self, "id")
        if isSupported {
            name = try container.req(String.self, "name")
            text = try container.req(NativeClipText.self, "text")
        }
    }

    public func encode(to encoder: Encoder) throws {
        let record = NativeTextStyleRecord(version: version, kind: kind, spread: spread)
        try record.encode(to: encoder, fields: ["name", "text"], persistent: ["id"]) { key, container in
            switch key {
            case "id":
                try container.put(id, key)
            case "name":
                try container.put(name, key)
            default:
                try container.put(text, key)
            }
        }
    }
}
