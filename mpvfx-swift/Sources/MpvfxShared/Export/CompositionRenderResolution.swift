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
// The Renders tab's resolution: the composition's own size ("auto"), or that size scaled with its aspect ratio
// kept, by its short edge (720p … 8K) or by a custom width. A render never squeezes the composition into another
// frame; changing the frame's shape is the composition size's job (NativeCompositionSize.swift).
import Foundation

public enum CompositionRenderResolution: Equatable, Sendable {
    /// The composition size as it is.
    case auto
    /// The composition scaled so its shorter side is this many pixels.
    case shortEdge(Double)
    /// The composition scaled to a custom width; the height follows the aspect.
    case custom

    public static let shortEdges: [Double] = [720, 1080, 1440, 2160, 4320]

    /// Reads the stored setting: "auto", "<n>p", "custom", and the choices saved before resolutions followed the
    /// composition (a fixed preset or the 1080p / 4K scale), which mean their short edge now. Anything else is auto.
    public init(stored: String) {
        if stored == "custom" { self = .custom; return }
        if stored.hasSuffix("p"), let n = Double(stored.dropLast()), Self.shortEdges.contains(n) { self = .shortEdge(n); return }
        switch ExportResolutionChoice(rawValue: stored) {
        case .scale(.k4)?: self = .shortEdge(2160)
        case .preset(let p)?: self = .shortEdge(min(p.info.width, p.info.height))
        default: self = .auto
        }
    }

    public var storedValue: String {
        switch self {
        case .auto: "auto"
        case .shortEdge(let n): "\(Int(n))p"
        case .custom: "custom"
        }
    }

    /// The output size for a composition, nil when it falls outside the 8K export envelope or is not a size.
    public func dimensions(compositionWidth w: Double, compositionHeight h: Double, customWidth: Double) -> ExportDimensions? {
        guard w > 0, h > 0, w.isFinite, h.isFinite else { return nil }
        let d: ExportDimensions
        switch self {
        case .auto: return ExportDimensions(width: w, height: h)
        case .shortEdge(let n):
            let s = n / min(w, h)
            d = ExportDimensions(width: Self.even(w * s), height: Self.even(h * s))
        case .custom:
            guard customWidth > 0, customWidth.isFinite else { return nil }
            d = ExportDimensions(width: Self.even(customWidth), height: Self.customHeight(forWidth: customWidth, compositionWidth: w, compositionHeight: h))
        }
        return isValidExportOutputDimensions(d) ? d : nil
    }

    /// The even height that keeps the composition aspect at `width`.
    public static func customHeight(forWidth width: Double, compositionWidth w: Double, compositionHeight h: Double) -> Double {
        w > 0 ? even(width * h / w) : 0
    }
    /// The even width that keeps the composition aspect at `height`.
    public static func customWidth(forHeight height: Double, compositionWidth w: Double, compositionHeight h: Double) -> Double {
        h > 0 ? even(height * w / h) : 0
    }

    /// Auto, every short edge whose scaled size fits the 8K envelope, then custom.
    public static func choices(compositionWidth w: Double, compositionHeight h: Double) -> [CompositionRenderResolution] {
        [.auto] + shortEdges.map { .shortEdge($0) }.filter { $0.dimensions(compositionWidth: w, compositionHeight: h, customWidth: 0) != nil } + [.custom]
    }

    /// Nearest even pixel count, at least 2 (H.264 4:2:0 needs even sides).
    static func even(_ v: Double) -> Double { max(2, (v / 2).rounded() * 2) }
}
