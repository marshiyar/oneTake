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
// Order-preserving JSON values used by the desktop shell (library views, save-barrier messages).
// Objects keep key order (JSONObject); binary data serialises as {"__ab": base64}.
import Foundation

public struct JSONObject: Equatable, Sendable, Sequence, ExpressibleByDictionaryLiteral {
    public private(set) var entries: [(key: String, value: JSONValue)] = []
    public init() {}
    public init(dictionaryLiteral elements: (String, JSONValue)...) { for (k, v) in elements { self[k] = v } }
    public init(_ pairs: [(String, JSONValue)]) { for (k, v) in pairs { self[k] = v } }
    public subscript(key: String) -> JSONValue? {
        get { entries.first { $0.key == key }?.value }
        set {
            if let i = entries.firstIndex(where: { $0.key == key }) {
                if let newValue { entries[i].value = newValue } else { entries.remove(at: i) }
            } else if let newValue { entries.append((key, newValue)) }
        }
    }
    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    public var keys: [String] { entries.map(\.key) }
    public func makeIterator() -> IndexingIterator<[(key: String, value: JSONValue)]> { entries.makeIterator() }
    /// Order-sensitive: same keys in the same order with equal values.
    public static func == (a: JSONObject, b: JSONObject) -> Bool {
        a.entries.count == b.entries.count && zip(a.entries, b.entries).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }
}

public enum JSONValue: Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object(JSONObject)
    case bytes(Data)

    public subscript(key: String) -> JSONValue? { if case .object(let o) = self { return o[key] }; return nil }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var number: Double? { if case .number(let n) = self { return n }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var isNull: Bool { self == .null }
}

public struct JSONParseError: Error, CustomStringConvertible {
    public let offset: Int; public let reason: String
    public var description: String { "Invalid JSON at \(offset): \(reason)" }
}

extension JSONValue {
    public static func parse(_ text: String) throws -> JSONValue {
        var p = Parser(bytes: Array(text.utf8))
        p.ws()
        let v = try p.value()
        p.ws()
        guard p.i == p.bytes.count else { throw p.err("trailing characters") }
        return v
    }

    public func serialized() -> String { var out = ""; write(into: &out); return out }

