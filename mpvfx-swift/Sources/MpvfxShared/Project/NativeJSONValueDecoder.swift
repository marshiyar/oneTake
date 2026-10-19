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
// NativeJSONValue -> Decodable without going through JSON text. Keyed containers list keys in the object's JS order,
// so ordered types (NativeOrderedMap, spread-key records) keep it, and non-finite numbers decode as Double.
// Also: JSON text -> NativeJSONValue with JSON.parse semantics (key order kept; a duplicate key keeps its first
// position and takes the last value).
import Foundation

struct NativeJSONDecodingError: Error, CustomStringConvertible { let description: String }

final class NativeJSONValueDecoder: Decoder {
    let value: NativeJSONValue; let codingPath: [CodingKey]; let userInfo: [CodingUserInfoKey: Any] = [:]
    init(_ v: NativeJSONValue, _ p: [CodingKey] = []) { value = v; codingPath = p }
    static func decode<T: Decodable>(_ t: T.Type, from v: NativeJSONValue) throws -> T { try decodeChild(t, v, []) }

    fileprivate static func mismatch<T>(_ t: T.Type, _ path: [CodingKey], _ v: NativeJSONValue) -> DecodingError {
        .typeMismatch(t, .init(codingPath: path, debugDescription: "Expected \(t), found \(v)"))
    }
    fileprivate static func decodeChild<T: Decodable>(_ t: T.Type, _ v: NativeJSONValue, _ path: [CodingKey]) throws -> T {
        if T.self == NativeJSONValue.self { return v as! T }
        if T.self == Double.self { guard case .number(let n) = v else { throw mismatch(t, path, v) }; return n as! T }
        if T.self == Bool.self { guard case .bool(let b) = v else { throw mismatch(t, path, v) }; return b as! T }
        if T.self == String.self { guard case .string(let s) = v else { throw mismatch(t, path, v) }; return s as! T }
        return try T(from: NativeJSONValueDecoder(v, path))
    }
    func container<Key: CodingKey>(keyedBy: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let o) = value else { throw Self.mismatch([String: NativeJSONValue].self, codingPath, value) }
        return KeyedDecodingContainer(Keyed<Key>(o, codingPath))
    }
    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard case .array(let a) = value else { throw Self.mismatch([NativeJSONValue].self, codingPath, value) }
        return Unkeyed(a, codingPath)
    }
    func singleValueContainer() throws -> SingleValueDecodingContainer { Single(value, codingPath) }

    struct Keyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
        let o: NativeJSONObject; let codingPath: [CodingKey]
        init(_ o: NativeJSONObject, _ p: [CodingKey]) { self.o = o; codingPath = p }
        var allKeys: [Key] { o.keys.compactMap { Key(stringValue: $0) } }
        func contains(_ key: Key) -> Bool { o[key.stringValue] != nil }
        func get(_ key: Key) throws -> NativeJSONValue {
            guard let v = o[key.stringValue] else { throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "Missing key \(key.stringValue)")) }
            return v
        }
        func decodeNil(forKey key: Key) throws -> Bool { if case .null = try get(key) { return true }; return false }
        func decode<T: Decodable>(_ t: T.Type, forKey key: Key) throws -> T { try NativeJSONValueDecoder.decodeChild(t, try get(key), codingPath + [key]) }
        func nestedContainer<N: CodingKey>(keyedBy: N.Type, forKey key: Key) throws -> KeyedDecodingContainer<N> {
            try NativeJSONValueDecoder(try get(key), codingPath + [key]).container(keyedBy: N.self)
        }
        func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer { try NativeJSONValueDecoder(try get(key), codingPath + [key]).unkeyedContainer() }
        func superDecoder() throws -> Decoder { NativeJSONValueDecoder(.object(o), codingPath) }
        func superDecoder(forKey key: Key) throws -> Decoder { NativeJSONValueDecoder(try get(key), codingPath + [key]) }
    }
    struct Unkeyed: UnkeyedDecodingContainer {
        let a: [NativeJSONValue]; let codingPath: [CodingKey]; var currentIndex = 0
        init(_ a: [NativeJSONValue], _ p: [CodingKey]) { self.a = a; codingPath = p }
        var count: Int? { a.count }
        var isAtEnd: Bool { currentIndex >= a.count }
        mutating func next() throws -> NativeJSONValue {
            guard !isAtEnd else { throw DecodingError.valueNotFound(NativeJSONValue.self, .init(codingPath: codingPath, debugDescription: "Unkeyed container is at end")) }
            defer { currentIndex += 1 }; return a[currentIndex]
        }
        mutating func decodeNil() throws -> Bool {
            if !isAtEnd, case .null = a[currentIndex] { currentIndex += 1; return true }; return false
        }
        mutating func decode<T: Decodable>(_ t: T.Type) throws -> T {
            let path = codingPath + [NativeAnyCodingKey(String(currentIndex))]
            return try NativeJSONValueDecoder.decodeChild(t, try next(), path)
        }
        mutating func nestedContainer<N: CodingKey>(keyedBy: N.Type) throws -> KeyedDecodingContainer<N> { try NativeJSONValueDecoder(try next(), codingPath).container(keyedBy: N.self) }
        mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer { try NativeJSONValueDecoder(try next(), codingPath).unkeyedContainer() }
        mutating func superDecoder() throws -> Decoder { NativeJSONValueDecoder(try next(), codingPath) }
    }
    struct Single: SingleValueDecodingContainer {
        let v: NativeJSONValue; let codingPath: [CodingKey]
        init(_ v: NativeJSONValue, _ p: [CodingKey]) { self.v = v; codingPath = p }
        func decodeNil() -> Bool { if case .null = v { return true }; return false }
        func decode<T: Decodable>(_ t: T.Type) throws -> T { try NativeJSONValueDecoder.decodeChild(t, v, codingPath) }
        func decode(_ t: Int.Type) throws -> Int {
            guard case .number(let n) = v, n.rounded(.towardZero) == n, let i = Int(exactly: n) else { throw NativeJSONValueDecoder.mismatch(t, codingPath, v) }
            return i
        }
    }
}

