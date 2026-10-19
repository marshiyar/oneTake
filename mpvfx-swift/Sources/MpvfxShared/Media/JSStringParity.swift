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
// JS string helpers shared by the media port (and shared/project's jsTrimmedIsEmpty).
import Foundation

/// ECMAScript WhiteSpace + LineTerminator (String.prototype.trim). Differs from Foundation's
/// `.whitespacesAndNewlines`: JS includes U+FEFF and excludes U+0085 (NEL).
func jsIsTrimmable(_ u: UInt16) -> Bool {
    switch u {
    case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: return true
    default: return false
    }
}

/// String.prototype.trim, on UTF-16 code units.
public func jsTrim(_ s: String) -> String {
    let u = Array(s.utf16)
    var a = 0, b = u.count
    while a < b && jsIsTrimmable(u[a]) { a += 1 }
    while b > a && jsIsTrimmable(u[b - 1]) { b -= 1 }
    return String(decoding: u[a..<b], as: UTF16.self)
}

/// Math.max(a, b): NaN if either is NaN (Swift.max would return the other operand).
@inlinable public func jsMathMax(_ a: Double, _ b: Double) -> Double {
    if a.isNaN || b.isNaN { return .nan }
    if a == 0 && b == 0 { return a.sign == .minus ? b : a }   // max(-0, +0) is +0
    return a > b ? a : b
}

/// JS `URIError: URI malformed`, thrown by encodeURIComponent on a lone UTF-16 surrogate.
public struct JSURIError: Error, Equatable, CustomStringConvertible {
    public let message = "URI malformed"
    public var description: String { "URIError: \(message)" }
}

private func percentEncode(_ scalar: Unicode.Scalar, into out: inout String) {
    for b in String(scalar).utf8 {
        switch b {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "!"), UInt8(ascii: "~"),
             UInt8(ascii: "*"), UInt8(ascii: "'"), UInt8(ascii: "("), UInt8(ascii: ")"):
            out.unicodeScalars.append(Unicode.Scalar(b))
        default:
            let hex = Array("0123456789ABCDEF".utf8)
            out += "%" + String(decoding: [hex[Int(b >> 4)], hex[Int(b & 15)]], as: UTF8.self)
        }
    }
}

/// encodeURIComponent over UTF-16 code units (a JS string), so lone surrogates are representable: it throws
/// JSURIError exactly where JS throws (at the first lone surrogate). Otherwise UTF-8 percent-encoding of everything
/// except A–Z a–z 0–9 - _ . ! ~ * ' ( ), uppercase hex.
public func jsEncodeURIComponent(utf16 units: [UInt16]) throws -> String {
    var out = "", i = 0
    while i < units.count {
        let u = units[i]
        if UTF16.isLeadSurrogate(u) {
            guard i + 1 < units.count, UTF16.isTrailSurrogate(units[i + 1]) else { throw JSURIError() }
            percentEncode(Unicode.Scalar(UTF16.decode(UTF16.EncodedScalar([u, units[i + 1]]))), into: &out); i += 2
        } else if UTF16.isTrailSurrogate(u) {
            throw JSURIError()
        } else {
            percentEncode(Unicode.Scalar(u)!, into: &out); i += 1
        }
    }
    return out
}

/// String convenience. A Swift String cannot hold a lone surrogate (it was replaced by U+FFFD when the String was
/// made), so this cannot throw; callers holding raw JS strings / UTF-16 must use the `utf16:` overload.
public func jsEncodeURIComponent(_ s: String) -> String { try! jsEncodeURIComponent(utf16: Array(s.utf16)) }

/// JS `base ** exponent` special cases on top of Foundation `pow` (the app is fully native; no JS-engine code is
/// copied). ECMA-262 Number::exponentiate differs from IEEE/C pow only here: a NaN exponent gives NaN (C pow(1, NaN)
/// is 1) and (±1) ** ±Infinity is NaN (C gives 1). Finite results may differ from Node/V8 in the last ULP; the
/// measured drift is recorded and pinned in MediaSwiftOnlyParityTests (see docs/IMPLEMENTATION_NOTES.md).
public func jsExponentiate(_ base: Double, _ exponent: Double) -> Double {
    if exponent.isNaN { return .nan }
    if exponent.isInfinite && (base == 1 || base == -1) { return .nan }
    return Foundation.pow(base, exponent)
}

/// ECMA-262 String.prototype.toLowerCase (locale-independent full Unicode lowercase).
/// Swift `lowercased()` already applies SpecialCasing (e.g. U+0130 → "i̇") but maps U+03A3 to σ unconditionally;
/// JS applies the Final_Sigma context (Unicode §3.13): Σ → ς when preceded by a cased letter (skipping
/// case-ignorable) and not followed by one. Verified against Node v20.19.2 in Fixtures/mediaParity.json `lower`.
public func jsToLowerCase(_ s: String) -> String {
    let scalars = Array(s.unicodeScalars)
    var out = String.UnicodeScalarView()
    for (idx, sc) in scalars.enumerated() {
        guard sc.value == 0x03A3 else { out.append(contentsOf: String(sc).lowercased().unicodeScalars); continue }
        var before = false
        var i = idx - 1
        while i >= 0 { let p = scalars[i].properties; if p.isCaseIgnorable { i -= 1; continue }; before = p.isCased; break }
        var after = false
        var j = idx + 1
        while j < scalars.count { let p = scalars[j].properties; if p.isCaseIgnorable { j += 1; continue }; after = p.isCased; break }
        out.append(before && !after ? "\u{03C2}" : "\u{03C3}")
    }
    return String(out)
}
