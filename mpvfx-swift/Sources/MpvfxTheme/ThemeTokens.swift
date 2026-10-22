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

/// The colour tokens with no dependencies, so any module (timeline, panels, player) can share
/// them without a dependency cycle. The dark values are the palette in docs/DESIGN.md (one flat grey, one blue
/// accent, clips coloured by media kind); the panels also use the Tailwind neutral/red ramps. Map to a drawing
/// colour at the use site.
///
/// Every token has a dark value and a light value (
/// derived from the dark one: surfaces and the neutral ramp are mirrored, accents are darkened until text in
/// them reaches WCAG AA on the light panel surfaces). A token reads the value for `Theme.mode`, so code that
/// asks for a token at draw time follows a live appearance switch without a restart.
public struct ThemeColor: Equatable, Sendable {
    public var r, g, b, a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    /// 0xRRGGBB.
    public init(_ rgb: UInt32, alpha: Double = 1) {
        self.init(r: Double((rgb >> 16) & 0xFF) / 255, g: Double((rgb >> 8) & 0xFF) / 255, b: Double(rgb & 0xFF) / 255, a: alpha)
    }
    public func alpha(_ a: Double) -> ThemeColor { ThemeColor(r: r, g: g, b: b, a: a) }

    /// WCAG 2.x relative luminance of the opaque colour.
    public var relativeLuminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
    /// WCAG contrast ratio between two opaque colours (1...21).
    public func contrast(_ o: ThemeColor) -> Double {
        let a = relativeLuminance, b = o.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

/// The resolved colour scheme the UI draws in.
public enum ThemeMode: String, Sendable, CaseIterable { case dark, light }

/// The user's appearance setting. `system` follows the OS (macOS effective appearance, GTK prefer-dark on Linux).
/// Until the user picks, the editor is dark (docs/DESIGN.md): footage is judged on a dark surround.
public enum ThemeAppearance: String, Sendable, CaseIterable {
    case system, light, dark
    /// Preferences key (`<userData>/preferences.json`).
    public static let preferenceKey = "mpvfx-appearance"
    /// The setting before the user picks one.
    public static let `default`: ThemeAppearance = .dark
    /// The stored value; anything missing or unknown is the default.
    public init(preference: String?) { self = preference.flatMap(ThemeAppearance.init(rawValue:)) ?? .default }
    public var label: String {
        switch self { case .system: "System"; case .light: "Light"; case .dark: "Dark" }
    }
    public func resolve(systemPrefersDark: Bool) -> ThemeMode {
        switch self {
        case .system: systemPrefersDark ? .dark : .light
        case .light: .light
        case .dark: .dark
        }
    }
}

/// The current mode and its change observers. Mutations and callbacks stay on the main thread;
/// drawing code may read the mode from any thread.
public enum Theme {
    private static let state = State()
    public static var mode: ThemeMode { state.mode }

    /// On the main thread, switches the mode and synchronously tells observers only when it changes.
    public static func setMode(_ m: ThemeMode) { state.setMode(m) }
    /// On the main thread, registers `fn` for subsequent changes. Returns an id for `removeObserver`.
    @discardableResult
    public static func addObserver(_ fn: @escaping (ThemeMode) -> Void) -> Int {
        state.addObserver(fn)
    }
    /// Removes an observer on the main thread.
    public static func removeObserver(_ id: Int) { state.removeObserver(id) }

    // SAFETY: storedMode is accessed only under modeLock. Observers (including their non-Sendable
    // captures) and nextObserver run on the main thread: off-main callers are bounced there synchronously
    // below, so delivery order and observer identity stay exact. Native GTK, AppKit and Win32 callbacks
    // use this synchronous API without requiring actor-isolated callers.
    private final class State: @unchecked Sendable {
        private let modeLock = NSLock()
        private var storedMode: ThemeMode = .dark
        private var observers: [(id: Int, fn: (ThemeMode) -> Void)] = []
        private var nextObserver = 0

        var mode: ThemeMode {
            modeLock.lock()
            defer { modeLock.unlock() }
            return storedMode
        }

        func setMode(_ m: ThemeMode) {
            if !Thread.isMainThread { return DispatchQueue.main.sync { setMode(m) } }
            guard m != mode else { return }
            modeLock.lock()
            storedMode = m
            modeLock.unlock()
            // Snapshot before delivery: callbacks may read tokens, change subscriptions or switch
            // mode again. No lock is held while calling user code; the current delivery keeps its order.
            let delivery = observers
            for o in delivery { o.fn(m) }
        }

        func addObserver(_ fn: @escaping (ThemeMode) -> Void) -> Int {
            if !Thread.isMainThread { return DispatchQueue.main.sync { addObserver(fn) } }
            nextObserver += 1
            observers.append((nextObserver, fn))
            return nextObserver
        }

        func removeObserver(_ id: Int) {
            if !Thread.isMainThread { return DispatchQueue.main.sync { removeObserver(id) } }
            observers.removeAll { $0.id == id }
        }
    }
}

/// A token's two values.
public struct ThemePair: Sendable {
    public let dark: ThemeColor, light: ThemeColor
    public init(_ dark: ThemeColor, _ light: ThemeColor) { self.dark = dark; self.light = light }
    public init(_ dark: UInt32, _ light: UInt32, alpha: Double = 1) { self.init(ThemeColor(dark, alpha: alpha), ThemeColor(light, alpha: alpha)) }
    public func value(_ m: ThemeMode) -> ThemeColor { m == .light ? light : dark }
    public var now: ThemeColor { value(Theme.mode) }
}

public enum ThemeTokens {
    // studio.* / panel.* (theme.js)
    /// The accent (docs/DESIGN.md): active tool, selection, focus, changed values.
    public static let studioAccentPair = ThemePair(0x4C8DF0, 0x1A5FCC)
    public static var studioAccent: ThemeColor { studioAccentPair.now }
    /// A primary button's fill under `onAccent` text (the Media panel's Import): the accent a step darker in dark
    /// mode so white 12 pt text keeps 4.5:1 (the accent itself gives 3.3:1); the hover is darker again.
    public static let primaryFillPair = ThemePair(0x2F6FD6, 0x1A5FCC)
    public static let primaryFillHoverPair = ThemePair(0x2763C4, 0x164FAD)
    /// The accent's line form (playhead, drop slots, timeline highlights): the accent blue a step lighter so a 1 px
    /// line stays visible. Named `mint` for the colour it used to be.
    public static let mintPair = ThemePair(0x5A98F0, 0x1A5FCC)
    public static var mint: ThemeColor { mintPair.now }
    /// shellBackground: ruler, toolbar strip and timeline surface.
    public static let timelineSurfacePair = ThemePair(0x1D1D1D, 0xF4F4F5)
    public static var timelineSurface: ThemeColor { timelineSurfacePair.now }

    // Tailwind neutral (light mirrors the ramp: 100 <-> 900; 400 and 500 a step darker so text keeps its dark contrast)
    public static let neutralPairs: [Int: ThemePair] = [
        50: ThemePair(0xFAFAFA, 0x0A0A0A), 100: ThemePair(0xF5F5F5, 0x171717), 200: ThemePair(0xE5E5E5, 0x262626),
        300: ThemePair(0xD4D4D4, 0x404040), 400: ThemePair(0xA3A3A3, 0x4D4D4D), 500: ThemePair(0x737373, 0x666666),
        600: ThemePair(0x525252, 0xA3A3A3), 700: ThemePair(0x404040, 0xD4D4D4), 800: ThemePair(0x262626, 0xE5E5E5),
        900: ThemePair(0x171717, 0xF5F5F5), 950: ThemePair(0x0A0A0A, 0xFAFAFA),
    ]
    public static func neutral(_ n: Int) -> ThemeColor { neutralPairs[n]!.now }
    public static var neutral50: ThemeColor { neutral(50) }
    public static var neutral100: ThemeColor { neutral(100) }
    public static var neutral200: ThemeColor { neutral(200) }
    public static var neutral300: ThemeColor { neutral(300) }
    public static var neutral400: ThemeColor { neutral(400) }
    public static var neutral500: ThemeColor { neutral(500) }
    public static var neutral600: ThemeColor { neutral(600) }
    public static var neutral700: ThemeColor { neutral(700) }
    public static var neutral800: ThemeColor { neutral(800) }
    public static var neutral900: ThemeColor { neutral(900) }
    public static var neutral950: ThemeColor { neutral(950) }

    // Tailwind red / green / blue / violet (light: the darker shade that reads as the same role on white)
    public static let red300Pair = ThemePair(0xFCA5A5, 0xB91C1C), red400Pair = ThemePair(0xF87171, 0xC81E1E)
    public static let red500Pair = ThemePair(0xEF4444, 0xC81E1E), red600Pair = ThemePair(0xDC2626, 0xB91C1C)
    public static let red950Pair = ThemePair(0x450A0A, 0xFEE2E2)
    public static let green500Pair = ThemePair(0x22C55E, 0x15803D)
    public static let blue400Pair = ThemePair(0x60A5FA, 0x2563EB), blue500Pair = ThemePair(0x3B82F6, 0x1D4ED8)
    public static let violet400Pair = ThemePair(0xA78BFA, 0x6D4ED6), purple500Pair = ThemePair(0xA855F7, 0x7E22CE)
    public static var red300: ThemeColor { red300Pair.now }
    public static var red400: ThemeColor { red400Pair.now }
    public static var red500: ThemeColor { red500Pair.now }
    public static var red600: ThemeColor { red600Pair.now }
    public static var red950: ThemeColor { red950Pair.now }
    public static var green500: ThemeColor { green500Pair.now }
    public static var blue400: ThemeColor { blue400Pair.now }
    public static var blue500: ThemeColor { blue500Pair.now }
    public static var violet400: ThemeColor { violet400Pair.now }
    public static var purple500: ThemeColor { purple500Pair.now }

    /// The strongest foreground ("white" in the dark studio: hover text, seams as white/12, slider thumbs).
    /// Light mode inks with near-black, so `white.alpha(0.06)` hover washes stay a faint tint of the text colour.
    public static let whitePair = ThemePair(0xFFFFFF, 0x09090B)
    public static var white: ThemeColor { whitePair.now }
    /// The opposite end ("black" in the dark studio).
    public static let blackPair = ThemePair(0x000000, 0xFFFFFF)
    public static var black: ThemeColor { blackPair.now }

    // MARK: panel.* (studio theme)
    /// Light shell: as dark as the light-palette rule allows (luminance above 0.7), so the seams between white panels show.
    public static let studioBgPair = ThemePair(0x000000, 0xDADADE)
    public static let studioSurfacePair = ThemePair(0x4A4A4A, 0xC9C9CE)
    public static let studioBorderPair = ThemePair(0x262626, 0xD4D4D8)
    public static let studioTextPair = ThemePair(0xE5E5E5, 0x27272A)
    public static let studioMutedPair = ThemePair(0x737373, 0x666666)
    public static let panelBgPair = ThemePair(0x1D1D1D, 0xFAFAFA)
    public static let panelBgInsetPair = ThemePair(0x191919, 0xF4F4F5)
    public static let panelInputPair = ThemePair(0x0E0E0E, 0xFFFFFF)
    public static let panelSurfacePair = ThemePair(0x232323, 0xE5E5E9)
    public static let panelHoverPair = ThemePair(0x2C2C2C, 0xD5D5DB)
    public static let panelBorderPair = ThemePair(0x000000, 0xC8C8CE)
    public static let panelBorderInputPair = ThemePair(0x333333, 0xB4B4BC)
    public static let panelHairlinePair = ThemePair(0x141414, 0xDCDCE0)
    /// The checkerboard behind a transparent colour (colour swatches, the picker's alpha bar): 4 pt cells of the two.
    public static let checkerLightPair = ThemePair(0x3A3A3A, 0xFFFFFF)
    public static let checkerDarkPair = ThemePair(0x262626, 0xD4D4D8)
    /// Panel text ramp (text0 strongest). Light values keep each step at or above its dark contrast.
    public static let textPairs: [ThemePair] = [
        ThemePair(0xFAFAFA, 0x09090B), ThemePair(0xE4E4E7, 0x27272A), ThemePair(0xA1A1AA, 0x4A4A52),
        ThemePair(0x71717A, 0x63636B), ThemePair(0x52525B, 0x8E8E96), ThemePair(0x3F3F46, 0xB4B4BB),
    ]
    public static let dangerPair = ThemePair(0xEF4444, 0xC81E1E)
    public static let mediaPair = ThemePair(0x00E3FF, 0x0A6F8A)
    public static let containerPair = ThemePair(0xF5A623, 0x955600)
    /// Popover/menu card (white/8 border).
    public static let popoverPair = ThemePair(0x252525, 0xFFFFFF)
    /// Timeline lanes (rowBackground) and track headers (gutterBackground).
    public static let timelineRowPair = ThemePair(0x1D1D1D, 0xFFFFFF)
    public static let timelineGutterPair = ThemePair(0x212121, 0xEFEFF2)
    /// Track header controls (docs/DESIGN.md step 4) on `timelineGutterPair`: an idle lock, eye, speaker or solo glyph
    /// (3:1, a control), and the track tag's text when the track is not targeted (4.5:1). A control that is on, and a
    /// targeted tag's fill, use `mintPair`; a targeted tag's text uses `onAccentMintPair`.
    public static let trackControlIdlePair = ThemePair(0x8C8C8C, 0x6E6E73)
    public static let trackTagTextPair = ThemePair(0xB4B4B4, 0x46464C)
    /// The 1 px outline of an untargeted track tag, and the wash under a header control in the pointer.
    public static let trackTagOutlinePair = ThemePair(0x4A4A4A, 0xC4C4CA)
    public static let trackControlHoverPair = ThemePair(0x2E2E2E, 0xDCDCE1)
    /// Timeline clip fill by media kind (docs/DESIGN.md), at rest and under the pointer. Light fills are mid tones that
    /// stand out from the white lanes and still carry dark ink at 4.5:1.
    public static let clipVideoPair = ThemePair(0x1D4A64, 0x8FBDE2), clipVideoHoverPair = ThemePair(0x245A79, 0x7BB0DA)
    public static let clipAudioPair = ThemePair(0x2F4A17, 0xA8D187), clipAudioHoverPair = ThemePair(0x3A5A1D, 0x93C46C)
    /// Opacity of the `white` ink for a clip's name and timecode on its fill (the name reaches 4.5:1, the timecode 3:1).
    public static let clipNameAlpha = 0.92, clipTimecodeAlpha = 0.72
    /// Height of the kind-coloured strip that keeps the name readable over thumbnails.
    public static let clipHeaderHeight = 18.0
    /// Timeline sequence end (docs/TIMELINE.md "Ruler and sequence end"): the end marker line and flag (3:1 on the
    /// lanes and the ruler, a control-weight line), and the shade over the ruler and lanes after the end.
    public static let timelineEndMarkerPair = ThemePair(0x8C8C8C, 0x6E6E73)
    public static let timelineOutOfRangePair = ThemePair(ThemeColor(0x000000, alpha: 0.28), ThemeColor(0x000000, alpha: 0.06))
    /// Timeline clip while dragged (opaque so the lanes under it do not show through), audio and visual.
    public static let clipDragAudioPair = ThemePair(ThemeColor(0x3C3454, alpha: 0.96), ThemeColor(0xE4DDFB, alpha: 0.96))
    public static let clipDragPair = ThemePair(ThemeColor(0x262A34, alpha: 0.96), ThemeColor(0xDDE1EA, alpha: 0.96))
    /// Audio waveform bars.
    public static let waveformPair = ThemePair(0x79C0F9, 0x1E5F8E)
    /// Native range control (Grade level slider): the darker edge of the accent fill.
    public static let accentEdgePair = ThemePair(0x2F6BDF, 0x1A52AB)
    /// Curve editor point outline.
    public static let curvePointOutlinePair = ThemePair(0x111111, 0xFFFFFF)
    /// Curve editor line and point colour per curve tab (CurveGraph's tab colours). Dark: the original values
    /// (Master gray-200, R rose-400, G green-400, B blue-400, Hue/Hue fuchsia-300, Hue/Sat yellow-400, Hue/Luma
    /// slate-50); light: text1 ink for Master and Hue/Luma, a darker shade of the same hue for the rest, each at
    /// least 3:1 on the light curve graph.
    public static let curveMasterPair = ThemePair(0xE5E7EB, 0x27272A)
    public static let curveRedPair = ThemePair(0xFB7185, 0xE11D48)
    public static let curveGreenPair = ThemePair(0x4ADE80, 0x15803D)
    public static let curveBluePair = ThemePair(0x60A5FA, 0x2563EB)
    public static let curveHueHuePair = ThemePair(0xF0ABFC, 0xC026D3)
    public static let curveHueSatPair = ThemePair(0xFACC15, 0xA16207)
    public static let curveHueLumaPair = ThemePair(0xF8FAFC, 0x27272A)
    /// Preview viewport around the stage.
    public static let viewportPair = ThemePair(0x141414, 0xE7E7EA)
    /// Keyframe marks by property kind (timeline lanes and inspector). Each kind also has its own shape, which carries
    /// the meaning; the colour reinforces it. Hues follow the Okabe-Ito colour-vision-safe set (yellow, reddish purple,
    /// orange, bluish green, blue) with a neutral for opacity, lightened for the dark lanes and darkened for the
    /// light ones. Each is at least 3:1 on the lane, row and gutter backgrounds in its mode, and every pair stays apart
    /// under simulated protan, deutan and tritan vision (`KeyframeKindTokenTests`).
    public static let keyframeTransformPair = ThemePair(0xF0E042, 0x6E5C00)
    public static let keyframe3DPair = ThemePair(0xE0A4C8, 0xA42F80)
    public static let keyframeOpacityPair = ThemePair(0xD4D4D8, 0x52525B)
    public static let keyframeColorPair = ThemePair(0xE6A100, 0xCC5C00)
    public static let keyframeEffectPair = ThemePair(0x2BC29A, 0x008056)
    public static let keyframeAudioPair = ThemePair(0x56B4E9, 0x0072B2)

    // MARK: Fixed (the same in both modes)
    /// Media/stage canvas surface: the stage stays neutral so pictures are judged on the same grey.
    public static let stageCanvas = ThemeColor(0x202329)
    /// Document background when a project names none.
    public static let stageDefaultBackground = ThemeColor(0x111111)
    /// Chrome drawn over the picture (preview toolbar pills, stage hints): dark scrim, white ink, both modes.
    public static let stageScrim = ThemeColor(0x000000)
    public static let stageInk = ThemeColor(0xFFFFFF)
    /// Label/glyph on an accent or danger fill (always white).
    public static let onAccent = ThemeColor(0xFFFFFF)
    /// Glyph on the mint accent: black on the bright dark-mode mint, white on the light mode's darker mint.
    public static let onAccentMintPair = ThemePair(0x000000, 0xFFFFFF)
    /// Dark ink on a mint fill (timeline band labels).
    public static let onMint = ThemeColor(0x09110E)
    /// Native range control's unfilled track and its edge (the platform control is light in both modes).
    public static let nativeRangeTrack = ThemeColor(0xEFEFEF), nativeRangeEdge = ThemeColor(0xB2B2B2)
    /// Smart guides and spacing marks (magenta, both modes).
    public static let guide = ThemeColor(0xFF44CC)
    /// Video scopes draw on black in both modes: the luma trace, the R/G/B traces, the vectorscope trace, the
    /// graticule ink, the skin-tone line and the clipping marks.
    public static let scopeLuma = ThemeColor(0xE2E8F0), scopeRed = ThemeColor(0xF87171)
    public static let scopeGreen = ThemeColor(0x4ADE80), scopeBlue = ThemeColor(0x60A5FA)
    public static let scopeVector = ThemeColor(0x6EE7B7), scopeInk = ThemeColor(0xFFFFFF)
    public static let scopeSkin = ThemeColor(0xFBBF24), scopeClip = ThemeColor(0xFF3B30)
    /// Timeline band edge colours (identity, both modes).
    public static let bandEdges: [ThemeColor] = [0x3CE6AC, 0x5BA6FF, 0xBE77FF, 0xFFB04D, 0xFF6799].map { ThemeColor($0) }
    /// Timeline pre-roll stripe (preRollBackground).
    public static let preRoll = ThemeColor(0xFF5353)
}
