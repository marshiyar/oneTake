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

/// docs/DESIGN.md "Words": the copy a user reads in the editor. Two rules are checked on the source of the UI
/// modules (the same scan shape as `ThemeTokensTests.testNoRawColorsOutsideTokens`):
///
/// 1. A user-facing message never interpolates a raw error (`"\(error)"`): Swift prints the error's debug form
///    (`DesktopError(code: …, message: …)`), which tells the user nothing they can act on. Say what failed and what
///    to do, from the error's own message. Ratchet: `rawErrorBaseline` holds today's count per file; a file may go
///    below it (then lower the number) but never above it, and a new file starts at zero.
/// 2. An ellipsis in user text is the single character "…" (U+2026), never three full stops. No baseline.
final class UICopyTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    /// Modules whose strings reach the user: panels, timeline, preview, the shells and their shared logic.
    static let uiModules = ["MpvfxPanels", "MpvfxTimeline", "MpvfxPlayer", "MpvfxDesktop", "MpvfxDesktopCore"]

    /// A raw error interpolated into a string: `\(error)`, `\(err)`, `\(e)`.
    static let rawError = try! NSRegularExpression(pattern: ##"\\\((?:error|err|e)\)"##)
    /// Where a string becomes something the user reads: an error dialog or alert, a toast, a panel's error line, an
    /// edit failure's message (shown as a toast), an import result's reason.
    static let userSink = try! NSRegularExpression(pattern:
        ##"onError\(|box\(|informativeText|messageText|toast\(|message: |reason: |[eE]rror = |[fF]ailure = "##)
    /// Lines that only write a log for developers (stderr, stdout), never shown in the UI.
    static let logLine = try! NSRegularExpression(pattern: ##"standardError|print\(|NSLog|debugPrint"##)
    /// Three full stops after a letter or a space inside a string literal ("Search assets..."); ranges such as
    /// `"a"..."z"` and `0...1` are outside the quotes and not matched.
    static let threeDots = try! NSRegularExpression(pattern: ##""[^"]*[A-Za-z ]\.\.\.[^"]*""##)

    /// Raw error interpolations into user-facing messages at this revision, per file (measured when the test was added). Lower a
    /// number when you replace one with a message the user can act on; remove the line at zero. Never raise one.
    static let rawErrorBaseline: [String: Int] = [
        "MpvfxDesktop/EditorSession+Panels.swift": 6,
        "MpvfxDesktop/EditorSession+Renders.swift": 1,
        "MpvfxDesktop/EditorSession+TimelineHooks.swift": 1,
        "MpvfxDesktop/EditorSession.swift": 4,
        "MpvfxDesktop/LinuxShell.swift": 2,
        "MpvfxDesktop/MacShell.swift": 1,
        "MpvfxDesktop/WindowsShell.swift": 4,
        "MpvfxPlayer/ExportFramePainter.swift": 1,
        "MpvfxTimeline/TimelineEditor+Canvas.swift": 1,
        "MpvfxTimeline/TimelineEditor+ClipMenu.swift": 2,
        "MpvfxTimeline/TimelineEditor+Clips.swift": 1,
        "MpvfxTimeline/TimelineEditor+Ripple.swift": 1,
        "MpvfxTimeline/TimelineEditor.swift": 1,
    ]

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
    static func isRawErrorMessage(_ code: String) -> Bool {
        !matches(logLine, code) && matches(rawError, code) && matches(userSink, code)
    }
    static func hasThreeDots(_ code: String) -> Bool { !matches(logLine, code) && matches(threeDots, code) }

    /// Every source line of the UI modules, comments stripped, with its file as "module/file" and "module/file:line: text".
    static func uiSourceLines() throws -> [(code: String, file: String, at: String)] {
        var out: [(code: String, file: String, at: String)] = []
        for module in uiModules {
            let dir = repo.appendingPathComponent("Sources/\(module)")
            guard let files = FileManager.default.enumerator(atPath: dir.path) else { throw CocoaError(.fileNoSuchFile) }
            for case let f as String in files where f.hasSuffix(".swift") {
                let file = "\(module)/\(f.replacingOccurrences(of: "\\", with: "/"))"
                let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
                for (i, line) in text.components(separatedBy: "\n").enumerated() {
                    out.append((line.components(separatedBy: "//").first ?? line, file, "\(file):\(i + 1): \(line.trimmingCharacters(in: .whitespaces))"))
                }
            }
        }
        return out
    }

    /// The scanners themselves: what they must flag and what they must leave alone.
    func testTheScannersFlagWhatTheRulesSay() {
        let raw = [#"} catch { onError("Could not save the project", "\(error)") }"#,
                   #"box(nil, "MpVFX could not start", "\(error)"); exit(1)"#,
                   #"self.renders.loadError = "Couldn't load render history (\(e))."#,
                   #"lastFailure = NativeProjectClipFailure(code: .documentMismatch, message: "\(error)")"#,
                   #"toast("Export failed: \(err)", true)"#]
        let notRaw = [#"FileHandle.standardError.write(Data("[MpVFX] drawing failed: \(error)\n".utf8))"#,
                      #"print("[MpVFX] smoke snapshot -> \(path) failed: \(error)")"#,
                      #"for e in f.extensions { gtk_file_filter_add_pattern(filter, "*.\(e)") }"#,
                      #"onError("Could not save the project", (error as? DesktopError)?.message ?? "The disk is full.")"#,
                      #"do { try save(); return nil } catch { return "\(error)" }"#]
        XCTAssertEqual(raw.filter { !Self.isRawErrorMessage($0) }, [], "missed by the raw-error scanner")
        XCTAssertEqual(notRaw.filter { Self.isRawErrorMessage($0) }, [], "wrongly flagged by the raw-error scanner")
        let dots = [#"text.isEmpty ? "Search assets..." : text"#, #"label: "Loading ...""#]
        let notDots = [#"("a"..."z").contains(c)"#, #"limited(o?["min"], fallback: 0, 0...1)"#, #"label: "Search assets…""#,
                       #"String(path[...path.lastIndex(of: "/")!])"#]
        XCTAssertEqual(dots.filter { !Self.hasThreeDots($0) }, [], "missed by the ellipsis scanner")
        XCTAssertEqual(notDots.filter { Self.hasThreeDots($0) }, [], "wrongly flagged by the ellipsis scanner")
    }

    /// Rule 1, as a ratchet: no file shows more raw errors to the user than the baseline allows.
    func testNoNewRawErrorInUserMessages() throws {
        var counts: [String: Int] = [:], lines: [String: [String]] = [:]
        for l in try Self.uiSourceLines() where Self.isRawErrorMessage(l.code) {
            counts[l.file, default: 0] += 1; lines[l.file, default: []].append(l.at)
        }
        let over = counts.filter { $0.value > (Self.rawErrorBaseline[$0.key] ?? 0) }.keys.sorted()
            .map { "\($0): \(counts[$0]!) > baseline \(Self.rawErrorBaseline[$0] ?? 0)\n  " + lines[$0]!.joined(separator: "\n  ") }
        XCTAssertEqual(over, [], "a raw error reaches the user (docs/DESIGN.md \"Words\"); show its message and what to do:\n"
                       + over.joined(separator: "\n"))
        let under = Self.rawErrorBaseline.filter { (counts[$0.key] ?? 0) < $0.value }.keys.sorted()
            .map { "\"\($0)\": \(counts[$0] ?? 0),   // was \(Self.rawErrorBaseline[$0]!)" }
        XCTAssertEqual(under, [], "fewer raw errors than the baseline: lower rawErrorBaseline (remove a line at 0):\n"
                       + under.joined(separator: "\n"))
    }

    /// Rule 2: "…" (U+2026), never "...", in the UI's strings.
    func testEllipsisIsOneCharacter() throws {
        let hits = try Self.uiSourceLines().filter { Self.hasThreeDots($0.code) }.map { $0.at }
        XCTAssertEqual(hits, [], "three full stops in user text (write \"…\", U+2026):\n" + hits.joined(separator: "\n"))
    }
}
