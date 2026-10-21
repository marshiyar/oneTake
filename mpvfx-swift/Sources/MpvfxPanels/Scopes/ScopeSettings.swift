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
import MpvfxScopes

/// The scopes the Grade group can show.
public enum ScopeKind: String, CaseIterable, Sendable {
    case waveform, overlay, parade, vectorscope, histogram, falseColor

    public var label: String {
        switch self {
        case .waveform: "Waveform"
        case .overlay: "RGB"
        case .parade: "Parade"
        case .vectorscope: "Vector"
        case .histogram: "Histogram"
        case .falseColor: "False color"
        }
    }

    /// The tile caption (top left inside the scope).
    public var title: String {
        switch self {
        case .waveform: "Luma waveform"
        case .overlay: "RGB overlay"
        case .parade: "RGB parade"
        case .vectorscope: "Vectorscope"
        case .histogram: "Histogram"
        case .falseColor: "False color"
        }
    }
}

/// How the scopes are shown: which ones, in what order, and their scale, targets, zoom and trace gain.
public struct ScopeSettings: Equatable, Sendable {
    public static let maxShown = 4
    public static let gains: [Double] = [0.25, 0.5, 1, 2, 4]
    public static let zooms: [Double] = [1, 2, 4]

    /// Shown in this order, 1...`maxShown`; waveform beside the vectorscope by default, as colourists read them.
    public private(set) var kinds: [ScopeKind] = [.waveform, .vectorscope]
    public var scale = ScopeScale.percent
    /// 0.75 (100/0/75/0 bars) or 1 (100/0/100/0).
    public var targetAmplitude = 0.75
    public private(set) var zoom = 1.0
    public private(set) var gain = 1.0
    public var matrix = ScopeMatrix.rec709

    public init() {}

    /// Shows `kind` (dropping the oldest when `maxShown` are shown) or hides it (never the last one).
    public mutating func toggle(_ kind: ScopeKind) {
        if let i = kinds.firstIndex(of: kind) {
            if kinds.count > 1 { kinds.remove(at: i) }
        } else {
            if kinds.count >= Self.maxShown { kinds.removeFirst() }
            kinds.append(kind)
        }
    }

    /// One step brighter (+1) or dimmer (-1) along `gains`.
    public mutating func stepGain(_ delta: Int) {
        let i = Self.gains.firstIndex(of: gain) ?? 2
        gain = Self.gains[min(Self.gains.count - 1, max(0, i + delta))]
    }

    /// The next vectorscope zoom (1x, 2x, 4x, then 1x).
    public mutating func cycleZoom() {
        let i = Self.zooms.firstIndex(of: zoom) ?? 0
        zoom = Self.zooms[(i + 1) % Self.zooms.count]
    }

    /// What the engine needs from these settings.
    var options: ScopeOptions { ScopeOptions(matrix: matrix, vectorZoom: zoom) }
}