/// JSON.parse for NativeJSONValue (standard library only).
struct NativeJSONTextParser {
    private let s: [UInt8]; private var i = 0
    init(_ text: String) { s = Array(text.utf8) }
    static func parse(_ text: String) throws -> NativeJSONValue {
        var p = NativeJSONTextParser(text)
        p.ws(); let v = try p.value(); p.ws()
        if p.i != p.s.count { throw p.err("Unexpected trailing input") }
        return v
    }
    private func err(_ m: String) -> NativeJSONDecodingError { .init(description: "\(m) at byte \(i)") }
    private mutating func ws() { while i < s.count, [0x20, 0x09, 0x0A, 0x0D].contains(s[i]) { i += 1 } }
    private mutating func lit(_ w: String, _ v: NativeJSONValue) throws -> NativeJSONValue {
        let b = Array(w.utf8)
        guard i + b.count <= s.count, Array(s[i..<i + b.count]) == b else { throw err("Unexpected token") }
        i += b.count; return v
    }
    private mutating func value() throws -> NativeJSONValue {
        guard i < s.count else { throw err("Unexpected end of JSON input") }
        switch s[i] {
        case UInt8(ascii: "{"):
            i += 1; ws(); var o = NativeJSONObject()
            if i < s.count, s[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
            while true {
                ws(); guard i < s.count, s[i] == UInt8(ascii: "\"") else { throw err("Expected property name") }
                let k = try string(); ws()
                guard i < s.count, s[i] == UInt8(ascii: ":") else { throw err("Expected ':'") }
                i += 1; ws(); o[k] = try value(); ws()
                guard i < s.count else { throw err("Unexpected end of JSON input") }
                if s[i] == UInt8(ascii: ",") { i += 1; continue }
                if s[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
                throw err("Expected ',' or '}'")
            }
        case UInt8(ascii: "["):
            i += 1; ws(); var a: [NativeJSONValue] = []
            if i < s.count, s[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
            while true {
                ws(); a.append(try value()); ws()
                guard i < s.count else { throw err("Unexpected end of JSON input") }
                if s[i] == UInt8(ascii: ",") { i += 1; continue }
                if s[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                throw err("Expected ',' or ']'")
            }
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): return try lit("true", .bool(true))
        case UInt8(ascii: "f"): return try lit("false", .bool(false))
        case UInt8(ascii: "n"): return try lit("null", .null)
        default: return .number(try number())
        }
    }
    private mutating func number() throws -> Double {
        let start = i
        func digits() -> Int { let b = i; while i < s.count, s[i] >= 48, s[i] <= 57 { i += 1 }; return i - b }
        if i < s.count, s[i] == UInt8(ascii: "-") { i += 1 }
        guard i < s.count else { throw err("Unexpected end of JSON input") }
        if s[i] == 48 { i += 1 } else if digits() == 0 { throw err("Unexpected token") }
        if i < s.count, s[i] == UInt8(ascii: ".") { i += 1; if digits() == 0 { throw err("Unterminated fractional number") } }
        if i < s.count, s[i] == UInt8(ascii: "e") || s[i] == UInt8(ascii: "E") {
            i += 1; if i < s.count, s[i] == UInt8(ascii: "+") || s[i] == UInt8(ascii: "-") { i += 1 }
            if digits() == 0 { throw err("Exponent part is missing a number") }
        }
        return Double(String(decoding: s[start..<i], as: UTF8.self))!
    }
    private mutating func hex4() throws -> UInt32 {
        guard i + 4 <= s.count, let v = UInt32(String(decoding: s[i..<i + 4], as: UTF8.self), radix: 16) else { throw err("Bad Unicode escape") }
        i += 4; return v
    }
    private mutating func string() throws -> String {
        i += 1; var out = String.UnicodeScalarView(); var runStart = i
        func flush(_ end: Int) { out.append(contentsOf: String(decoding: s[runStart..<end], as: UTF8.self).unicodeScalars) }
        while true {
            guard i < s.count else { throw err("Unterminated string in JSON") }
            let c = s[i]
            if c == UInt8(ascii: "\"") { flush(i); i += 1; return String(out) }
            if c < 0x20 { throw err("Bad control character in string literal") }
            if c != UInt8(ascii: "\\") { i += 1; continue }
            flush(i); i += 1
            guard i < s.count else { throw err("Unterminated string in JSON") }
            let e = s[i]; i += 1
            switch e {
            case UInt8(ascii: "\""): out.append("\""); case UInt8(ascii: "\\"): out.append("\\"); case UInt8(ascii: "/"): out.append("/")
            case UInt8(ascii: "b"): out.append("\u{08}"); case UInt8(ascii: "f"): out.append("\u{0C}")
            case UInt8(ascii: "n"): out.append("\n"); case UInt8(ascii: "r"): out.append("\r"); case UInt8(ascii: "t"): out.append("\t")
            case UInt8(ascii: "u"):
                var u = try hex4()
                if (0xD800...0xDBFF).contains(u), i + 6 <= s.count, s[i] == UInt8(ascii: "\\"), s[i + 1] == UInt8(ascii: "u") {
                    let save = i; i += 2; let lo = try hex4()
                    if (0xDC00...0xDFFF).contains(lo) { u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00) } else { i = save }
                }
                // Lone surrogates cannot live in a Swift String; they become U+FFFD (JS would keep the code unit).
                out.append(Unicode.Scalar(u) ?? "\u{FFFD}")
            default: throw err("Bad escaped character in JSON")
            }
            runStart = i
        }
    }
}
