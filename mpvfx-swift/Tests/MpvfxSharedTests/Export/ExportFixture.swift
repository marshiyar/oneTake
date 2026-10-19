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
import XCTest
@testable import MpvfxShared

// Loads Fixtures/exportParity.json, recorded reference values of the export policy and
// the engine version recorded in the fixture (recorded data; the generator is not part of this repo).
// Its "engine" section (encoder presets) is kept as recorded but no longer asserted.
// Read via #filePath because Package.swift declares no test resources. Order-preserving parse (NativeJSONValue.parse).
enum ExportFixture {
    static let root: NativeJSONValue = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/exportParity.json")
        return try! NativeJSONValue.parse(String(contentsOf: url, encoding: .utf8))
    }()
    static var cases: NativeJSONValue { root["cases"]! }
    static func list(_ v: NativeJSONValue?) -> [NativeJSONValue] { v?.arrayValue ?? [] }
}

/// A JS number from the fixture (non-finite numbers and -0 were written as strings by the generator's replacer).
func fxNum(_ v: NativeJSONValue?) -> Double {
    switch v {
    case .number(let n)?: return n
    case .string("NaN")?: return .nan
    case .string("Infinity")?: return .infinity
    case .string("-Infinity")?: return -.infinity
    case .string("-0")?: return -0.0
    default: fatalError("not a fixture number: \(String(describing: v))")
    }
}
/// Rebuild the JS value: numeric fields of a dimensions object get their special-number strings decoded.
func fxDimsValue(_ v: NativeJSONValue?) -> NativeJSONValue? {
    guard let v else { return nil }
    guard case .object(var o) = v else { return v }
    for k in ["width", "height"] { if let x = o[k] { o[k] = .number(fxNum(x)) } }
    return .object(o)
}
/// Keeps every key of the fixture object, in order (ExportDimensions(json:)).
func fxDims(_ v: NativeJSONValue?) -> ExportDimensions? {
    guard case .object(let o)? = fxDimsValue(v) else { return nil }
    return ExportDimensions(json: o)
}
func fxDimsJSON(_ d: ExportDimensions?) -> NativeJSONValue { d?.jsonValue ?? .null }
func bitsEqual(_ a: Double, _ b: Double) -> Bool { a.bitPattern == b.bitPattern || (a.isNaN && b.isNaN) }
func dimsJSON(_ w: Double, _ h: Double) -> NativeJSONValue { fxDimsJSON(.init(width: w, height: h)) }