    func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += Self.jsNumber(n)
        case .string(let s): Self.quote(s, into: &out)
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() { if i > 0 { out += "," }; v.write(into: &out) }
            out += "]"
        case .object(let o):
            out += "{"
            for (i, e) in o.entries.enumerated() {
                if i > 0 { out += "," }
                Self.quote(e.key, into: &out); out += ":"; e.value.write(into: &out)
            }
            out += "}"
        case .bytes(let d): out += "{\"__ab\":\"" + d.base64EncodedString() + "\"}"
        }
    }

    /// Number formatting as JSON.stringify (ECMAScript Number::toString); non-finite -> null.
    static func jsNumber(_ n: Double) -> String {
        guard n.isFinite else { return "null" }
        if n == 0 { return "0" }   // also -0, as JS
        if n == n.rounded(), abs(n) <= 9007199254740992 { return String(format: "%.0f", n) }   // exact below 2^53
        // Swift's description is the shortest round-trip digits, like JS; fix exponent style.
        var s = "\(n)"
        if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            var mant = String(s[..<e]); var exp = String(s[s.index(after: e)...])
            if mant.hasSuffix(".0") { mant.removeLast(2) }
            let neg = exp.hasPrefix("-")
            exp = String(exp.drop { $0 == "-" || $0 == "+" }.drop { $0 == "0" })
            let ev = Int(exp) ?? 0
            if neg && ev <= 6 {               // JS prints 1e-6 .. as decimals
                let digits = mant.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "-", with: "")
                return (n < 0 ? "-" : "") + "0." + String(repeating: "0", count: ev - 1) + digits
            }
            if !neg && ev < 21 {
                let digits = mant.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "-", with: "")
                let intLen = ev + 1
                let body = digits.count > intLen ? digits.prefix(intLen) + "." + digits.dropFirst(intLen)
                                                 : digits + String(repeating: "0", count: intLen - digits.count)
                return (n < 0 ? "-" : "") + body
            }
            s = mant + "e" + (neg ? "-" : "+") + (exp.isEmpty ? "0" : exp)
        }
        return s
    }

    static func quote(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) }
                else { out.unicodeScalars.append(u) }
            }
        }
        out += "\""
    }

    struct Parser {
        let bytes: [UInt8]; var i = 0
        init(bytes: [UInt8]) { self.bytes = bytes }
        func err(_ r: String) -> JSONParseError { JSONParseError(offset: i, reason: r) }
        mutating func ws() { while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 } }
        mutating func lit(_ s: String, _ v: JSONValue) throws -> JSONValue {
            let u = Array(s.utf8)
            guard i + u.count <= bytes.count, Array(bytes[i..<i + u.count]) == u else { throw err("bad literal") }
            i += u.count; return v
        }
        mutating func value(depth: Int = 0) throws -> JSONValue {
            guard depth < 512 else { throw err("nesting too deep") }
            guard i < bytes.count else { throw err("unexpected end") }
            switch bytes[i] {
            case UInt8(ascii: "n"): return try lit("null", .null)
            case UInt8(ascii: "t"): return try lit("true", .bool(true))
            case UInt8(ascii: "f"): return try lit("false", .bool(false))
            case UInt8(ascii: "\""): return .string(try str())
            case UInt8(ascii: "["):
                i += 1; ws(); var a: [JSONValue] = []
                if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                while true {
                    ws(); a.append(try value(depth: depth + 1)); ws()
                    guard i < bytes.count else { throw err("unterminated array") }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                    throw err("expected , or ]")
                }
            case UInt8(ascii: "{"):
                i += 1; ws(); var o = JSONObject()
                if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
                while true {
                    ws(); guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw err("expected key") }
                    let k = try str(); ws()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw err("expected :") }
                    i += 1; ws()
                    o[k] = try value(depth: depth + 1)   // duplicate key: last value, first position (JSON.parse)
                    ws()
                    guard i < bytes.count else { throw err("unterminated object") }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "}") {
                        i += 1
                        if o.count == 1, case .string(let b64)? = o["__ab"] {
                            guard let d = Data(base64Encoded: b64) else { throw err("bad ArrayBuffer") }
                            return .bytes(d)
                        }
                        return .object(o)
                    }
                    throw err("expected , or }")
                }
            default: return .number(try num())
            }
        }
        mutating func num() throws -> Double {
            let start = i
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
            while i < bytes.count, (bytes[i] >= 0x30 && bytes[i] <= 0x39) || [UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"), UInt8(ascii: "+"), UInt8(ascii: "-")].contains(bytes[i]) { i += 1 }
            guard let d = Double(String(decoding: bytes[start..<i], as: UTF8.self)), i > start else { i = start; throw err("bad number") }
            return d
        }
        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16) else { throw err("bad \\u escape") }
            i += 4; return v
        }
        mutating func str() throws -> String {
            i += 1
            var scalars = String.UnicodeScalarView()
            var run = i
            func flush(_ end: Int) { scalars.append(contentsOf: String(decoding: bytes[run..<end], as: UTF8.self).unicodeScalars) }
            while i < bytes.count {
                let c = bytes[i]
                if c == UInt8(ascii: "\"") { flush(i); i += 1; return String(scalars) }
                if c < 0x20 { throw err("control character in string") }
                if c != UInt8(ascii: "\\") { i += 1; continue }
                flush(i); i += 1
                guard i < bytes.count else { break }
                let e = bytes[i]; i += 1
                switch e {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    var v = try hex4()
                    if (0xD800...0xDBFF).contains(v), i + 6 <= bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                        let save = i; i += 2
                        let lo = try hex4()
                        if (0xDC00...0xDFFF).contains(lo) { v = 0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00) } else { i = save }
                    }
                    scalars.append(Unicode.Scalar(v) ?? "\u{FFFD}")   // lone surrogate: Swift strings cannot hold it
                default: throw err("bad escape")
                }
                run = i
            }
            throw err("unterminated string")
        }
    }
}
