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
// Unknown-key carry-through for records copied whole (`{ ...value }`) or passed through as-is.
// `order` is every input key in JS order; `extra` holds the keys this model doesn't know. Encoding replays the input
// order (known keys take their current values in place, as `{ ...value, known }` does), then appends known keys that
// weren't in the input, then extras added later. Equality compares `extra` only (order-insensitive, like toEqual).
import Foundation

public struct NativeSpreadKeys: Hashable {
    public var order: [String] = []
    public var extra = NativeJSONObject()
    public init(order: [String] = [], extra: NativeJSONObject = [:]) { self.order = order; self.extra = extra }
    public static func == (a: Self, b: Self) -> Bool { a.extra == b.extra }
    public func hash(into h: inout Hasher) { h.combine(extra.count) }
}

func decodeSpread(_ decoder: Decoder, known: [String]) throws -> NativeSpreadKeys {
    let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
    var s = NativeSpreadKeys()
    for k in c.allKeys {
        s.order.append(k.stringValue)
        if !known.contains(k.stringValue) { s.extra[k.stringValue] = try c.decode(NativeJSONValue.self, forKey: k) }
    }
    return s
}

/// `write(key, &container)` encodes one known key (or nothing when its optional value is nil).
func encodeSpread(_ encoder: Encoder, _ s: NativeSpreadKeys, known: [String],
                  _ write: (String, inout KeyedEncodingContainer<NativeAnyCodingKey>) throws -> Void) throws {
    var c = encoder.container(keyedBy: NativeAnyCodingKey.self)
    var done = Set<String>()
    for k in s.order where done.insert(k).inserted {
        if known.contains(k) { try write(k, &c) } else if let v = s.extra[k] { try c.encode(v, forKey: NativeAnyCodingKey(k)) }
    }
    for k in known where done.insert(k).inserted { try write(k, &c) }
    for (k, v) in s.extra where done.insert(k).inserted { try c.encode(v, forKey: NativeAnyCodingKey(k)) }
}

/// Spread keys of a raw JSON object (nil / non-object gives none).
func spreadOfJSON(_ v: NativeJSONValue?, known: [String]) -> NativeSpreadKeys {
    guard case .object(let o)? = v else { return .init() }
    var s = NativeSpreadKeys(order: Array(o.keys))
    for (k, x) in o where !known.contains(k) { s.extra[k] = x }
    return s
}

/// Re-applies input key order and unknown keys to an encoded known-keys-only object.
func overlaySpread(_ typed: NativeJSONValue, _ s: NativeSpreadKeys) -> NativeJSONValue {
    guard case .object(let t) = typed, !(s.order.isEmpty && s.extra.isEmpty) else { return typed }
    var r = NativeJSONObject()
    for k in s.order { if let v = t[k] ?? s.extra[k] { r[k] = v } }
    for (k, v) in t where r[k] == nil { r[k] = v }
    for (k, v) in s.extra where r[k] == nil { r[k] = v }
    return .object(r)
}

extension KeyedEncodingContainer where Key == NativeAnyCodingKey {
    mutating func put<T: Encodable>(_ v: T?, _ k: String) throws { if let v { try encode(v, forKey: NativeAnyCodingKey(k)) } }
}
extension KeyedDecodingContainer where Key == NativeAnyCodingKey {
    func req<T: Decodable>(_ t: T.Type, _ k: String) throws -> T { try decode(t, forKey: NativeAnyCodingKey(k)) }
    func opt<T: Decodable>(_ t: T.Type, _ k: String) throws -> T? { try decodeIfPresent(t, forKey: NativeAnyCodingKey(k)) }
}
