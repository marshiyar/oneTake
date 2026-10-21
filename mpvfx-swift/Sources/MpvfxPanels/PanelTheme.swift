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
import MpvfxTheme
import MpvfxTimeline

private typealias T = ThemeTokens

/// The panels' design tokens, defined once so every native panel draws from the same values.
///
/// Values: the `studio.*` and `panel.*` colors, the Tailwind default
/// neutral/red palettes the panels use (`bg-neutral-950`, `text-neutral-500`, `text-red-400`, ...),
/// the body font and range thumbs, and the Tailwind spacing/radius/type scale
/// (`px-3` = 12, `rounded-lg` = 8, `text-[11px]`, `font-semibold`). Class names are kept in the comments so a
/// view can be checked against its design spec.
public enum PanelTheme {
    // Colours read the shared tokens (MpvfxTheme) for the current `Theme.mode`, so a live appearance switch
    // repaints with the other palette. Dark values are the original palette; light values are derived (ThemeTokens).
    private static func c(_ p: ThemePair) -> CanvasColor { CanvasColor(p.now) }

    // MARK: studio.* (theme.js)
    public static var studioBg: CanvasColor { c(T.studioBgPair) }
    public static var studioSurface: CanvasColor { c(T.studioSurfacePair) }
    public static var studioBorder: CanvasColor { c(T.studioBorderPair) }
    public static var studioText: CanvasColor { c(T.studioTextPair) }
    public static var studioMuted: CanvasColor { c(T.studioMutedPair) }
    /// `studio-accent` / `panel-accent` (#2D7FFF). The inline-style mint (`P.accent`, `--hf-accent`) is `mint`.
    public static var accent: CanvasColor { c(T.studioAccentPair) }
    public static var mint: CanvasColor { c(T.mintPair) }
    /// A primary button (fill, hover fill) under `onAccent` text.
    public static var primaryFill: CanvasColor { c(T.primaryFillPair) }
    public static var primaryFillHover: CanvasColor { c(T.primaryFillHoverPair) }
    /// Property row labels in the inspector (number, slider, toggle and segmented rows, pair headings): text-2, the
    /// grey that still reaches 4.5:1 on the inspector's inset and on the compact fields' panel grey in both modes.
    public static var rowLabel: CanvasColor { text2 }

    // MARK: panel.* (theme.js)
    public static var panelBg: CanvasColor { c(T.panelBgPair) }
    public static var panelBgInset: CanvasColor { c(T.panelBgInsetPair) }
    public static var panelInput: CanvasColor { c(T.panelInputPair) }
    public static var panelSurface: CanvasColor { c(T.panelSurfacePair) }
    public static var panelHover: CanvasColor { c(T.panelHoverPair) }
    public static var panelBorder: CanvasColor { c(T.panelBorderPair) }
    public static var panelBorderInput: CanvasColor { c(T.panelBorderInputPair) }
    public static var panelHairline: CanvasColor { c(T.panelHairlinePair) }
    public static var text0: CanvasColor { c(T.textPairs[0]) }
    public static var text1: CanvasColor { c(T.textPairs[1]) }
    public static var text2: CanvasColor { c(T.textPairs[2]) }
    public static var text3: CanvasColor { c(T.textPairs[3]) }
    public static var text4: CanvasColor { c(T.textPairs[4]) }
    public static var text5: CanvasColor { c(T.textPairs[5]) }
    public static var danger: CanvasColor { c(T.dangerPair) }
    public static var media: CanvasColor { c(T.mediaPair) }
    public static var container: CanvasColor { c(T.containerPair) }

    // MARK: Tailwind neutral / red (default palette)
    public static var neutral50: CanvasColor { c(T.neutralPairs[50]!) }
    public static var neutral100: CanvasColor { c(T.neutralPairs[100]!) }
    public static var neutral200: CanvasColor { c(T.neutralPairs[200]!) }
    public static var neutral300: CanvasColor { c(T.neutralPairs[300]!) }
    public static var neutral400: CanvasColor { c(T.neutralPairs[400]!) }
    public static var neutral500: CanvasColor { c(T.neutralPairs[500]!) }
    public static var neutral600: CanvasColor { c(T.neutralPairs[600]!) }
    public static var neutral700: CanvasColor { c(T.neutralPairs[700]!) }
    public static var neutral800: CanvasColor { c(T.neutralPairs[800]!) }
    public static var neutral900: CanvasColor { c(T.neutralPairs[900]!) }
    public static var neutral950: CanvasColor { c(T.neutralPairs[950]!) }
    public static var red400: CanvasColor { c(T.red400Pair) }
    public static var red500: CanvasColor { c(T.red500Pair) }
    public static var red600: CanvasColor { c(T.red600Pair) }
    public static var red950: CanvasColor { c(T.red950Pair) }
    /// Opposite end of `white`: black in dark mode, white in light mode.
    public static var black: CanvasColor { c(T.blackPair) }
    /// Strongest foreground: white in dark mode, near-black ink in light mode (see `ThemeTokens.white`).
    public static var white: CanvasColor { c(T.whitePair) }
    /// Audio identity tint (timeline `.is-audio`, violet-400).
    public static var audioViolet: CanvasColor { c(T.violet400Pair) }

    // MARK: Fixed in both modes
    /// Text/glyph on an accent or danger fill.
    public static let onAccent = CanvasColor(T.onAccent)
    /// White ink and dark scrim for chrome drawn over the picture (the stage stays neutral).
    public static let stageInk = CanvasColor(T.stageInk)
    public static let stageScrim = CanvasColor(T.stageScrim)

    // MARK: Derived surfaces used by the shell
    /// A resize seam under the pointer (`white/18`); at rest the seam is the black shell, while dragging the accent.
    public static var seamHover: CanvasColor { white.withAlpha(0.18) }

