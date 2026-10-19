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
// Encodable -> NativeJSONValue without going through JSON text, so non-finite numbers survive as .number(NaN/±Inf)
// (JSONEncoder refuses them). Objects keep encode-call order (JS insertion order).
// This lets the validator report NaN/Infinity for in-memory documents, not only for parsed text.
import Foundation

final class NativeJSONValueEncoder: Encoder {
    final class Box { var value: NativeJSONValue; init(_ v: NativeJSONValue) { value = v } }
    let codingPath: [CodingKey]; let userInfo: [CodingUserInfoKey: Any] = [:]
    let box: Box
    init(_ box: Box, _ path: [CodingKey] = []) { self.box = box; codingPath = path }

    static func encode<T: Encodable>(_ v: T) throws -> NativeJSONValue {
        let box = Box(.null); try v.encode(to: NativeJSONValueEncoder(box)); return box.value
    }
    fileprivate static func encodeChild<T: Encodable>(_ v: T, _ path: [CodingKey]) throws -> NativeJSONValue {
        // Exact type checks: Darwin's NSNumber bridging would let `true as? Double` succeed.
        if T.self == Bool.self { return .bool(v as! Bool) }
        if T.self == Double.self { return .number(v as! Double) }
        if T.self == String.self { return .string(v as! String) }
        if let j = v as? NativeJSONValue { return j }
        let box = Box(.null); try v.encode(to: NativeJSONValueEncoder(box, path)); return box.value
    }

    func container<Key: CodingKey>(keyedBy: Key.Type) -> KeyedEncodingContainer<Key> {
        if case .object = box.value {} else { box.value = .object([:]) }
        return KeyedEncodingContainer(Keyed<Key>(box, codingPath))
    }
    func unkeyedContainer() -> UnkeyedEncodingContainer { box.value = .array([]); return Unkeyed(box, codingPath) }
    func singleValueContainer() -> SingleValueEncodingContainer { Single(box, codingPath) }

    struct Keyed<Key: CodingKey>: KeyedEncodingContainerProtocol {
        let box: Box; let codingPath: [CodingKey]
        init(_ b: Box, _ p: [CodingKey]) { box = b; codingPath = p }
        mutating func set(_ k: Key, _ v: NativeJSONValue) { if case .object(var o) = box.value { o[k.stringValue] = v; box.value = .object(o) } }
        mutating func encodeNil(forKey key: Key) throws { set(key, .null) }
        mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws { set(key, try NativeJSONValueEncoder.encodeChild(value, codingPath + [key])) }
        mutating func nestedContainer<N: CodingKey>(keyedBy: N.Type, forKey key: Key) -> KeyedEncodingContainer<N> {
            let child = Box(.object([:])); set(key, child.value)
            return KeyedEncodingContainer(Deferred<N>(Keyed<N>(child, codingPath + [key]), { [box] v in
                if case .object(var o) = box.value { o[key.stringValue] = v; box.value = .object(o) } }))
        }
        mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer { fatalError("unused by the document model") }
        mutating func superEncoder() -> Encoder { fatalError("unused") }
        mutating func superEncoder(forKey key: Key) -> Encoder { fatalError("unused") }
    }
    /// Writes a nested keyed container's box back into its parent on every change.
    struct Deferred<Key: CodingKey>: KeyedEncodingContainerProtocol {
        var inner: Keyed<Key>; let commit: (NativeJSONValue) -> Void
        init(_ i: Keyed<Key>, _ c: @escaping (NativeJSONValue) -> Void) { inner = i; commit = c }
        var codingPath: [CodingKey] { inner.codingPath }
        mutating func encodeNil(forKey key: Key) throws { try inner.encodeNil(forKey: key); commit(inner.box.value) }
        mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws { try inner.encode(value, forKey: key); commit(inner.box.value) }
        mutating func nestedContainer<N: CodingKey>(keyedBy: N.Type, forKey key: Key) -> KeyedEncodingContainer<N> { fatalError("unused") }
        mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer { fatalError("unused") }
        mutating func superEncoder() -> Encoder { fatalError("unused") }
        mutating func superEncoder(forKey key: Key) -> Encoder { fatalError("unused") }
    }
    struct Unkeyed: UnkeyedEncodingContainer {
        let box: Box; let codingPath: [CodingKey]
        init(_ b: Box, _ p: [CodingKey]) { box = b; codingPath = p }
        var count: Int { box.value.arrayValue?.count ?? 0 }
        struct Index: CodingKey { var stringValue: String; var intValue: Int?; init(_ i: Int) { intValue = i; stringValue = "\(i)" }
            init?(stringValue: String) { nil }; init?(intValue: Int) { self.init(intValue) } }
        mutating func append(_ v: NativeJSONValue) { if case .array(var a) = box.value { a.append(v); box.value = .array(a) } }
        mutating func encodeNil() throws { append(.null) }
        mutating func encode<T: Encodable>(_ value: T) throws { append(try NativeJSONValueEncoder.encodeChild(value, codingPath + [Index(count)])) }
        mutating func nestedContainer<N: CodingKey>(keyedBy: N.Type) -> KeyedEncodingContainer<N> { fatalError("unused") }
        mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer { fatalError("unused") }
        mutating func superEncoder() -> Encoder { fatalError("unused") }
    }
    struct Single: SingleValueEncodingContainer {
        let box: Box; let codingPath: [CodingKey]
        init(_ b: Box, _ p: [CodingKey]) { box = b; codingPath = p }
        mutating func encodeNil() throws { box.value = .null }
        mutating func encode<T: Encodable>(_ value: T) throws { box.value = try NativeJSONValueEncoder.encodeChild(value, codingPath) }
        mutating func encode(_ value: Bool) throws { box.value = .bool(value) }
        mutating func encode(_ value: String) throws { box.value = .string(value) }
        mutating func encode(_ value: Double) throws { box.value = .number(value) }
        mutating func encode(_ value: Int) throws { box.value = .number(Double(value)) }
    }
}
