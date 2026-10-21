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
import MpvfxCanvas

/// Where the shown scopes sit: one scope fills the width; two or more go two to a row (a row with one tile left
/// spans the width), so the default pair fits beside each other in the inspector. Every tile keeps a shape that
/// suits its scope.
public enum ScopeLayout {
    public static let gap = 6.0

    /// Tiles for `kinds` in a box `width` wide with its top left at (x, y).
    public static func tiles(_ kinds: [ScopeKind], x: Double, y: Double, width: Double) -> [(kind: ScopeKind, rect: CanvasRect)] {
        var out: [(kind: ScopeKind, rect: CanvasRect)] = []
        var top = y
        for row in rows(kinds) {
            let w = (width - gap * Double(row.count - 1)) / Double(row.count)
            let h = row.map { preferredHeight($0, width: w) }.max() ?? 0
            for (i, kind) in row.enumerated() {
                out.append((kind, CanvasRect(x: x + Double(i) * (w + gap), y: top, width: w, height: h)))
            }
            top += h + gap
        }
        return out
    }

    /// How tall the scopes area is: the bottom of its last tile.
    public static func height(_ kinds: [ScopeKind], width: Double) -> Double {
        guard let last = tiles(kinds, x: 0, y: 0, width: width).last else { return 0 }
        return last.rect.maxY
    }

    /// Two per row once more than one is shown.
    static func rows(_ kinds: [ScopeKind]) -> [[ScopeKind]] {
        let perRow = kinds.count >= 2 ? 2 : 1
        return stride(from: 0, to: kinds.count, by: perRow).map { Array(kinds[$0..<min(kinds.count, $0 + perRow)]) }
    }

    /// Waveform-like scopes and false colour: 16:9; the vectorscope: 4:3, so its square plot stays large.
    static func preferredHeight(_ kind: ScopeKind, width: Double) -> Double {
        (kind == .vectorscope ? width * 3 / 4 : width * 9 / 16).rounded()
    }
}
