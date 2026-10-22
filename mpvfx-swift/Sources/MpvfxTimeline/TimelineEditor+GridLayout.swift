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
import MpvfxShared

public extension TimelineEditor {
    /// Ordered selection to cells; the menu/shortcut caller supplies selection order, then track order.
    @discardableResult
    func applyGridLayout(_ layout: NativeGridLayout, clipIds: [String], atFrame frame: Double,
                         options: NativeGridOptions = .init()) -> Bool {
        let before = document
        do {
            let next = try planNativeGridLayout(before, clipIds: clipIds, layout: layout, frame: frame, options: options, engine: engine)
            withHistory("Arrange layout") { replaceDocument(next, inverse: .restoreDocument(before)) }
            lastFailure = nil
            return true
        } catch {
            let message = (error as? NativeGridFailure)?.userMessage ?? "The clips could not be arranged."
            lastFailure = .init(code: .documentMismatch, message: message)
            return false
        }
    }
}
