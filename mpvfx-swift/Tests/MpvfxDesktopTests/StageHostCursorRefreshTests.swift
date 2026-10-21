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
import MpvfxCanvas
import MpvfxTimeline
@testable import MpvfxDesktop
#if os(Linux)
import CGtk3

/// The native host must apply the router's new shape even when no motion event follows the state change.
final class StageHostCursorRefreshTests: XCTestCase {
    final class Input: CanvasInput {
        var shape = EditorShellRouter.Cursor.move
        var moves: [(Double, Double, PointerModifiers)] = []
        func pointerDown(x: Double, y: Double, shift: Bool) { shape = .crosshair }
        func pointerMove(x: Double, y: Double) {}
        func pointerMove(x: Double, y: Double, modifiers: PointerModifiers) {
            moves.append((x, y, modifiers)); shape = modifiers.isEmpty ? .move : .notAllowed
        }
        func pointerUp(x: Double, y: Double) { shape = .arrow }
        func secondaryClick(x: Double, y: Double) {}
        func scroll(dx: Double, dy: Double, x: Double, ctrl: Bool, shift: Bool) {}
        func keyDown(_ k: EditorKey) -> Bool { false }
        func keyUp(_ k: EditorKey) {}
        func resized(_ size: CanvasSize) {}
    }

    func withHost(_ body: (GtkCanvasHost, OpaquePointer, Input) throws -> Void) throws {
        guard gtk_init_check(nil, nil) != 0 else { throw XCTSkip("requires a display; run under xvfb-run") }
        let host = GtkCanvasHost { _, _ in }
        let input = Input()
        host.input = input
        host.cursorAt = { _, _ in input.shape }
        let window = try XCTUnwrap(gtk_window_new(GTK_WINDOW_TOPLEVEL))
        gtk_container_add(UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkContainer.self), host.widget)
        gtk_window_set_default_size(UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self), 300, 200)
        gtk_widget_show_all(window)
        defer { gtk_widget_destroy(window) }
        while gtk_events_pending() != 0 { _ = gtk_main_iteration_do(0) }
        let native = try XCTUnwrap(gtk_widget_get_window(host.widget))
        host.lastPoint = (20, 30)
        host.refreshCursor()
        try body(host, native, input)
    }

    func testInvalidationChangesTheNativeCursorWithoutPointerMotion() throws {
        try withHost { host, window, input in
            let previous = try XCTUnwrap(gdk_window_get_cursor(window))
            _ = g_object_ref(UnsafeMutableRawPointer(previous))
            defer { g_object_unref(UnsafeMutableRawPointer(previous)) }
            input.shape = .arrow   // opening Settings changes the router without moving the mouse
            host.invalidate()
            let current = try XCTUnwrap(gdk_window_get_cursor(window))
            XCTAssertNotEqual(previous, current)
            host.invalidate()
            XCTAssertEqual(current, gdk_window_get_cursor(window), "an unchanged shape reuses the native cursor")
            XCTAssertTrue(input.moves.isEmpty, "redrawing must not simulate a pointer move")
        }
    }

    func testEveryModifierTransitionResendsTheStationaryPointerAndAppliesTheCursor() throws {
        try withHost { host, window, input in
            let cases: [(Int32, guint, PointerModifiers)] = [
                (GDK_KEY_Alt_L, GDK_MOD1_MASK.rawValue, .alt),
                (GDK_KEY_Shift_R, GDK_SHIFT_MASK.rawValue, .shift),
                (GDK_KEY_Control_L, GDK_CONTROL_MASK.rawValue, .ctrl),
                (GDK_KEY_Super_R, GDK_SUPER_MASK.rawValue, .meta),
            ]
            for (key, mask, modifier) in cases {
                let previous = try XCTUnwrap(gdk_window_get_cursor(window))
                _ = g_object_ref(UnsafeMutableRawPointer(previous))
                defer { g_object_unref(UnsafeMutableRawPointer(previous)) }
                var event = GdkEventKey()
                event.keyval = guint(key)
                host.modifierChanged(event, pressed: true)
                XCTAssertEqual(input.moves.last?.2, modifier)
                XCTAssertEqual(input.moves.last?.0, 20); XCTAssertEqual(input.moves.last?.1, 30)
                XCTAssertNotEqual(previous, gdk_window_get_cursor(window))
                event.state = mask
                host.modifierChanged(event, pressed: false)
                XCTAssertEqual(input.moves.last?.2, [])
                XCTAssertEqual(input.shape, .move)
            }
            XCTAssertEqual(input.moves.count, cases.count * 2)
        }
    }

    func testButtonCaptureAndReleaseApplyTheNewCursorBeforeAnotherMotion() throws {
        try withHost { host, window, input in
            func send(_ type: GdkEventType) throws {
                let event = try XCTUnwrap(gdk_event_new(type))
                defer { gdk_event_free(event) }
                let button = UnsafeMutableRawPointer(event).assumingMemoryBound(to: GdkEventButton.self)
                button.pointee.window = window
                _ = g_object_ref(UnsafeMutableRawPointer(window))   // freed with the event
                button.pointee.send_event = 1
                button.pointee.button = 1
                button.pointee.x = 20; button.pointee.y = 30
                let seat = gdk_display_get_default_seat(gdk_window_get_display(window))
                gdk_event_set_device(event, gdk_seat_get_pointer(seat))
                XCTAssertEqual(gtk_widget_event(host.widget, event), 1)
            }
            let previous = try XCTUnwrap(gdk_window_get_cursor(window))
            _ = g_object_ref(UnsafeMutableRawPointer(previous))
            defer { g_object_unref(UnsafeMutableRawPointer(previous)) }
            try send(GDK_BUTTON_PRESS)
            XCTAssertEqual(input.shape, .crosshair)
            let captured = try XCTUnwrap(gdk_window_get_cursor(window))
            _ = g_object_ref(UnsafeMutableRawPointer(captured))
            defer { g_object_unref(UnsafeMutableRawPointer(captured)) }
            XCTAssertNotEqual(previous, captured)
            try send(GDK_BUTTON_RELEASE)
            XCTAssertEqual(input.shape, .arrow)
            XCTAssertNotEqual(captured, gdk_window_get_cursor(window))
            XCTAssertTrue(input.moves.isEmpty)
        }
    }

    func testPaintingCanChangeTheCursorUnderAStationaryPointer() throws {
        try withHost { host, window, input in
            let previous = try XCTUnwrap(gdk_window_get_cursor(window))
            _ = g_object_ref(UnsafeMutableRawPointer(previous))
            defer { g_object_unref(UnsafeMutableRawPointer(previous)) }
            host.paint = { _, _ in input.shape = .notAllowed }
            let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 300, 200)!
            defer { cairo_surface_destroy(surface) }
            let context = cairo_create(surface)!
            defer { cairo_destroy(context) }
            gtk_widget_draw(host.widget, context)
            XCTAssertNotEqual(previous, gdk_window_get_cursor(window))
            XCTAssertTrue(input.moves.isEmpty)
        }
    }
}
#endif
