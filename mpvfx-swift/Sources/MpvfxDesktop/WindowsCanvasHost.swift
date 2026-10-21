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
#if os(Windows)
import CMpvfxWin32
import Foundation
import MpvfxCanvas
import MpvfxTimeline
import WinSDK

/// The main window's client area as one Direct2D canvas (an ID2D1HwndRenderTarget) forwarding WM_PAINT to a
/// CanvasContext painter and Win32 input to a CanvasInput: the Windows counterpart of GtkCanvasHost and
/// MacCanvasHost, with no logic beyond translating messages. Drawing units and input coordinates are DIPs (device
/// pixels / (dpi / 96)), so painters draw in the same points on every monitor.
final class WindowsCanvasHost {
    let hwnd: HWND
    var paint: (CanvasContext, CanvasSize) -> Void
    weak var input: CanvasInput?
    /// Cursor for a point (resize seams); nil = arrow.
    var cursorAt: ((Double, Double) -> EditorShellRouter.Cursor)?
    /// Files from Explorer are about to land at this point (WM_DROPFILES reports only the drop, so this is sent
    /// right before `onFilesDropped`; there is no hover feedback while dragging).
    var onFilesDragged: ((CanvasPoint?) -> Void)?
    /// Files dropped from Explorer (local paths, canvas points).
    var onFilesDropped: (([String], CanvasPoint) -> Void)?
    /// A frame failed to draw (the canvas calls cannot throw); the shell reports it.
    var onDrawError: ((Error) -> Void)?
    private(set) var dpi: Double
    var lastSize = CanvasSize(0, 0)
    /// Last pointer position (a modifier change re-sends it, as on the other hosts).
    var lastPoint: (x: Double, y: Double)?
    private var target: OpaquePointer?
    private var buttonsDown = 0

    init(hwnd: HWND, paint: @escaping (CanvasContext, CanvasSize) -> Void) {
        self.hwnd = hwnd; self.paint = paint
        let windowDpi = GetDpiForWindow(hwnd)
        dpi = windowDpi == 0 ? 96 : Double(windowDpi)
        DragAcceptFiles(hwnd, true)
    }
    deinit { releaseTarget() }

    var scale: Double { dpi / 96 }

    /// Client area in device pixels.
    func clientPixels() -> MpvfxPixelSize {
        var r = RECT()
        GetClientRect(hwnd, &r)
        return MpvfxPixelSize(width: UInt32(max(0, r.right - r.left)), height: UInt32(max(0, r.bottom - r.top)))
    }
    /// Client area in DIPs.
    var size: CanvasSize {
        let px = clientPixels()
        return CanvasSize(Double(px.width) / scale, Double(px.height) / scale)
    }

    func invalidate() { InvalidateRect(hwnd, nil, false) }

    /// Handles a window message; nil when it is not the host's, for the window procedure to pass on.
    func handle(_ msg: UINT, _ wp: WPARAM, _ lp: LPARAM) -> LRESULT? {
        switch Int32(msg) {
        case WM_PAINT: paintFrame(); return 0
        case WM_ERASEBKGND: return 1   // the canvas paints every pixel
        case WM_SIZE: resizeTarget(); invalidate(); return 0
        case WM_DPICHANGED: dpiChanged(wp, lp); return 0
        case WM_SETCURSOR: return setCursor(lp)
        case WM_DROPFILES: dropFiles(wp); return 0
        case WM_MOUSEWHEEL, WM_MOUSEHWHEEL: wheel(msg, wp, lp); return 0
        case WM_KEYDOWN, WM_SYSKEYDOWN, WM_KEYUP, WM_SYSKEYUP: return key(msg, wp, lp)
        default: return pointer(msg, wp, lp)
        }
    }

    // MARK: Drawing

    private func ensureTarget() -> OpaquePointer? {
        if let target { return target }
        var t: OpaquePointer?
        var hr = mpvfx_d2d_init()
        if hr >= 0 { hr = mpvfx_d2d_target_create_hwnd(UnsafeMutableRawPointer(hwnd), clientPixels(), Float(dpi), &t) }
        guard hr >= 0, let t else { onDrawError?(Direct2DError("CreateHwndRenderTarget", hr)); return nil }
        target = t
        return t
    }

    private func releaseTarget() {
        if let target { mpvfx_d2d_target_release(target) }
        target = nil
    }

    private func paintFrame() {
        var ps = PAINTSTRUCT()
        BeginPaint(hwnd, &ps)
        defer { EndPaint(hwnd, &ps) }
        guard let t = ensureTarget() else { return }
        let size = self.size
        if size != lastSize { lastSize = size; input?.resized(size) }
        mpvfx_d2d_begin_draw(t)
        let canvas = Direct2DCanvas(target: t, dpiScale: scale)
        paint(canvas, size)
        let hr = mpvfx_d2d_end_draw(t)
        if hr == Int32(bitPattern: 0x8899_000C) {   // D2DERR_RECREATE_TARGET: the device was lost; draw again on a new one
            releaseTarget(); invalidate(); return
        }
        if let error = canvas.drawError ?? (hr < 0 ? Direct2DError("EndDraw", hr) : nil) { onDrawError?(error) }
    }

