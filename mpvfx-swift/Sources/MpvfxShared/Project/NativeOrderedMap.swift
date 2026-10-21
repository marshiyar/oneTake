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
// An object/record with JavaScript own-property order: canonical array-index keys ("0".."4294967294", no leading
// zeros) first in ascending numeric order, then every other key in insertion order. Re-setting an existing key keeps
// its position; removing then re-adding moves it to the end (JS `delete` + assign).
// Equality ignores order, like vitest `toEqual`. Use `keys` to compare order explicitly.
import Foundation

/// A canonical array index (CanonicalNumericIndexString that is an integer in [0, 2^32 - 2]).
public func jsIsArrayIndexKey(_ key: String) -> Bool {
    guard let first = key.utf8.first, !key.isEmpty, key.utf8.count <= 10, key.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return false }
    if first == 48 && key.utf8.count > 1 { return false }
    return UInt64(key)! <= 4_294_967_294
}

public struct NativeOrderedMap<Value> {
    public private(set) var keys: [String] = []
    private var storage: [String: Value] = [:]

    public init() {}
    public init<S: Sequence>(_ pairs: S) where S.Element == (String, Value) { for (k, v) in pairs { self[k] = v } }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }
    public var values: [Value] { keys.map { storage[$0]! } }

    public subscript(key: String) -> Value? {
        get { storage[key] }
        set {
            guard let newValue else { removeValue(forKey: key); return }
            if storage.updateValue(newValue, forKey: key) == nil { insertKey(key) }
        }
    }
    public subscript(key: String, default defaultValue: @autoclosure () -> Value) -> Value {
        get { storage[key] ?? defaultValue() }
        set { self[key] = newValue }
    }
    @discardableResult public mutating func removeValue(forKey key: String) -> Value? {
        guard let old = storage.removeValue(forKey: key) else { return nil }
        keys.removeAll { $0 == key }
        return old
    }
    private mutating func insertKey(_ key: String) {
        guard jsIsArrayIndexKey(key) else { keys.append(key); return }
        let n = UInt64(key)!
        let at = keys.firstIndex { !jsIsArrayIndexKey($0) || UInt64($0)! > n } ?? keys.count
        keys.insert(key, at: at)
    }
    public func mapValues<T>(_ f: (Value) throws -> T) rethrows -> NativeOrderedMap<T> {
        var out = NativeOrderedMap<T>(); for k in keys { out[k] = try f(storage[k]!) }; return out
    }
    public func filter(_ isIncluded: ((key: String, value: Value)) throws -> Bool) rethrows -> NativeOrderedMap<Value> {
        var out = NativeOrderedMap(); for e in self where try isIncluded(e) { out[e.key] = e.value }; return out
    }
    /// Plain dictionary view (order lost).
    public var dictionary: [String: Value] { storage }
}

extension NativeOrderedMap: Sequence {
    public typealias Element = (key: String, value: Value)
    public func makeIterator() -> AnyIterator<Element> {
        var i = 0
        return AnyIterator { guard i < keys.count else { return nil }; defer { i += 1 }; return (keys[i], storage[keys[i]]!) }
    }
}

extension NativeOrderedMap: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, Value)...) { self.init(elements) }
}

extension NativeOrderedMap: Equatable where Value: Equatable {
    public static func == (a: Self, b: Self) -> Bool { a.storage == b.storage }
}
extension NativeOrderedMap: Sendable where Value: Sendable {}
extension NativeOrderedMap: Hashable where Value: Hashable {
    public func hash(into h: inout Hasher) { h.combine(storage) }
}

/// Encodes/decodes as a JSON object. Order is kept with NativeJSONValueEncoder/NativeJSONValueDecoder.
extension NativeOrderedMap: Codable where Value: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: NativeAnyCodingKey.self)
        self.init()
        for k in c.allKeys { self[k.stringValue] = try c.decode(Value.self, forKey: k) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: NativeAnyCodingKey.self)
        for (k, v) in self { try c.encode(v, forKey: NativeAnyCodingKey(k)) }
    }
}

public typealias NativeJSONObject = NativeOrderedMap<NativeJSONValue>

/// Any JSON key.
public struct NativeAnyCodingKey: CodingKey {
    public var stringValue: String; public var intValue: Int? { nil }
    public init(_ s: String) { stringValue = s }
    public init?(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { stringValue = String(intValue) }
}

extension NativeOrderedMap {
    /// `{ ...self, ...other }`: existing keys keep their position and take `combine`'s value; new keys follow JS order.
    public func merging(_ other: NativeOrderedMap, uniquingKeysWith combine: (Value, Value) -> Value) -> NativeOrderedMap {
        var r = self
        for (k, v) in other { r[k] = r[k].map { combine($0, v) } ?? v }
        return r
    }
}
