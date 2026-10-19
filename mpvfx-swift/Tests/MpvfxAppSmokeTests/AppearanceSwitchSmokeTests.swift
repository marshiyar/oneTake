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
import OneTakeMedia

#if os(Linux)
/// The real app, switched between Light and Dark while it runs, paints every surface exactly as a launch in that mode
/// does. Runs the built `MpVFX` binary (`swift build` first; `scripts/check.sh` does) with the demo timeline under a
/// 1440×900 Xvfb display, once per case, and compares the window snapshots (`MPVFX_SMOKE_SNAPSHOT`, which draws the
/// window through GTK) surface by surface. The switch goes through `EditorSession.setAppearance`, the entry point of
/// the View menu (macOS) and the Shortcuts card's Appearance row; `MPVFX_SMOKE_SET_APPEARANCE` makes it half a
/// second before the snapshot, after the first paint.
final class AppearanceSwitchSmokeTests: XCTestCase {
    static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The editor's major surfaces in the 1440×900 demo window (window points; the layout is the default one).
    static let surfaces: [(name: String, x: Range<Int>, y: Range<Int>)] = [
        ("library / media bin", 20..<360, 150..<520),
        ("preview surround and stage toolbar", 400..<1000, 40..<110),
        ("stage chrome under the picture", 400..<1000, 460..<495),
        ("transport", 395..<1005, 500..<532),
        ("timeline toolbar", 5..<1430, 545..<570),
        ("timeline ruler", 270..<1430, 575..<605),
        ("timeline track headers", 5..<230, 615..<755),
        ("timeline tracks", 270..<1430, 615..<755),
        ("inspector / right panel", 1020..<1430, 60..<520),
    ]

    struct SmokeError: Error, CustomStringConvertible { let description: String; init(_ d: String) { description = d } }
    struct Shot { var rgba: [UInt8]; var width: Int; var height: Int }

    func binary() throws -> String {
        for rel in [".build/debug/MpVFX", ".build/out/Products/Debug-linux-x86_64/MpVFX"] {
            let p = Self.packageRoot.appendingPathComponent(rel).path
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        throw SmokeError("MpVFX is not built: run `swift build` (scripts/check.sh builds before testing)")
    }

    func xvfbRun() throws -> String {
        for p in ["/usr/bin/xvfb-run", "/usr/local/bin/xvfb-run"] where FileManager.default.isExecutableFile(atPath: p) { return p }
        throw XCTSkip("xvfb-run is not installed (apt install xvfb); the live appearance switch is not checked on this machine")
    }

    /// Launches the app in `mode` (optionally switching to `switchTo` after the first paint) and returns its snapshot.
    func snapshot(_ mode: String, switchTo: String? = nil) throws -> Shot {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mpvfx-appearance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("snap.png").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try xvfbRun())
        p.arguments = ["-a", "-s", "-screen 0 1440x900x24", try binary()]
        var env = ProcessInfo.processInfo.environment
        env["MPVFX_USER_DATA_DIR"] = dir.appendingPathComponent("user").path
        env["MPVFX_DEMO"] = "1"; env["MPVFX_AUDIO_OUTPUT"] = "null"
        env["MPVFX_APPEARANCE"] = mode
        env["MPVFX_SMOKE_SELECT"] = "clip:a"   // the inspector shows the clip's rows, the timeline its selection
        env["MPVFX_SMOKE_DELAY_MS"] = "3000"
        env["MPVFX_SMOKE_SNAPSHOT"] = png
        env["MPVFX_SMOKE_SET_APPEARANCE"] = switchTo
        p.environment = env
        let log = dir.appendingPathComponent("app.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let out = try FileHandle(forWritingTo: log)
        p.standardOutput = out; p.standardError = out
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        try p.run()
        if done.wait(timeout: .now() + 120) == .timedOut { p.terminate(); XCTFail("MpVFX did not quit after its snapshot") }
        try? out.close()
        guard let data = FileManager.default.contents(atPath: png) else {
            throw SmokeError("no snapshot from \(mode)→\(switchTo ?? "-"):\n" + ((try? String(contentsOf: log, encoding: .utf8)) ?? ""))
        }
        let img = try ImageCodec.decode(data)
        return Shot(rgba: img.rgba, width: img.width, height: img.height)
    }

    /// Mean absolute channel difference over a surface (0…255).
    func meanDiff(_ a: Shot, _ b: Shot, _ x: Range<Int>, _ y: Range<Int>) -> Double {
        var sum = 0, n = 0
        for yy in y { for xx in x {
            let i = (yy * a.width + xx) * 4
            for c in 0..<3 { sum += abs(Int(a.rgba[i + c]) - Int(b.rgba[i + c])) }
            n += 3
        } }
        return Double(sum) / Double(max(1, n))
    }

    /// Share of pixels whose largest channel difference exceeds `tolerance`.
    func changedShare(_ a: Shot, _ b: Shot, tolerance: Int = 8) -> Double {
        var changed = 0
        for i in stride(from: 0, to: a.rgba.count, by: 4) where (0..<3).contains(where: { abs(Int(a.rgba[i + $0]) - Int(b.rgba[i + $0])) > tolerance }) {
            changed += 1
        }
        return Double(changed) / Double(max(1, a.rgba.count / 4))
    }

    func testLiveSwitchMatchesALaunchInThatMode() throws {
        let dark = try snapshot("dark"), light = try snapshot("light")
        let toLight = try snapshot("dark", switchTo: "light"), toDark = try snapshot("light", switchTo: "dark")
        XCTAssertEqual([dark, light, toLight, toDark].map { [$0.width, $0.height] }, Array(repeating: [1440, 900], count: 4))
        Self.surfaces.forEach { s in
            // The surface really has two palettes (the check below would be empty otherwise) ...
            XCTAssertGreaterThan(meanDiff(dark, light, s.x, s.y), 40, "\(s.name): dark and light launches look alike")
            // ... and a live switch reaches it, both ways.
            XCTAssertLessThanOrEqual(meanDiff(toLight, light, s.x, s.y), 1.5, "\(s.name): dark → light differs from a light launch")
            XCTAssertLessThanOrEqual(meanDiff(toDark, dark, s.x, s.y), 1.5, "\(s.name): light → dark differs from a dark launch")
        }
        XCTAssertLessThan(changedShare(toLight, light), 0.001, "dark → light: whole window")
        XCTAssertLessThan(changedShare(toDark, dark), 0.001, "light → dark: whole window")
    }
}
#endif
