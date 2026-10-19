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

/// A JSON value with object key order preserved, so documents round-trip the way
/// `JSON.parse` / `JSON.stringify` keep them.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case let .object(pairs) = self { return pairs.last(where: { $0.0 == key })?.1 }
        return nil
    }

    public var numberValue: Double? { if case let .number(n) = self { return n }; return nil }
    public var stringValue: String? { if case let .string(s) = self { return s }; return nil }
    public var arrayValue: [JSONValue]? { if case let .array(a) = self { return a }; return nil }
    public var isObject: Bool { if case .object = self { return true }; return false }
}

public struct JSONParseError: Error, CustomStringConvertible {
    public let description: String
}

/// Strict RFC 8259 parser (what `JSON.parse` accepts). Duplicate keys: last wins on lookup.
public func parseJSON(_ text: String) throws -> JSONValue {
    var parser = JSONParser(bytes: Array(text.utf8))
    parser.skipWhitespace()
    let value = try parser.parseValue()
    parser.skipWhitespace()
    guard parser.index == parser.bytes.count else { throw JSONParseError(description: "Unexpected non-whitespace character after JSON") }
    return value
}

private struct JSONParser {
    let bytes: [UInt8]
    var index = 0

    mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    mutating func parseValue() throws -> JSONValue {
        guard index < bytes.count else { throw JSONParseError(description: "Unexpected end of JSON input") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return .number(try parseNumber())
        }
    }

    mutating func expect(_ word: String) throws {
        for b in word.utf8 {
            guard index < bytes.count, bytes[index] == b else { throw JSONParseError(description: "Unexpected token in JSON") }
            index += 1
        }
    }

    mutating func parseObject() throws -> JSONValue {
        index += 1
        var pairs: [(String, JSONValue)] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw JSONParseError(description: "Expected property name in JSON") }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw JSONParseError(description: "Expected ':' in JSON") }
            index += 1
            skipWhitespace()
            let value = try parseValue()
            if let existing = pairs.firstIndex(where: { $0.0 == key }) { pairs[existing].1 = value } else { pairs.append((key, value)) }
            skipWhitespace()
            guard index < bytes.count else { throw JSONParseError(description: "Unexpected end of JSON input") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
            throw JSONParseError(description: "Expected ',' or '}' in JSON")
        }
    }

    mutating func parseArray() throws -> JSONValue {
        index += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
        while true {
            skipWhitespace()
            items.append(try parseValue())
            skipWhitespace()
            guard index < bytes.count else { throw JSONParseError(description: "Unexpected end of JSON input") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            throw JSONParseError(description: "Expected ',' or ']' in JSON")
        }
    }

    mutating func parseString() throws -> String {
        index += 1
        var scalars = String.UnicodeScalarView()
        var raw: [UInt8] = []
        func flush() { if !raw.isEmpty { scalars.append(contentsOf: String(decoding: raw, as: UTF8.self).unicodeScalars); raw.removeAll() } }
        while index < bytes.count {
            let b = bytes[index]
            if b == UInt8(ascii: "\"") { index += 1; flush(); return String(scalars) }
            if b < 0x20 { throw JSONParseError(description: "Bad control character in string literal in JSON") }
            if b == UInt8(ascii: "\\") {
                flush()
                index += 1
                guard index < bytes.count else { break }
                let e = bytes[index]
                index += 1
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
                    var code = try hex4()
                    if (0xD800..<0xDC00).contains(code), index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        let save = index
                        index += 2
                        let low = try hex4()
                        if (0xDC00..<0xE000).contains(low) { code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00) } else { index = save }
                    }
                    scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                default: throw JSONParseError(description: "Bad escaped character in JSON")
                }
                continue
            }
            raw.append(b)
            index += 1
        }
        throw JSONParseError(description: "Unterminated string in JSON")
    }

    mutating func hex4() throws -> UInt32 {
        guard index + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else {
            throw JSONParseError(description: "Bad Unicode escape in JSON")
        }
        index += 4
        return v
    }

    mutating func parseNumber() throws -> Double {
        let start = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
        func digits() -> Int { let s = index; while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }; return index - s }
        guard index < bytes.count else { throw JSONParseError(description: "No number after minus sign in JSON") }
        if bytes[index] == UInt8(ascii: "0") { index += 1 } else if digits() == 0 { throw JSONParseError(description: "Unexpected token in JSON") }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") { index += 1; guard digits() > 0 else { throw JSONParseError(description: "Unterminated fractional number in JSON") } }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard digits() > 0 else { throw JSONParseError(description: "Exponent part is missing a number in JSON") }
        }
        return Double(String(decoding: bytes[start..<index], as: UTF8.self)) ?? .nan
    }
}

/// `JSON.stringify` of a value: no whitespace, non-finite numbers as `null`.
public func stringifyJSON(_ value: JSONValue) -> String {
    switch value {
    case .null: return "null"
    case let .bool(b): return b ? "true" : "false"
    case let .number(n): return n.isFinite ? jsNumberToString(n) : "null"
    case let .string(s): return quoteJSONString(s)
    case let .array(items): return "[" + items.map(stringifyJSON).joined(separator: ",") + "]"
    case let .object(pairs): return "{" + pairs.map { quoteJSONString($0.0) + ":" + stringifyJSON($0.1) }.joined(separator: ",") + "}"
    }
}

