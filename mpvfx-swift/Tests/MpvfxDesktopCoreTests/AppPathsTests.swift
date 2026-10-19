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
import XCTest
@testable import MpvfxDesktopCore

final class AppPathsTests: XCTestCase {
    func testIsolatedUserDataScopesInstanceLock() {
        let a = AppPaths.resolve(env: ["MPVFX_USER_DATA_DIR": "/tmp/a"], executable: "/x")
        let b = AppPaths.resolve(env: ["MPVFX_USER_DATA_DIR": "/tmp/b"], executable: "/x")
        XCTAssertNotEqual(a.appId, b.appId)
        XCTAssertTrue(a.appId.hasPrefix("com.mpvfx.editor.u"))
        XCTAssertEqual(a.userData, "/tmp/a")
        let shared = AppPaths.resolve(env: ["XDG_CONFIG_HOME": "/c"], executable: "/x")
        XCTAssertEqual(shared.appId, "com.mpvfx.editor")
        XCTAssertEqual(shared.userData, "/c/MpVFX")
    }

    func testStubBackendIsExplicit() async {
        do { _ = try await NotImplementedBackend().importFiles(projectId: "p", paths: [], directory: nil); XCTFail("expected an error") }
        catch { XCTAssertTrue("\(error)".contains("not implemented")) }
    }
}
