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
@testable import MpvfxTheme

final class ThemeTokensTests: XCTestCase {
    override func tearDown() { Theme.setMode(.dark) }

    func testAppearanceSettingResolves() {
        XCTAssertEqual(ThemeAppearance(preference: nil), .dark)              // default: the dark editor
        XCTAssertEqual(ThemeAppearance(preference: "bogus"), .dark)
        XCTAssertEqual(ThemeAppearance(preference: "light"), .light)
        XCTAssertEqual(ThemeAppearance.allCases.map(\.label), ["System", "Light", "Dark"])
        XCTAssertEqual(ThemeAppearance.system.resolve(systemPrefersDark: true), .dark)
        XCTAssertEqual(ThemeAppearance.system.resolve(systemPrefersDark: false), .light)
        XCTAssertEqual(ThemeAppearance.light.resolve(systemPrefersDark: true), .light)
        XCTAssertEqual(ThemeAppearance.dark.resolve(systemPrefersDark: false), .dark)
    }

    func testModeSwitchNotifiesAndTokensFollow() {
        XCTAssertEqual(Theme.mode, .dark)
        XCTAssertEqual(ThemeTokens.timelineSurface, ThemeColor(0x1D1D1D))   // dark = docs/DESIGN.md
        XCTAssertEqual(ThemeTokens.mint, ThemeColor(0x5A98F0))
        var seen: [ThemeMode] = []
        let id = Theme.addObserver { seen.append($0) }
        defer { Theme.removeObserver(id) }
        Theme.setMode(.light)
        Theme.setMode(.light)                                                  // no change, no call
        XCTAssertEqual(seen, [.light])
        XCTAssertEqual(ThemeTokens.timelineSurface, ThemeTokens.timelineSurfacePair.light)
        XCTAssertNotEqual(ThemeTokens.neutral950, ThemeColor(0x0A0A0A))
        XCTAssertEqual(ThemeTokens.stageCanvas, ThemeColor(0x202329))         // the stage stays neutral
        Theme.setMode(.dark)
        XCTAssertEqual(seen, [.light, .dark])
        XCTAssertEqual(ThemeTokens.neutral950, ThemeColor(0x0A0A0A))
    }

    /// Light text reaches WCAG AA (4.5:1) on every light panel surface, and never falls below its dark contrast.
    func testLightTextContrastIsAA() {
        let lightSurfaces = [T.panelBgPair, T.panelBgInsetPair, T.panelInputPair, T.panelSurfacePair, T.popoverPair,
                             T.timelineRowPair, T.timelineSurfacePair, T.neutralPairs[950]!, T.neutralPairs[900]!].map(\.light)
        let darkSurfaces = [T.panelBgPair, T.panelBgInsetPair, T.panelInputPair, T.panelSurfacePair, T.popoverPair,
                            T.timelineRowPair, T.timelineSurfacePair, T.neutralPairs[950]!, T.neutralPairs[900]!].map(\.dark)
        let text: [(String, ThemePair)] = [("text0", T.textPairs[0]), ("text1", T.textPairs[1]), ("text2", T.textPairs[2]),
                                           ("text3", T.textPairs[3]), ("neutral200", T.neutralPairs[200]!), ("neutral300", T.neutralPairs[300]!),
                                           ("neutral400", T.neutralPairs[400]!), ("neutral500", T.neutralPairs[500]!),
                                           ("studioText", T.studioTextPair), ("studioMuted", T.studioMutedPair),
                                           ("accent", T.studioAccentPair), ("mint", T.mintPair), ("red400", T.red400Pair),
                                           ("danger", T.dangerPair), ("violet400", T.violet400Pair)]
        for (name, p) in text {
            let light = lightSurfaces.map { p.light.contrast($0) }.min()!
            let dark = darkSurfaces.map { p.dark.contrast($0) }.min()!
            XCTAssertGreaterThanOrEqual(light, 4.5, "\(name) light contrast \(light)")
            // The neutral text ramp keeps its dark contrast (capped at AAA); accents only need AA.
            if !["accent", "mint", "red400", "danger", "violet400"].contains(name) {
                XCTAssertGreaterThanOrEqual(light + 0.05, min(dark, 7), "\(name) light \(light) < dark \(dark)")
            }
        }
        XCTAssertEqual(ThemeColor(0xFFFFFF).contrast(ThemeColor(0x000000)), 21, accuracy: 0.01)
    }

