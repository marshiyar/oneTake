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
#if os(Linux)
import XCTest
import Foundation
import MpvfxCanvas
import MpvfxShared
import MpvfxPanels
@testable import MpvfxDesktop

final class BackgroundGeneratorHostTests: XCTestCase {
    func testMediaGeneratorActionSelectsClipAndOpensDesignAtPlayhead() throws {
        let dir = NSTemporaryDirectory() + "generator-host-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let session = try EditorSession(backend: nil, projectPath: nil, demo: true)
        defer { session.audio?.stop() }
        let router = session.installShell(userData: dir) {}
        router.draw(PanelMeasureCanvas(), size: CanvasSize(1440, 900))
        let panels = try XCTUnwrap(session.panels)
        panels.left.onAddGenerator?(.radial)
        let id = try XCTUnwrap(session.timeline.view.selection.first)
        XCTAssertEqual(session.editor.clip(id)?.clip.generator?.gradientType, "radial")
        XCTAssertEqual(panels.right.inspector.selection, [id]); XCTAssertEqual(panels.right.inspector.openGroupId, "generator")
        XCTAssertEqual(panels.right.layout.rightPanelTab, .design)
        XCTAssertEqual(session.editor.undoStack.count, 1)
    }
}
#endif