    // MARK: Type
    /// The studio body font stack: `-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif`. macOS and Windows get
    /// the system UI font ("Sans"). On Linux Chromium resolves that stack to `sans-serif` → Arial → Liberation Sans
    /// (fontconfig's metric-compatible alias), so the panels ask Pango for the same face, falling back to Sans.
    #if os(Linux)
    public static let uiFamily = "Arial, Liberation Sans, Sans"
    /// Tailwind `font-mono` (ui-monospace … "Liberation Mono", "Courier New", monospace) as Chromium resolves it on Linux.
    public static let monoFamily = "Liberation Mono, Monospace"
    #else
    public static let uiFamily = "Sans"
    public static let monoFamily = "Monospace"
    #endif
    public static func font(_ size: Double, _ weight: CanvasFont.Weight = .regular) -> CanvasFont { CanvasFont(family: uiFamily, size: size, weight: weight) }
    public static func mono(_ size: Double, _ weight: CanvasFont.Weight = .regular) -> CanvasFont { CanvasFont(family: monoFamily, size: size, weight: weight) }
    /// `text-xs` (12px), `text-sm` (14px).
    public static let textXs = 12.0, textSm = 14.0

    // MARK: Radii (rounded-*) and spacing (Tailwind 4px unit)
    public static let radius = 4.0, radiusMd = 6.0, radiusLg = 8.0, radiusXl = 12.0
    public static func sp(_ n: Double) -> Double { n * 4 }

    // MARK: Shell metrics (fitPanels, left sidebar, right panel)
    /// The seam between two panels: 1px where the black shell (`studioBg`) shows through. Its pointer zone is 13px
    /// wide, centred on it.
    public static let seamWidth = 1.0, seamHitWidth = 13.0
    /// Collapsed rail width (`w-10`); a seam follows a rail as it follows a panel.
    public static let railBox = 40.0
    /// The smallest pointer target, in points (WCAG 2.2 SC 2.5.8; docs/DESIGN.md "Accessibility floors"). A hit rect
    /// grows to it around its glyph (`CanvasRect.target`); the glyph keeps its drawn size.
    public static let minTarget = 24.0
}

/// Value coloring of a property row (value tier).
public enum PropertyValueTier: Equatable, Sendable {
    case `default`, explicitDefault, explicitCustom

    public static func resolve(explicit: String?, default def: String) -> PropertyValueTier {
        guard let e = explicit?.trimmingCharacters(in: .whitespaces), !e.isEmpty else { return .default }
        return e == def.trimmingCharacters(in: .whitespaces) ? .explicitDefault : .explicitCustom
    }
    /// Labels stay grey in every tier (docs/DESIGN.md Rollout 5): the value, not the label, says what changed.
    public var labelColor: CanvasColor { PanelTheme.rowLabel }
    /// The value in the accent once the user changed it (Principle 2), else the field's own ink.
    public var valueColor: CanvasColor { self == .explicitCustom ? PanelTheme.accent : PanelTheme.neutral100 }
    /// A value's ink as drawn: `neutral600` when disabled, the field's ink while typed, the accent while scrubbed or
    /// dragged, else `valueColor`.
    func valueInk(disabled: Bool, typing: Bool = false, adjusting: Bool) -> CanvasColor {
        if disabled { return PanelTheme.neutral600 }
        if typing { return PanelTheme.neutral100 }
        return adjusting ? PanelTheme.accent : valueColor
    }
}


extension CanvasColor {
    /// This colour drawn at `opacity` over the opaque `bg`, as one opaque colour (an element's `opacity`
    /// composites the whole glyph once, so overlapping strokes must not darken twice).
    func over(_ bg: CanvasColor, opacity o: Double) -> CanvasColor {
        CanvasColor(r: bg.r + (r - bg.r) * o, g: bg.g + (g - bg.g) * o, b: bg.b + (b - bg.b) * o)
    }
}

extension CanvasRect {
    var midY: Double { y + height / 2 }
    var midX: Double { x + width / 2 }
    /// This rect grown about its centre to at least `PanelTheme.minTarget` in each dimension: the hit rect of a
    /// glyph drawn smaller than a pointer target. A dimension already that large is kept.
    var target: CanvasRect {
        let w = max(width, PanelTheme.minTarget), h = max(height, PanelTheme.minTarget)
        return CanvasRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h)
    }
    /// `target`, slid (never shrunk) to stay inside `bounds` where it fits, so it does not cover the control beside
    /// it: a reset glyph in a column's corner keeps its 24 points inside the column.
    func target(in bounds: CanvasRect) -> CanvasRect {
        let t = target
        func slide(_ v: Double, _ len: Double, _ lo: Double, _ hi: Double) -> Double { hi - lo < len ? v : min(max(v, lo), hi - len) }
        return CanvasRect(x: slide(t.x, t.width, bounds.x, bounds.maxX), y: slide(t.y, t.height, bounds.y, bounds.maxY),
                          width: t.width, height: t.height)
    }
    /// The rect with its edges on whole layout pixels (rounded half up), as Chromium snaps backgrounds and borders
    /// laid out at fractional positions (a 44.5px header paints 45).
    var snapped: CanvasRect {
        let x0 = (x + 1e-6).rounded(.down) + ((x - x.rounded(.down)) >= 0.5 - 1e-6 ? 1 : 0)
        let y0 = (y + 1e-6).rounded(.down) + ((y - y.rounded(.down)) >= 0.5 - 1e-6 ? 1 : 0)
        let x1 = ((x + width) + 0.5 + 1e-6).rounded(.down), y1 = ((y + height) + 0.5 + 1e-6).rounded(.down)
        return CanvasRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
