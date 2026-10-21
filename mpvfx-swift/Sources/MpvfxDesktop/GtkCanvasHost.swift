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
import CGtk3
import MpvfxCanvas
import MpvfxTimeline

/// GtkDrawingArea forwarding "draw" to a CanvasContext painter and input to a CanvasInput.
/// Thin: no logic beyond translating GDK events.
final class GtkCanvasHost {
    let widget: UnsafeMutablePointer<GtkWidget>
    var paint: (CanvasContext, CanvasSize) -> Void
    weak var input: CanvasInput?
    var lastSize = CanvasSize(0, 0)
    /// A file drag from the file manager moved over the canvas (nil: it left).
    var onFilesDragged: ((CanvasPoint?) -> Void)?
    /// Files dropped from the file manager (local paths, canvas points).
    var onFilesDropped: (([String], CanvasPoint) -> Void)?

    init(paint: @escaping (CanvasContext, CanvasSize) -> Void) {
        self.paint = paint
        widget = gtk_drawing_area_new()!
        gtk_widget_set_can_focus(widget, 1)
        let mask = GDK_BUTTON_PRESS_MASK.rawValue | GDK_BUTTON_RELEASE_MASK.rawValue | GDK_POINTER_MOTION_MASK.rawValue |
            GDK_SCROLL_MASK.rawValue | GDK_SMOOTH_SCROLL_MASK.rawValue | GDK_KEY_PRESS_MASK.rawValue | GDK_KEY_RELEASE_MASK.rawValue
        gtk_widget_add_events(widget, Int32(bitPattern: mask))
        let me = Unmanaged.passUnretained(self).toOpaque()   // host is kept alive by its owner
        func host(_ d: UnsafeMutableRawPointer?) -> GtkCanvasHost { Unmanaged<GtkCanvasHost>.fromOpaque(d!).takeUnretainedValue() }
        typealias EvCB = @convention(c) (UnsafeMutablePointer<GtkWidget>?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> gboolean

        _ = mpvfx_connect(raw(widget), "draw", unsafeBitCast({ (w: UnsafeMutablePointer<GtkWidget>?, cr: OpaquePointer?, data: UnsafeMutableRawPointer?) -> gboolean in
            guard let w, let cr, let data else { return 0 }
            let h = Unmanaged<GtkCanvasHost>.fromOpaque(data).takeUnretainedValue()
            let size = CanvasSize(Double(gtk_widget_get_allocated_width(w)), Double(gtk_widget_get_allocated_height(w)))
            if size != h.lastSize { h.lastSize = size; h.input?.resized(size) }
            h.paint(CairoCanvas(cr: cr), size)
            return 1
        } as @convention(c) (UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, UnsafeMutableRawPointer?) -> gboolean, to: GCallback.self), me)

        _ = mpvfx_connect(raw(widget), "button-press-event", unsafeBitCast({ (w, e, d) -> gboolean in
            let ev = e!.assumingMemoryBound(to: GdkEventButton.self).pointee
            guard ev.type == GDK_BUTTON_PRESS else { return 0 }
            gtk_widget_grab_focus(w)
            if ev.button == 3 {
                Unmanaged<GtkCanvasHost>.fromOpaque(d!).takeUnretainedValue().input?.secondaryClick(x: ev.x, y: ev.y)
                return 1
            }
            // Left, middle (preview pan) and extra buttons, in DOM numbering.
            Unmanaged<GtkCanvasHost>.fromOpaque(d!).takeUnretainedValue().input?
                .pointerDown(x: ev.x, y: ev.y, button: PointerButton.fromGdk(ev.button), modifiers: GtkCanvasHost.modifiers(ev.state))
            return 1
        } as EvCB, to: GCallback.self), me)
        _ = mpvfx_connect(raw(widget), "button-release-event", unsafeBitCast({ (_, e, d) -> gboolean in
            let ev = e!.assumingMemoryBound(to: GdkEventButton.self).pointee
            guard ev.button != 3 else { return 0 }
            Unmanaged<GtkCanvasHost>.fromOpaque(d!).takeUnretainedValue().input?.pointerUp(x: ev.x, y: ev.y, button: PointerButton.fromGdk(ev.button))
            return 1
        } as EvCB, to: GCallback.self), me)
        _ = mpvfx_connect(raw(widget), "motion-notify-event", unsafeBitCast({ (_, e, d) -> gboolean in
            let ev = e!.assumingMemoryBound(to: GdkEventMotion.self).pointee
            let h = Unmanaged<GtkCanvasHost>.fromOpaque(d!).takeUnretainedValue()
            h.lastPoint = (ev.x, ev.y)
            h.input?.pointerMove(x: ev.x, y: ev.y, modifiers: GtkCanvasHost.modifiers(ev.state))
            return 1
        } as EvCB, to: GCallback.self), me)
        _ = mpvfx_connect(raw(widget), "scroll-event", unsafeBitCast({ (_, e, d) -> gboolean in
            let ev = e!.assumingMemoryBound(to: GdkEventScroll.self).pointee
            var dx = 0.0, dy = 0.0
            switch ev.direction {
            case GDK_SCROLL_UP: dy = -1; case GDK_SCROLL_DOWN: dy = 1; case GDK_SCROLL_LEFT: dx = -1; case GDK_SCROLL_RIGHT: dx = 1
            default: dx = ev.delta_x; dy = ev.delta_y
            }
            // A touchpad's smooth deltas are pixels / 10 (GDK divides the compositor's pixel axis by 10), so they map
            // back 1:1 and stay precise; a wheel notch (or a mouse's smooth ±1) is a line step, ~53px in Chromium.
            let source = ev.device.map { gdk_device_get_source($0) }
            let precise = ev.direction == GDK_SCROLL_SMOOTH && (source == GDK_SOURCE_TOUCHPAD || source == GDK_SOURCE_TOUCHSCREEN)
            let scale = precise ? 10.0 : 53.0
            Unmanaged<GtkCanvasHost>.fromOpaque(d!).takeUnretainedValue().input?.scroll(
                dx: dx * scale, dy: dy * scale, x: ev.x, ctrl: GtkCanvasHost.modifiers(ev.state).zoomsWheel,
                shift: ev.state & GDK_SHIFT_MASK.rawValue != 0, precise: precise)
            return 1
        } as EvCB, to: GCallback.self), me)
        _ = mpvfx_connect(raw(widget), "key-press-event", unsafeBitCast({ (_, e, d) -> gboolean in
            Unmanaged<GtkCanvasHost>.fromOpaque(d!).takeUnretainedValue().altChanged(e!.assumingMemoryBound(to: GdkEventKey.self).pointee, pressed: true)
            guard let k = GtkCanvasHost.key(e!.assumingMemoryBound(to: GdkEventKey.self).pointee, isRepeat: false) else { return 0 }
            return (Unmanaged<GtkCanvasHost>.fromOpaque(d!).takeUnretainedValue().input?.keyDown(k) ?? false) ? 1 : 0
        } as EvCB, to: GCallback.self), me)
        _ = mpvfx_connect(raw(widget), "key-release-event", unsafeBitCast({ (_, e, d) -> gboolean in
            Unmanaged<GtkCanvasHost>.fromOpaque(d!).takeUnretainedValue().altChanged(e!.assumingMemoryBound(to: GdkEventKey.self).pointee, pressed: false)
            guard let k = GtkCanvasHost.key(e!.assumingMemoryBound(to: GdkEventKey.self).pointee, isRepeat: false) else { return 0 }
            Unmanaged<GtkCanvasHost>.fromOpaque(d!).takeUnretainedValue().input?.keyUp(k); return 1
        } as EvCB, to: GCallback.self), me)
        // Files from the file manager (AssetsTab drop zone / timeline file drop).
        mpvfx_enable_uri_drop(widget)
        typealias MotionCB = @convention(c) (UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, Int32, Int32, UInt32, UnsafeMutableRawPointer?) -> gboolean
        _ = mpvfx_connect(raw(widget), "drag-motion", unsafeBitCast({ (_, _, x, y, _, d) -> gboolean in
            Unmanaged<GtkCanvasHost>.fromOpaque(d!).takeUnretainedValue().onFilesDragged?(CanvasPoint(Double(x), Double(y)))
            return 1
        } as MotionCB, to: GCallback.self), me)
        typealias LeaveCB = @convention(c) (UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, UInt32, UnsafeMutableRawPointer?) -> Void
        _ = mpvfx_connect(raw(widget), "drag-leave", unsafeBitCast({ (_, _, _, d) in
            Unmanaged<GtkCanvasHost>.fromOpaque(d!).takeUnretainedValue().onFilesDragged?(nil)
        } as LeaveCB, to: GCallback.self), me)
        typealias ReceivedCB = @convention(c) (UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, Int32, Int32, OpaquePointer?, UInt32, UInt32, UnsafeMutableRawPointer?) -> Void
        _ = mpvfx_connect(raw(widget), "drag-data-received", unsafeBitCast({ (_, _, x, y, sel, _, _, d) in
            let h = Unmanaged<GtkCanvasHost>.fromOpaque(d!).takeUnretainedValue()
            let paths = GtkCanvasHost.paths(fromUriList: sel)
            if !paths.isEmpty { h.onFilesDropped?(paths, CanvasPoint(Double(x), Double(y))) } else { h.onFilesDragged?(nil) }
        } as ReceivedCB, to: GCallback.self), me)
        _ = host
    }

    /// Local file paths from a text/uri-list selection (non-file URIs are skipped).
    static func paths(fromUriList sel: OpaquePointer?) -> [String] {
        guard let sel, let uris = gtk_selection_data_get_uris(sel) else { return [] }
        defer { g_strfreev(uris) }
        var out: [String] = []
        var i = 0
        while let uri = uris[i] {
            if let f = g_filename_from_uri(uri, nil, nil) { out.append(String(cString: f)); g_free(f) }
            i += 1
        }
        return out
    }

    static func key(_ ev: GdkEventKey, isRepeat: Bool) -> EditorKey? {
        let s = ev.state
        let code: EditorKey.Code
        switch Int32(ev.keyval) {
        case GDK_KEY_space: code = .space
        case GDK_KEY_Left: code = .left
        case GDK_KEY_Right: code = .right
        case GDK_KEY_Up: code = .up
        case GDK_KEY_Down: code = .down
        case GDK_KEY_Home: code = .home
        case GDK_KEY_End: code = .end
        case GDK_KEY_Delete: code = .delete
        case GDK_KEY_BackSpace: code = .backspace
        case GDK_KEY_Escape: code = .escape
        case GDK_KEY_Return: code = .enter
        case GDK_KEY_Tab, GDK_KEY_ISO_Left_Tab: code = .tab   // ⇧Tab arrives as ISO_Left_Tab
        default:
            let u = gdk_keyval_to_unicode(ev.keyval)
            guard u > 32, let scalar = Unicode.Scalar(u) else { return nil }
            code = .char(Character(scalar))
        }
        return EditorKey(code, shift: s & GDK_SHIFT_MASK.rawValue != 0, ctrl: s & GDK_CONTROL_MASK.rawValue != 0,
                         alt: s & GDK_MOD1_MASK.rawValue != 0, meta: s & GDK_META_MASK.rawValue != 0, isRepeat: isRepeat)
    }

    /// Last pointer position over the canvas (a modifier change re-sends it).
    var lastPoint: (x: Double, y: Double)?
    /// Alt pressed or released without moving: re-send the pointer with the new modifiers (the event's state is
    /// from before the key, so the Alt bit is set from the key itself), as MacCanvasHost does on flagsChanged.
    func altChanged(_ ev: GdkEventKey, pressed: Bool) {
        let k = Int32(ev.keyval)
        guard k == GDK_KEY_Alt_L || k == GDK_KEY_Alt_R, let p = lastPoint else { return }
        var m = Self.modifiers(ev.state)
        if pressed { m.insert(.alt) } else { m.remove(.alt) }
        input?.pointerMove(x: p.x, y: p.y, modifiers: m)
    }

    static func modifiers(_ s: guint) -> PointerModifiers {
        var m: PointerModifiers = []
        if s & GDK_SHIFT_MASK.rawValue != 0 { m.insert(.shift) }
        if s & GDK_MOD1_MASK.rawValue != 0 { m.insert(.alt) }
        if s & (GDK_META_MASK.rawValue | GDK_SUPER_MASK.rawValue) != 0 { m.insert(.meta) }
        if s & GDK_CONTROL_MASK.rawValue != 0 { m.insert(.ctrl) }
        return m
    }

    func setMinimumSize(width: Int32, height: Int32) { gtk_widget_set_size_request(widget, width, height) }
    func invalidate() { gtk_widget_queue_draw(widget) }
}
#endif
