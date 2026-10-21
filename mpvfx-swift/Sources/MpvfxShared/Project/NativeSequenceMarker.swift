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

/// A named point on the sequence, saved independently of clip selection and edits.
public struct NativeSequenceMarker: Codable, Equatable, Sendable {
    public var id: String
    public var time: Double
    public var name: String
    public var color: String
    public var note: String
    public var spread = NativeSpreadKeys()
    static let known = ["id", "time", "name", "color", "note"]
    public init(id: String, time: Double, name: String, color: String = "#FBBF24", note: String = "") {
        self.id = id; self.time = time; self.name = name; self.color = color; self.note = note
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        id = try c.req(String.self, "id"); time = try c.req(Double.self, "time")
        name = try c.req(String.self, "name"); color = try c.req(String.self, "color"); note = try c.req(String.self, "note")
        spread = try decodeSpread(decoder, known: Self.known)
    }
    public func encode(to encoder: Encoder) throws {
        try encodeSpread(encoder, spread, known: Self.known) { k, c in
            switch k {
            case "id": try c.put(id, k); case "time": try c.put(time, k); case "name": try c.put(name, k)
            case "color": try c.put(color, k); default: try c.put(note, k)
            }
        }
    }

}

func validateNativeSequenceMarkers(_ raw: NativeJSONValue?, _ issues: inout Issues) {
    guard let raw else { return }
    guard let markers = raw.arrayValue else {
        pushIssue(&issues, .invalidTrack, "sequence.markers", "Markers must be an array"); return
    }
    var ids = Set<String>()
    for (i, marker) in markers.enumerated() {
        let p = "sequence.markers[\(i)]"
        guard marker.isRecord else { pushIssue(&issues, .invalidTrack, p, "Marker must be an object"); continue }
        requireId(marker["id"], "\(p).id", &issues)
        collectDuplicateId(&ids, marker["id"], "\(p).id", &issues)
        if !(marker["time"]?.numberValue.map { $0.isFinite && $0 >= 0 && $0 <= jsMaxSafeInteger } ?? false) {
            pushIssue(&issues, .invalidTrack, "\(p).time", "Marker time must be finite, non-negative seconds")
        }
        if !isNonEmptyString(marker["name"]) { pushIssue(&issues, .invalidTrack, "\(p).name", "Marker needs a name") }
        let color = marker["color"]?.stringValue ?? ""
        if color.count != 7 || color.first != "#" || !color.dropFirst().allSatisfy({ $0.isHexDigit && $0.isASCII }) {
            pushIssue(&issues, .invalidTrack, "\(p).color", "Marker color must be #RRGGBB")
        }
        if marker["note"]?.stringValue == nil { pushIssue(&issues, .invalidTrack, "\(p).note", "Marker note must be text") }
    }
}
