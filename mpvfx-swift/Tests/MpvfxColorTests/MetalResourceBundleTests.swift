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
#if canImport(MpvfxMetal)
import XCTest
import Metal
import MpvfxMetal

/// The installed app keeps the kernels' resource bundle in MpVFX.app/Contents/Resources, where SwiftPM's
/// `Bundle.module` never looks (it crashed the downloaded app at launch, CI run 39198405420's disk image).
final class MetalResourceBundleTests: XCTestCase {
    func testFindsTheBundleInAnInstalledAppsResources() throws {
        let built = try XCTUnwrap(MetalGradePipeline.resourceBundle(), "the test run's own resource bundle")
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("MpVFX-\(UUID().uuidString).app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        try FileManager.default.copyItem(at: built.bundleURL,
                                         to: resources.appendingPathComponent(MetalGradePipeline.resourceBundleName))
        let found = try XCTUnwrap(MetalGradePipeline.resourceBundle(searching: [resources, app]))
        XCTAssertEqual(found.bundleURL.resolvingSymlinksInPath().deletingLastPathComponent().path,
                       resources.resolvingSymlinksInPath().path)
        XCTAssertNotNil(found.url(forResource: "MpvfxColorShared", withExtension: "h")
                        ?? found.url(forResource: "MpvfxColorShared", withExtension: "h", subdirectory: "Shaders"))
    }

    func testAMissingBundleIsNilNotACrash() {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("no-bundle-\(UUID().uuidString)")
        XCTAssertNil(MetalGradePipeline.resourceBundle(searching: [empty, nil]))
    }
}
#endif