    /// The light palette mirrors the dark one: surfaces are light, ink is dark, accents keep their hue family.
    func testLightPaletteIsDerived() {
        for p in [T.panelBgPair, T.panelBgInsetPair, T.panelInputPair, T.panelSurfacePair, T.studioBgPair, T.timelineSurfacePair] {
            XCTAssertLessThan(p.dark.relativeLuminance, 0.05); XCTAssertGreaterThan(p.light.relativeLuminance, 0.7)
        }
        XCTAssertGreaterThan(T.whitePair.dark.relativeLuminance, 0.99); XCTAssertLessThan(T.whitePair.light.relativeLuminance, 0.01)
        for n in [100, 200, 300, 600, 700, 800, 900] { XCTAssertEqual(T.neutralPairs[n]!.light, T.neutralPairs[1000 - n]!.dark, "neutral\(n)") }
        XCTAssertGreaterThan(T.mintPair.light.b, T.mintPair.light.r)   // still the accent blue
        XCTAssertGreaterThan(T.studioAccentPair.light.b, T.studioAccentPair.light.r)   // still blue
    }

    // MARK: Token coverage

    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    /// UI modules whose chrome must draw through the theme tokens.
    static let uiModules = ["MpvfxPanels", "MpvfxTimeline", "MpvfxPlayer", "MpvfxDesktop"]
    /// Raw colour literals: hex strings (CanvasColor(hex:) or a bare "#rrggbb" literal; JSON document data is skipped), rgba(...) shorthands, numeric CanvasColor(r:g:b:), ThemeColor(0x...), NSColor literals.
    static let rawColor = try! NSRegularExpression(pattern:
        ##"CanvasColor\(hex: *"|(?<![A-Za-z])\.rgba\(|CanvasColor\(r: *[0-9.]+ *, *g: *[0-9.]+|ThemeColor\(0x|NSColor\(srgbRed: *0x|NSColor\(calibratedRed|NSColor\.(black|white|darkGray)|(?<![:\\])"#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?""##)

    /// No hard-coded colours left in panels, timeline, preview chrome or the shells: every colour is a token
    /// (MpvfxTheme/ThemeTokens.swift, which PanelTheme/PanelStyle/TimelineTheme read), so both palettes cover it.
    func testNoRawColorsOutsideTokens() throws {
        var hits: [String] = []
        for module in Self.uiModules {
            let dir = Self.repo.appendingPathComponent("Sources/\(module)")
            guard let files = FileManager.default.enumerator(atPath: dir.path) else { XCTFail("missing \(dir.path)"); continue }
            for case let f as String in files where f.hasSuffix(".swift") {
                let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
                for (i, line) in text.components(separatedBy: "\n").enumerated() {
                    let code = line.components(separatedBy: "//").first ?? line
                    let r = NSRange(code.startIndex..., in: code)
                    if Self.rawColor.firstMatch(in: code, range: r) != nil { hits.append("\(module)/\(f):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))") }
                }
            }
        }
        XCTAssertEqual(hits, [], "raw colours (use a ThemeTokens/PanelTheme token):\n" + hits.joined(separator: "\n"))
    }

    // MARK: No colour captured once

    /// `ThemeTokens` members that are the same in both modes (`static let X = ThemeColor(...)` and friends, no `Pair`).
    static func fixedTokenNames() throws -> Set<String> {
        var names: Set<String> = []
        for f in ["ThemeTokens.swift", "FxRackTokens.swift"] {
            let text = try String(contentsOf: repo.appendingPathComponent("Sources/MpvfxTheme/\(f)"), encoding: .utf8)
            for line in text.components(separatedBy: "\n") where line.contains("static let ") && !line.contains("Pair") {
                let decl = try NSRegularExpression(pattern: #"(?:static let|,)\s+(\w+)\s*(?::[^=]+)?="#)
                for m in decl.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    if let r = Range(m.range(at: 1), in: line) { names.insert(String(line[r])) }
                }
            }
        }
        return names
    }

    /// Colour members of a token facade (`static var name: CanvasColor { ... }`, read at each use).
    static func computedColorNames(_ path: String) throws -> Set<String> {
        let text = try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
        let re = try NSRegularExpression(pattern: #"static (?:var|let) (\w+): CanvasColor\b"#)
        return Set(re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } })
    }

