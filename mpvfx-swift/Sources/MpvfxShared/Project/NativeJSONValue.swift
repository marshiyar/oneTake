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
// Untyped JSON values (`unknown` / string-keyed record payloads) as the document validators read them.
import Foundation

public indirect enum NativeJSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([NativeJSONValue]), object(NativeJSONObject)

    public init(from decoder: Decoder) throws {
        if let d = decoder as? NativeJSONValueDecoder { self = d.value; return }
        if let k = try? decoder.container(keyedBy: NativeAnyCodingKey.self) {
            var o = NativeJSONObject()
            for key in k.allKeys { o[key.stringValue] = try k.decode(NativeJSONValue.self, forKey: key) }
            self = .object(o); return
        }
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { self = .array(try c.decode([NativeJSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// JS Math.round: floor(x + 0.5).
@inlinable public func jsMathRound(_ x: Double) -> Double {
    guard x.isFinite else { return x }
    if x < 0 && x >= -0.5 { return -0.0 }
    let f = x.rounded(.down)
    return x - f >= 0.5 ? f + 1 : f
}
/// JS `%` (sign follows dividend).
@inlinable public func jsRemainder(_ a: Double, _ b: Double) -> Double { a.truncatingRemainder(dividingBy: b) }
/// JS Number.isInteger.
@inlinable public func jsIsInteger(_ x: Double) -> Bool { x.isFinite && x.rounded(.towardZero) == x }
public let jsMaxSafeInteger: Double = 9_007_199_254_740_991

/// JS Number.parseFloat: skips leading whitespace, takes the longest valid decimal prefix
/// (incl. "Infinity"), else NaN.
public func jsParseFloat(_ s: String) -> Double {
    let chars = Array(s.drop(while: { $0.isWhitespace }).unicodeScalars)
    var i = 0
    func peek() -> Unicode.Scalar? { i < chars.count ? chars[i] : nil }
    var out = ""
    if let c = peek(), c == "+" || c == "-" { out.unicodeScalars.append(c); i += 1 }
    if String(String.UnicodeScalarView(chars[i...])).hasPrefix("Infinity") { return out == "-" ? -.infinity : .infinity }
    var digits = false
    while let c = peek(), ("0"..."9").contains(c) { out.unicodeScalars.append(c); i += 1; digits = true }
    if peek() == "." { out += "."; i += 1
        while let c = peek(), ("0"..."9").contains(c) { out.unicodeScalars.append(c); i += 1; digits = true } }
    guard digits else { return .nan }
    if let c = peek(), c == "e" || c == "E" {
        var exp = "e"; var j = i + 1
        if j < chars.count, chars[j] == "+" || chars[j] == "-" { exp.unicodeScalars.append(chars[j]); j += 1 }
        var expDigits = false
        while j < chars.count, ("0"..."9").contains(chars[j]) { exp.unicodeScalars.append(chars[j]); j += 1; expDigits = true }
        if expDigits { out += exp }
    }
    if out.hasSuffix(".") { out.removeLast() }
    if out == "+" || out == "-" || out.isEmpty { return .nan }
    return Double(out) ?? .nan
}

/// JS Number(string) = ECMA-262 StringToNumber: JS whitespace trim (jsTrim: includes U+FEFF, excludes U+0085),
/// "" -> 0, unsigned 0x/0o/0b integers, [+-]Infinity, StrDecimalLiteral with ASCII digits only; else NaN.
/// Swift's Double(String) is used only after the text is validated (it would accept "inf", "nan", "0x1p3", "+-1"...).
/// Verified against Node in Tests/MpvfxSharedTests/Export (exportParity.json `authored`).
public func jsNumber(_ s: String) -> Double {
    let t = Array(jsTrim(s).utf8)
    if t.isEmpty { return 0 }
    if t.count > 2, t[0] == UInt8(ascii: "0") {
        var radix: Double = 0
        switch t[1] {
        case UInt8(ascii: "x"), UInt8(ascii: "X"): radix = 16
        case UInt8(ascii: "o"), UInt8(ascii: "O"): radix = 8
        case UInt8(ascii: "b"), UInt8(ascii: "B"): radix = 2
        default: break
        }
        if radix > 0 {
            var v = 0.0   // exact below 2^53; above, JS rounds the whole digit string once (documented gap)
            for c in t[2...] {
                let d: Double
                switch c {
                case 48...57: d = Double(c - 48)
                case 97...102: d = Double(c - 87)
                case 65...70: d = Double(c - 55)
                default: return .nan
                }
                if d >= radix { return .nan }
                v = v * radix + d
            }
            return v
        }
    }
    var i = 0
    var neg = false
    if t[0] == UInt8(ascii: "+") || t[0] == UInt8(ascii: "-") { neg = t[0] == UInt8(ascii: "-"); i = 1 }
    if String(decoding: t[i...], as: UTF8.self) == "Infinity" { return neg ? -.infinity : .infinity }
    func digits(_ j: inout Int) -> Int { let st = j; while j < t.count, t[j] >= 48, t[j] <= 57 { j += 1 }; return j - st }
    var j = i
    let intDigits = digits(&j)
    var fracDigits = 0
    var dotAt = -1
    if j < t.count, t[j] == UInt8(ascii: ".") { dotAt = j; j += 1; fracDigits = digits(&j) }
    if intDigits + fracDigits == 0 { return .nan }
    let mantissaEnd = j
    if j < t.count, t[j] == UInt8(ascii: "e") || t[j] == UInt8(ascii: "E") {
        j += 1
        if j < t.count, t[j] == UInt8(ascii: "+") || t[j] == UInt8(ascii: "-") { j += 1 }
        if digits(&j) == 0 { return .nan }
    }
    if j != t.count { return .nan }
    // Normalise "5." / ".5" to "5.0" / "0.5" so the strict parse below sees a plain literal.
    var m = String(decoding: t[i..<mantissaEnd], as: UTF8.self)
    if dotAt >= 0 { if intDigits == 0 { m = "0" + m }; if fracDigits == 0 { m += "0" } }
    guard let v = Double(m + String(decoding: t[mantissaEnd...], as: UTF8.self)) else { return .nan }
    return neg ? -v : v
}

/// Deterministic replacement for `a.localeCompare(b)` as shared/project orders ids everywhere in
/// shared/project: no locales, no options -> ICU default collation (root/UCA, strength
/// tertiary, alternate non-ignorable, no numeric ordering, so "10" < "9").
/// Uses only Unicode canonical decomposition (not locale APIs), so the order is identical on
/// every OS. Simplified UCA:
///  - primary: whitespace/punctuation/symbols (CLDR root order for ASCII) < digits < letters
///    (case-folded); other scalars after all of these, by code point.
///  - secondary: combining marks after NFD (accents); unaccented < accented.
///  - tertiary: lowercase < uppercase.
/// Levels are compared over the whole string in turn (primary first), as UCA does.
/// Returns -1, 0, 1. Gaps vs ICU are listed in docs/IMPLEMENTATION_NOTES.md.
public func jsLocaleCompare(_ a: String, _ b: String) -> Int {
    let l = collationKey(a), r = collationKey(b)
    for level in 0..<3 {
        let x = l[level], y = r[level]
        for (p, q) in zip(x, y) where p != q { return p < q ? -1 : 1 }
        if x.count != y.count { return x.count < y.count ? -1 : 1 }
    }
    return 0
}

private let collationSymbolOrder: [Unicode.Scalar] = Array("\t\n\r _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$".unicodeScalars)

private func collationKey(_ s: String) -> [[UInt32]] {
    var primary: [UInt32] = [], secondary: [UInt32] = [], tertiary: [UInt32] = []
    for c in s.decomposedStringWithCanonicalMapping.unicodeScalars {
        if (0x0300...0x036F).contains(c.value) {        // combining diacritic: secondary weight only
            secondary.append(c.value); continue
        }
        let p: UInt32, t: UInt32
        if let i = collationSymbolOrder.firstIndex(of: c) { p = 0x1000 + UInt32(i); t = 0 }
        else if ("0"..."9").contains(c) { p = 0x2000 + c.value; t = 0 }
        else if ("a"..."z").contains(c) { p = 0x3000 + c.value; t = 0 }
        else if ("A"..."Z").contains(c) { p = 0x3000 + c.value + 32; t = 2 }
        else if c == "\u{DF}" {                          // ß expands to "ss" (UCA), tertiary after both s and S (ICU: ss < SS < ß)
            primary.append(0x3000 + 0x73); secondary.append(0); tertiary.append(3)
            p = 0x3000 + 0x73; t = 3
        }
        else if (0x03B1...0x03C9).contains(c.value) { p = 0x8000 + c.value; t = 0 }          // Greek lowercase
        else if (0x0391...0x03A9).contains(c.value) { p = 0x8000 + c.value + 0x20; t = 2 }   // Greek uppercase
        else { p = 0x10000 + c.value; t = 0 }   // other scripts (incl. CJK): code-point order after Greek
        primary.append(p); secondary.append(0); tertiary.append(t)
    }
    return [primary, secondary, tertiary]
}

/// JS `String(n)` / JSON.stringify number formatting (ECMAScript Number::toString, radix 10).
/// Uses Swift's shortest round-trip digits (same digit choice as JS) and re-applies JS layout rules.
public func jsNumberString(_ n: Double) -> String {
    if n.isNaN { return "NaN" }
    if n.isInfinite { return n < 0 ? "-Infinity" : "Infinity" }
    if n == 0 { return "0" }   // also -0
    let neg = n < 0
    // Swift description: "123.45", "1e-07", "1.5e+21", "0.001" ...
    var desc = "\(abs(n))"
    var exp10 = 0
    if let e = desc.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        exp10 = Int(desc[desc.index(after: e)...])!
        desc = String(desc[..<e])
    }
    var intPart = desc, fracPart = ""
    if let dot = desc.firstIndex(of: ".") { intPart = String(desc[..<dot]); fracPart = String(desc[desc.index(after: dot)...]) }
    var digits = intPart + fracPart
    var pointPos = intPart.count + exp10          // decimal point position relative to digits start
    while digits.hasPrefix("0") && digits.count > 1 { digits.removeFirst(); pointPos -= 1 }
    while digits.hasSuffix("0") && digits.count > 1 { digits.removeLast() }
    let k = digits.count, nn = pointPos
    var out: String
    if k <= nn && nn <= 21 { out = digits + String(repeating: "0", count: nn - k) }
    else if 0 < nn && nn <= 21 { let i = digits.index(digits.startIndex, offsetBy: nn); out = digits[..<i] + "." + digits[i...] }
    else if -6 < nn && nn <= 0 { out = "0." + String(repeating: "0", count: -nn) + digits }
    else {
        let e = nn - 1
        let es = e >= 0 ? "+\(e)" : "\(e)"
        out = k == 1 ? digits + "e" + es : String(digits.first!) + "." + digits.dropFirst() + "e" + es
    }
    return neg ? "-" + out : out
}

/// JSON.stringify(value, null, indent) for NativeJSONValue. Object keys are emitted in JS own-property order.
public func jsJSONStringify(_ v: NativeJSONValue, indent: Int = 0) -> String {
    func esc(_ s: String) -> String {
        var o = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": o += "\\\""; case "\\": o += "\\\\"
            case "\n": o += "\\n"; case "\r": o += "\\r"; case "\t": o += "\\t"
            case "\u{08}": o += "\\b"; case "\u{0C}": o += "\\f"
            default:
                if u.value < 0x20 { o += String(format: "\\u%04x", u.value) } else { o.unicodeScalars.append(u) }
            }
        }
        return o + "\""
    }
    func go(_ v: NativeJSONValue, _ level: Int) -> String {
        let pad = indent > 0 ? "\n" + String(repeating: " ", count: indent * (level + 1)) : ""
        let end = indent > 0 ? "\n" + String(repeating: " ", count: indent * level) : ""
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n.isFinite ? jsNumberString(n) : "null"
        case .string(let s): return esc(s)
        case .array(let a):
            if a.isEmpty { return "[]" }
            return "[" + a.map { pad + go($0, level + 1) }.joined(separator: ",") + end + "]"
        case .object(let o):
            if o.isEmpty { return "{}" }
            let sep = indent > 0 ? ": " : ":"
            return "{" + o.map { pad + esc($0.key) + sep + go($0.value, level + 1) }.joined(separator: ",") + end + "}"
        }
    }
    return go(v, 0)
}

/// JS default Array.prototype.sort order for strings (UTF-16 code units).
public func jsCodeUnitLess(_ a: String, _ b: String) -> Bool { a.utf16.lexicographicallyPrecedes(b.utf16) }

extension NativeJSONValue {
    /// Object member access; setting on a non-object is a no-op, setting nil removes the key (JS `delete`).
    public subscript(key: String) -> NativeJSONValue? {
        get { if case .object(let o) = self { return o[key] }; return nil }
        set { if case .object(var o) = self { o[key] = newValue; self = .object(o) } }
    }
    /// Array element access; out-of-range reads return nil, writes to a non-array or out of range are no-ops.
    public subscript(index: Int) -> NativeJSONValue? {
        get { if case .array(let a) = self, a.indices.contains(index) { return a[index] }; return nil }
        set { if case .array(var a) = self, a.indices.contains(index), let v = newValue { a[index] = v; self = .array(a) } }
    }
    /// Parse JSON text (JSON.parse).
    public static func parse(_ text: String) throws -> NativeJSONValue {
        try NativeJSONTextParser.parse(text)
    }
    public var isRecord: Bool { if case .object = self { return true }; return false }
    public var arrayValue: [NativeJSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: NativeJSONObject? { if case .object(let o) = self { return o }; return nil }
    public var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }

    /// Encode any Encodable into a JSON value (nil optionals are omitted; NaN/±Infinity are kept as numbers).
    public static func from<T: Encodable>(_ value: T) throws -> NativeJSONValue {
        try NativeJSONValueEncoder.encode(value)
    }
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try NativeJSONValueDecoder.decode(T.self, from: self)
    }
}