    private func resizeTarget() {
        guard let target else { return }
        let px = clientPixels()
        let hr = mpvfx_d2d_target_resize(target, px.width, px.height)
        if hr < 0 { releaseTarget() }   // made again at the new size on the next paint
    }

    /// WM_DPICHANGED: the new DPI in the low word; lParam is the suggested window rectangle at that DPI.
    private func dpiChanged(_ wp: WPARAM, _ lp: LPARAM) {
        dpi = Double(wp & 0xFFFF)
        if let target { mpvfx_d2d_target_set_dpi(target, Float(dpi)) }
        if let r = UnsafePointer<RECT>(bitPattern: Int(lp))?.pointee {
            SetWindowPos(hwnd, nil, r.left, r.top, r.right - r.left, r.bottom - r.top, UINT(SWP_NOZORDER | SWP_NOACTIVATE))
        }
        invalidate()
    }

    // MARK: Pointer

    /// Client pixel coordinates in lParam (signed 16-bit halves) as DIPs.
    private func point(_ lp: LPARAM) -> (x: Double, y: Double) {
        (Double(Int16(truncatingIfNeeded: lp)) / scale, Double(Int16(truncatingIfNeeded: lp >> 16)) / scale)
    }

    static func modifiers() -> PointerModifiers {
        var m: PointerModifiers = []
        if GetKeyState(Int32(VK_SHIFT)) < 0 { m.insert(.shift) }
        if GetKeyState(Int32(VK_MENU)) < 0 { m.insert(.alt) }
        if GetKeyState(Int32(VK_LWIN)) < 0 || GetKeyState(Int32(VK_RWIN)) < 0 { m.insert(.meta) }
        if GetKeyState(Int32(VK_CONTROL)) < 0 { m.insert(.ctrl) }
        return m
    }

    /// The DOM button of a button message (XBUTTON1 = back, XBUTTON2 = forward in the high word of wParam).
    private static func button(_ msg: UINT, _ wp: WPARAM) -> Int? {
        switch Int32(msg) {
        case WM_LBUTTONDOWN, WM_LBUTTONUP: return PointerButton.primary
        case WM_MBUTTONDOWN, WM_MBUTTONUP: return PointerButton.middle
        case WM_XBUTTONDOWN, WM_XBUTTONUP: return (wp >> 16) & 0xFFFF == 1 ? PointerButton.back : PointerButton.forward
        default: return nil
        }
    }

    private func pointer(_ msg: UINT, _ wp: WPARAM, _ lp: LPARAM) -> LRESULT? {
        let p = point(lp)
        switch Int32(msg) {
        case WM_MOUSEMOVE:
            lastPoint = p
            input?.pointerMove(x: p.x, y: p.y, modifiers: Self.modifiers())
            showCursor(at: p)   // the move may change the stage's cursor; WM_SETCURSOR came before it
            return 0
        case WM_RBUTTONDOWN:
            SetFocus(hwnd)
            input?.secondaryClick(x: p.x, y: p.y)
            return 0
        case WM_LBUTTONDOWN, WM_MBUTTONDOWN, WM_XBUTTONDOWN:
            SetFocus(hwnd)
            if buttonsDown == 0 { SetCapture(hwnd) }   // keep the drag when the pointer leaves the window
            buttonsDown += 1
            input?.pointerDown(x: p.x, y: p.y, button: Self.button(msg, wp)!, modifiers: Self.modifiers())
            return Int32(msg) == WM_XBUTTONDOWN ? 1 : 0
        case WM_LBUTTONUP, WM_MBUTTONUP, WM_XBUTTONUP:
            buttonsDown = max(0, buttonsDown - 1)
            if buttonsDown == 0 { ReleaseCapture() }
            input?.pointerUp(x: p.x, y: p.y, button: Self.button(msg, wp)!)
            return Int32(msg) == WM_XBUTTONUP ? 1 : 0
        case WM_CAPTURECHANGED:
            buttonsDown = 0
            return 0
        default:
            return nil
        }
    }

    /// One wheel notch (120) is a line step of ~53 DIPs, as in Chromium; a precision touchpad sends smaller deltas,
    /// which are passed through at the same scale and marked precise. Wheel messages carry screen coordinates.
    private func wheel(_ msg: UINT, _ wp: WPARAM, _ lp: LPARAM) {
        let delta = Double(Int16(truncatingIfNeeded: wp >> 16))
        var pt = POINT(x: LONG(Int16(truncatingIfNeeded: lp)), y: LONG(Int16(truncatingIfNeeded: lp >> 16)))
        ScreenToClient(hwnd, &pt)
        let precise = Int(delta) % 120 != 0
        let step = delta / 120 * 53
        let horizontal = Int32(msg) == WM_MOUSEHWHEEL
        let m = Self.modifiers()
        // Wheel up is a negative dy (content moves down), as GDK_SCROLL_UP; tilting right is a positive dx.
        input?.scroll(dx: horizontal ? step : 0, dy: horizontal ? 0 : -step, x: Double(pt.x) / scale,
                      ctrl: m.contains(.ctrl), shift: m.contains(.shift), precise: precise)
    }