    /// A stored declaration (evaluated once, not at draw time): `static let/var x = ...`, `lazy var x = ...`, or a
    /// type member `let/var x = ...` (four-space indent; locals in function bodies are deeper and run per draw).
    static let storedDeclaration = try! NSRegularExpression(pattern:
        #"(?:\bstatic\s+(?:let|var)|\blazy\s+var)\s+\w+\s*(?::[^={]+)?=(?!=)|^    (?:(?:public|private|fileprivate|internal|open|final|nonisolated\(unsafe\)|private\(set\)|public private\(set\))\s+)*(?:let|var)\s+\w+\s*(?::[^={]+)?=(?!=)"#)

    /// Whether `code` (one line, comments stripped) stores a value derived from a mode-dependent token.
    static func capturesModeColor(_ code: String, fixed: Set<String>, facades: [String: Set<String>]) -> Bool {
        guard storedDeclaration.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil else { return false }
        if code.contains(".now") || code.contains("Theme.mode") || code.contains("TimelineTheme.default.") || code.contains("TimelineTheme().") { return true }
        // A colour built from a pair when the declaration runs (`static let x: CanvasColor = c(T.somethingPair)`).
        if code.range(of: #"\b(CanvasColor|ThemeColor)\b"#, options: .regularExpression) != nil,
           code.range(of: #"\w+Pairs?\b"#, options: .regularExpression) != nil { return true }
        let ref = try! NSRegularExpression(pattern: #"\b(ThemeTokens|T|PanelTheme|PanelStyle)\.(\w+)"#)
        for m in ref.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let t = Range(m.range(at: 1), in: code), let n = Range(m.range(at: 2), in: code) else { continue }
            let type = String(code[t]) == "T" ? "ThemeTokens" : String(code[t]), name = String(code[n])
            // A stored ThemePair is fine: its colour is picked (`.now`, caught above) when it is drawn.
            let pair = name.hasSuffix("Pair") || name.hasSuffix("Pairs")
            if type == "ThemeTokens" ? !fixed.contains(name) && !pair : facades[type]?.contains(name) == true { return true }
        }
        return false
    }

    /// Every source line of the UI modules (and the canvas), comments stripped, with "module/file:line: text".
    static func uiSourceLines() throws -> [(code: String, at: String)] {
        var out: [(code: String, at: String)] = []
        for module in uiModules + ["MpvfxCanvas"] {
            let dir = repo.appendingPathComponent("Sources/\(module)")
            guard let files = FileManager.default.enumerator(atPath: dir.path) else { throw CocoaError(.fileNoSuchFile) }
            for case let f as String in files where f.hasSuffix(".swift") {
                let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
                for (i, line) in text.components(separatedBy: "\n").enumerated() {
                    out.append((line.components(separatedBy: "//").first ?? line, "\(module)/\(f):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))"))
                }
            }
        }
        return out
    }

    /// No UI module keeps a colour derived from a mode-dependent token in a stored property or static: such a value
    /// is computed once and a live appearance switch would not reach it. Fixed tokens (the stage, guides, band
    /// edges) may be stored.
    func testNoColourCapturedFromAModeToken() throws {
        let fixed = try Self.fixedTokenNames()
        let facades = ["PanelTheme": try Self.computedColorNames("Sources/MpvfxPanels/PanelTheme.swift"),
                       "PanelStyle": try Self.computedColorNames("Sources/MpvfxPanels/PanelStyle.swift")]
        XCTAssertTrue(fixed.isSuperset(of: ["stageCanvas", "guide", "stageInk", "bandEdges", "nativeRangeEdge"]))
        XCTAssertFalse(fixed.contains("studioAccent") || fixed.contains("neutralPairs") || fixed.contains("white"))
        XCTAssertTrue(facades["PanelTheme"]!.isSuperset(of: ["panelBg", "text1", "seamHover"]))
        // The scanner itself: what it must flag and what it must leave alone.
        let flagged = ["    public static let accent = CanvasColor(ThemeTokens.studioAccent)", "    let bg = PanelTheme.panelBg",
                       "    private var ink: CanvasColor = CanvasColor(ThemeTokens.white)", "static var c = ThemeTokens.mintPair.now",
                       "    lazy var edge = PanelStyle.popoverBorder", "    public static let rows = TimelineTheme.default.rowBackground",
                       "    static let wash = CanvasColor(T.panelHover)", "    public static let panelBg: CanvasColor = c(T.panelBgPair)"]
        let left = ["    public static let canvasSurface = CanvasColor(ThemeTokens.stageCanvas)", "        let bg = PanelTheme.panelBgInset",
                    "    public static var panelBg: CanvasColor { c(T.panelBgPair) }", "    public static let `default` = TimelineTheme()",
                    "    public static let onAccent = CanvasColor(T.onAccent)", "    let font = PanelTheme.font(11)",
                    "    static let tabs: [(String, ThemePair)] = [(\"master\", ThemeTokens.curveMasterPair)]"]
        XCTAssertEqual(flagged.filter { !Self.capturesModeColor($0, fixed: fixed, facades: facades) }, [], "missed by the scanner")
        XCTAssertEqual(left.filter { Self.capturesModeColor($0, fixed: fixed, facades: facades) }, [], "wrongly flagged")
        let hits = try Self.uiSourceLines().filter { Self.capturesModeColor($0.code, fixed: fixed, facades: facades) }.map(\.at)
        XCTAssertEqual(hits, [], "colours captured once from a mode-dependent token (read the token at draw time):\n" + hits.joined(separator: "\n"))
    }
}

private typealias T = ThemeTokens