func quoteJSONString(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 || (0xD800...0xDFFF).contains(scalar.value) {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}

/// `Number.prototype.toString()` (ECMA-262 Number::toString, radix 10).
public func jsNumberToString(_ value: Double) -> String {
    if value.isNaN { return "NaN" }
    if value == 0 { return "0" }
    if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
    if value < 0 { return "-" + jsNumberToString(-value) }
    // Swift's description is the shortest round-tripping digit string, same as JS.
    let (digits, exponent) = shortestDigits(value)
    let k = digits.count
    let n = exponent // value = 0.d1d2..dk * 10^n
    if k <= n && n <= 21 { return digits + String(repeating: "0", count: n - k) }
    if 0 < n && n <= 21 { return String(digits.prefix(n)) + "." + String(digits.dropFirst(n)) }
    if -6 < n && n <= 0 { return "0." + String(repeating: "0", count: -n) + digits }
    let e = n - 1
    let mantissa = k == 1 ? digits : String(digits.prefix(1)) + "." + String(digits.dropFirst(1))
    return mantissa + "e" + (e >= 0 ? "+" : "-") + String(abs(e))
}

/// Shortest decimal digits and the exponent n such that value = 0.DIGITS × 10^n.
private func shortestDigits(_ value: Double) -> (String, Int) {
    let text = "\(value)" // e.g. "1.25", "1e-07", "1.2345e+22", "100.0"
    var mantissa = text
    var exp = 0
    if let eIndex = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        mantissa = String(text[..<eIndex])
        exp = Int(text[text.index(after: eIndex)...]) ?? 0
    }
    var intPart = mantissa
    var fracPart = ""
    if let dot = mantissa.firstIndex(of: ".") {
        intPart = String(mantissa[..<dot])
        fracPart = String(mantissa[mantissa.index(after: dot)...])
    }
    var all = intPart + fracPart
    var pointPos = intPart.count + exp
    while all.hasPrefix("0") && all.count > 1 { all.removeFirst(); pointPos -= 1 }
    while all.hasSuffix("0") && all.count > 1 { all.removeLast() }
    return (all, pointPos)
}

/// `Number.prototype.toFixed(digits)` for |x| < 1e21: exact binary value, ties away from zero.
public func jsToFixed(_ x: Double, _ digits: Int) -> String {
    if x.isNaN { return "NaN" }
    if abs(x) >= 1e21 { return jsNumberToString(x) }
    let negative = x < 0 || (x == 0 && x.sign == .minus && false)
    let a = abs(x)
    // The exact decimal expansion of a double has at most 1074 fractional digits;
    // 80 is plenty to decide a tie at `digits` <= 20 for magnitudes used here.
    let exact = String(format: "%.80f", a)
    let parts = exact.split(separator: ".", omittingEmptySubsequences: false)
    let intDigits = Array(parts[0])
    let frac = Array(parts.count > 1 ? parts[1] : "")
    var kept = intDigits + Array(frac.prefix(digits))
    let rest = frac.dropFirst(digits)
    var roundUp = false
    if let first = rest.first {
        if first > "5" { roundUp = true }
        else if first == "5" { roundUp = true } // ties (and above-tie) round away from zero
    }
    if roundUp {
        var i = kept.count - 1
        while i >= 0 {
            if kept[i] == "9" { kept[i] = "0"; i -= 1 } else { kept[i] = Character(String(kept[i].wholeNumberValue! + 1)); break }
        }
        if i < 0 { kept.insert("1", at: 0) }
    }
    let intCount = kept.count - digits
    var s = String(kept.prefix(intCount))
    if digits > 0 { s += "." + String(kept.suffix(digits)) }
    let isZero = !kept.contains(where: { $0 != "0" })
    return (negative && !isZero ? "-" : "") + s
}

/// `Number(x.toFixed(digits))`.
public func jsRoundTo(_ x: Double, _ digits: Int) -> Double {
    if !x.isFinite { return x }
    return Double(jsToFixed(x, digits)) ?? x
}

/// `Math.round`: nearest, ties toward +∞.
@inline(__always) public func jsMathRound(_ x: Double) -> Double {
    let f = (x).rounded(.down)
    return x - f >= 0.5 ? f + 1 : f
}

/// `Number(value)` for the string branch the readers allow (`raw.trim() !== ""`).
public func jsStringToNumber(_ s: String) -> Double {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return 0 }
    if t == "Infinity" || t == "+Infinity" { return .infinity }
    if t == "-Infinity" { return -.infinity }
    let lower = t.lowercased()
    if lower.hasPrefix("0x") { return UInt64(t.dropFirst(2), radix: 16).map(Double.init) ?? .nan }
    if lower.hasPrefix("0b") { return UInt64(t.dropFirst(2), radix: 2).map(Double.init) ?? .nan }
    if lower.hasPrefix("0o") { return UInt64(t.dropFirst(2), radix: 8).map(Double.init) ?? .nan }
    // Reject Swift-only spellings (inf, nan, hex floats) that JS does not accept.
    let allowed = Set("0123456789+-.eE")
    guard t.allSatisfy({ allowed.contains($0) }) else { return .nan }
    return Double(t) ?? .nan
}

/// `formatFilterNumber` in the engine mixer: `Number(value.toFixed(6)).toString()`.
public func formatFilterNumber(_ value: Double) -> String { jsNumberToString(jsRoundTo(value, 6)) }