    private func setCursor(_ lp: LPARAM) -> LRESULT? {
        guard lp & 0xFFFF == 1, let cursorAt else { return nil }   // HTCLIENT only; the frame keeps its cursors
        var pt = POINT()
        GetCursorPos(&pt)
        ScreenToClient(hwnd, &pt)
        let id = cursorAt(Double(pt.x) / scale, Double(pt.y) / scale).windowsCursorId
        SetCursor(LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: id)))
        return 1
    }

    /// Sets the cursor for a client point (logical px) straight after the input it follows.
    private func showCursor(at p: (x: Double, y: Double)) {
        guard let cursorAt else { return }
        SetCursor(LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: cursorAt(p.x, p.y).windowsCursorId)))
    }

    // MARK: Keys

    /// Virtual keys with their own EditorKey code.
    private static let namedKeys: [Int32: EditorKey.Code] = [
        Int32(VK_SPACE): .space, Int32(VK_LEFT): .left, Int32(VK_RIGHT): .right, Int32(VK_UP): .up, Int32(VK_DOWN): .down,
        Int32(VK_HOME): .home, Int32(VK_END): .end, Int32(VK_DELETE): .delete, Int32(VK_BACK): .backspace,
        Int32(VK_ESCAPE): .escape, Int32(VK_RETURN): .enter, Int32(VK_TAB): .tab,
    ]

    /// The character a key types with Shift (and Caps Lock) applied but not Ctrl or Alt, so Ctrl+Z reads as "z" as
    /// GTK's keyval does.
    private static func character(_ vk: Int32, _ lp: LPARAM) -> Character? {
        var state = [UInt8](repeating: 0, count: 256)
        guard GetKeyboardState(&state) else { return nil }
        for k in [VK_CONTROL, VK_LCONTROL, VK_RCONTROL, VK_MENU, VK_LMENU, VK_RMENU] { state[Int(k)] = 0 }
        var buffer = [WCHAR](repeating: 0, count: 8)
        // Flag 0x4: leave the keyboard's dead-key state alone (Windows 10 1607 on).
        let n = ToUnicode(UINT(vk), UINT((lp >> 16) & 0xFF), &state, &buffer, Int32(buffer.count), 0x4)
        guard n == 1, buffer[0] > 32, let scalar = Unicode.Scalar(UInt32(buffer[0])) else { return nil }
        return Character(scalar)
    }

    static func editorKey(_ vk: Int32, _ lp: LPARAM) -> EditorKey? {
        guard let code = namedKeys[vk] ?? character(vk, lp).map(EditorKey.Code.char) else { return nil }
        let m = modifiers()
        // Bit 30 of lParam: the key was already down (auto-repeat).
        return EditorKey(code, shift: m.contains(.shift), ctrl: m.contains(.ctrl), alt: m.contains(.alt),
                         meta: m.contains(.meta), isRepeat: (lp >> 30) & 1 == 1)
    }

    /// Unhandled keys go on to DefWindowProc, so Alt+F4 and the window menu keep working.
    private func key(_ msg: UINT, _ wp: WPARAM, _ lp: LPARAM) -> LRESULT? {
        let vk = Int32(truncatingIfNeeded: wp)
        let down = Int32(msg) == WM_KEYDOWN || Int32(msg) == WM_SYSKEYDOWN
        if vk == Int32(VK_MENU), let p = lastPoint {   // Alt alone: re-send the pointer with the new modifiers
            var m = Self.modifiers()
            if down { m.insert(.alt) } else { m.remove(.alt) }
            input?.pointerMove(x: p.x, y: p.y, modifiers: m)
            showCursor(at: p)
        }
        guard let k = Self.editorKey(vk, lp), let input else { return nil }
        if down { return input.keyDown(k) ? 0 : nil }
        input.keyUp(k)
        return 0
    }

    // MARK: Files from Explorer

    private func dropFiles(_ wp: WPARAM) {
        guard let drop = UnsafeMutableRawPointer(bitPattern: UInt(wp)) else { return }
        let hdrop = HDROP(OpaquePointer(drop))
        defer { DragFinish(hdrop) }
        var pt = POINT()
        DragQueryPoint(hdrop, &pt)
        final class Paths { var list: [String] = [] }
        let paths = Paths()
        let context = Unmanaged.passUnretained(paths).toOpaque()
        for i in 0..<mpvfx_dropped_file_count(drop) {
            _ = mpvfx_dropped_file(drop, i, { ctx, path in
                guard let ctx, let path else { return }
                Unmanaged<Paths>.fromOpaque(ctx).takeUnretainedValue().list.append(String(decodingCString: path, as: UTF16.self))
            }, context)
        }
        let at = CanvasPoint(Double(pt.x) / scale, Double(pt.y) / scale)
        guard !paths.list.isEmpty else { return }
        onFilesDragged?(at)
        onFilesDropped?(paths.list, at)
    }
}
#endif
