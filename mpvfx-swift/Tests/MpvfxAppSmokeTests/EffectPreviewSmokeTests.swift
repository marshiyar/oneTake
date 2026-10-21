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
/// The real app at 1440×900 under Xvfb, the demo timeline's clip selected and the Design tab's Effects group open
/// (`openInspectorGroup` in `<userData>/panel-layout.json`, the preference the app restores): the catalog tiles show
/// the graded sample picture in dark and light. Before the fix they were empty grey frames, so the right panel held
/// no saturated colour but the accent. `MPVFX_SNAPSHOT_DIR` keeps the window snapshots (`effects-grid-<mode>.png`).
final class EffectPreviewSmokeTests: XCTestCase {
    static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    struct SmokeError: Error, CustomStringConvertible { let description: String }
    typealias Shot = (rgba: [UInt8], width: Int, height: Int)

    func binary() throws -> String {
        for rel in [".build/debug/MpVFX", ".build/out/Products/Debug-linux-x86_64/MpVFX"] {
            let p = Self.packageRoot.appendingPathComponent(rel).path
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        throw SmokeError(description: "MpVFX is not built: run `swift build` (scripts/check.sh builds before testing)")
    }

    func xvfbRun() throws -> String {
        for p in ["/usr/bin/xvfb-run", "/usr/local/bin/xvfb-run"] where FileManager.default.isExecutableFile(atPath: p) { return p }
        throw XCTSkip("xvfb-run is not installed (apt install xvfb); the effects grid is not captured on this machine")
    }

    /// Launches the demo in `mode` with the Effects group open and returns the window snapshot.
    func snapshot(_ mode: String) throws -> Shot {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mpvfx-fx-grid-\(UUID().uuidString)")
        let user = dir.appendingPathComponent("user")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"openInspectorGroup":"effects"}"#.utf8).write(to: user.appendingPathComponent("panel-layout.json"))
        let png = dir.appendingPathComponent("snap.png").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try xvfbRun())
        p.arguments = ["-a", "-s", "-screen 0 1440x900x24", try binary()]
        var env = ProcessInfo.processInfo.environment
        env["MPVFX_USER_DATA_DIR"] = user.path
        env["MPVFX_DEMO"] = "1"; env["MPVFX_AUDIO_OUTPUT"] = "null"; env["MPVFX_APPEARANCE"] = mode
        env["MPVFX_SMOKE_SELECT"] = "clip:a"; env["MPVFX_SMOKE_DELAY_MS"] = "3000"; env["MPVFX_SMOKE_SNAPSHOT"] = png
        p.environment = env
        let log = dir.appendingPathComponent("app.log")
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let out = try FileHandle(forWritingTo: log)
        p.standardOutput = out; p.standardError = out
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        try p.run()
        if done.wait(timeout: .now() + 120) == .timedOut { p.terminate(); XCTFail("MpVFX did not quit after its snapshot") }
        try out.close()
        guard let data = FileManager.default.contents(atPath: png) else {
            throw SmokeError(description: "no snapshot in \(mode):\n" + ((try? String(contentsOf: log, encoding: .utf8)) ?? ""))
        }
        keep(data, "effects-grid-\(mode).png")
        let shot = try ImageCodec.decode(data)
        XCTAssertEqual([shot.width, shot.height], [1440, 900], "the window snapshot is the 1440×900 display")
        return shot
    }

    func keep(_ data: Data, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["MPVFX_SNAPSHOT_DIR"] else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        XCTAssertNoThrow(try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name)))
    }

    /// Saturated pixels in the right panel (x 1020…1430) that are not the accent blue (#4c8df0 and its tints).
    func saturatedPixels(_ img: Shot) -> Int {
        var n = 0
        for y in 40..<min(900, img.height) { for x in 1020..<min(1430, img.width) {
            let i = (y * img.width + x) * 4
            let r = Int(img.rgba[i]), g = Int(img.rgba[i + 1]), b = Int(img.rgba[i + 2])
            let accentLike = b > r + 60 && b > g + 20 && abs((g - r) - 65) < 40
            if max(r, g, b) - min(r, g, b) > 90, !accentLike { n += 1 }
        } }
        return n
    }

    // Measured at 1440×900 on Linux/Xvfb: 2692 (dark) and 2601 (light) saturated pixels with the three Essentials
    // tiles drawn; the panel outside the tile frames holds 91 and 0 (the clip icon), which is all the blank tiles showed.

    func testEffectsGridShowsTheGradedSampleInDark() throws {
        XCTAssertGreaterThan(saturatedPixels(try snapshot("dark")), 1000, "dark: the effect tiles show no picture")
    }

    func testEffectsGridShowsTheGradedSampleInLight() throws {
        XCTAssertGreaterThan(saturatedPixels(try snapshot("light")), 1000, "light: the effect tiles show no picture")
    }
}
#endif
