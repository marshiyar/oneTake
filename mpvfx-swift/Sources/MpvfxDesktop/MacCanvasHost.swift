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
#if os(macOS)
import AppKit
import MpvfxCanvas
import MpvfxTimeline

/// Flipped NSView forwarding draw(_:) to a CanvasContext painter and AppKit events to a CanvasInput.
/// The macOS counterpart of GtkCanvasHost: no logic beyond translating events. Coordinates are view points,
/// origin top-left, y down; AppKit applies the backing scale (Retina) to the context, so painters draw in points.
final class MacCanvasHost: NSView {
    var paint: (CanvasContext, CanvasSize) -> Void
    weak var input: CanvasInput?
    /// Cursor for a point (resize seams); nil = arrow.
    var cursorAt: ((Double, Double) -> NSCursor?)?
    var lastSize = CanvasSize(0, 0)
    var accessibilityControls: (() -> [CanvasAccessibilityControl])?
    /// A file drag from Finder moved over the canvas (nil: it left).
    var onFilesDragged: ((CanvasPoint?) -> Void)?
    /// Files dropped from Finder (local paths, view points).
    var onFilesDropped: (([String], CanvasPoint) -> Void)?

    init(paint: @escaping (CanvasContext, CanvasSize) -> Void) {
        self.paint = paint
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        registerForDraggedTypes([.fileURL])   // AssetsTab drop zone / timeline file drop
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityChildren() -> [Any]? {
        accessibilityControls?().map { control in
            let local = NSRect(x: control.frame.x, y: control.frame.y, width: control.frame.width, height: control.frame.height)
            let screen = window?.convertToScreen(convert(local, to: nil)) ?? local
            return MacCanvasAccessibilitySwitch(parent: self, label: control.label, value: control.value,
                                                frame: screen, press: control.press)
        }
    }

    func invalidate() { refreshCursor(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let size = CanvasSize(Double(bounds.width), Double(bounds.height))
        if size != lastSize { lastSize = size; input?.resized(size) }
        paint(CoreGraphicsCanvas(context: cg), size)
        refreshCursor()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    // Hover (pointer moves without a button) needs a tracking area.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    private func point(_ e: NSEvent) -> (x: Double, y: Double) {
        let p = convert(e.locationInWindow, from: nil)   // flipped view: y grows downward
        return (Double(p.x), Double(p.y))
    }

    // MARK: Files from Finder

    private func fileURLs(_ info: NSDraggingInfo) -> [String] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.map(\.path)
    }
    private func dragPoint(_ info: NSDraggingInfo) -> CanvasPoint {
        let p = convert(info.draggingLocation, from: nil)   // flipped view: y grows downward
        return CanvasPoint(Double(p.x), Double(p.y))
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender).isEmpty else { return [] }
        onFilesDragged?(dragPoint(sender))
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { onFilesDragged?(nil) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = fileURLs(sender)
        guard !paths.isEmpty else { onFilesDragged?(nil); return false }
        onFilesDropped?(paths, dragPoint(sender))
        return true
    }

    // MARK: Pointer
    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = point(e); lastPoint = p
        defer { refreshCursor() }
        // Control-click is the macOS secondary click.
        if e.modifierFlags.contains(.control) { input?.secondaryClick(x: p.x, y: p.y); return }
        input?.pointerDown(x: p.x, y: p.y, button: PointerButton.primary, modifiers: Self.modifiers(e))
    }
    override func mouseDragged(with e: NSEvent) { move(e) }
    override func mouseMoved(with e: NSEvent) { move(e) }
    private func move(_ e: NSEvent) {
        let p = point(e); lastPoint = p
        input?.pointerMove(x: p.x, y: p.y, modifiers: Self.modifiers(e)); updateCursor(p)
    }
    private var lastPoint: (x: Double, y: Double)?
    /// A modifier pressed or released without moving re-sends the pointer with the new modifiers (gesture
    /// recording switches between move, opacity and rotation on the modifier alone, like the original's keydown).
    override func flagsChanged(with e: NSEvent) {
        super.flagsChanged(with: e)
        if let p = lastPoint { input?.pointerMove(x: p.x, y: p.y, modifiers: Self.modifiers(e)); refreshCursor() }
    }
    // Middle and extra buttons (DOM numbering): the preview pans on a middle-button drag.
    override func otherMouseDown(with e: NSEvent) {
        let p = point(e); lastPoint = p
        input?.pointerDown(x: p.x, y: p.y, button: PointerButton.fromAppKit(e.buttonNumber), modifiers: Self.modifiers(e))
        updateCursor(p)
    }
    override func otherMouseDragged(with e: NSEvent) { move(e) }
    override func otherMouseUp(with e: NSEvent) {
        let p = point(e); lastPoint = p
        input?.pointerUp(x: p.x, y: p.y, button: PointerButton.fromAppKit(e.buttonNumber)); refreshCursor()
    }
    static func modifiers(_ e: NSEvent) -> PointerModifiers {
        let f = e.modifierFlags
        var m: PointerModifiers = []
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.option) { m.insert(.alt) }
        if f.contains(.command) { m.insert(.meta) }
        if f.contains(.control) { m.insert(.ctrl) }
        return m
    }
    private func updateCursor(_ p: (x: Double, y: Double)) { (cursorAt?(p.x, p.y) ?? .arrow).set() }
    /// Redraws and modal changes need a refresh too. Do not set a global AppKit cursor when this view is
    /// behind another app/window or the pointer has left its bounds.
    private func refreshCursor() {
        guard let window, window.isKeyWindow,
              NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber else { return }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(p) else { return }
        updateCursor((Double(p.x), Double(p.y)))
    }
    override func mouseUp(with e: NSEvent) {
        guard !e.modifierFlags.contains(.control) else { return }
        let p = point(e); lastPoint = p
        input?.pointerUp(x: p.x, y: p.y, button: PointerButton.primary); refreshCursor()
    }
    override func rightMouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = point(e); lastPoint = p
        input?.secondaryClick(x: p.x, y: p.y); updateCursor(p)
    }

    override func scrollWheel(with e: NSEvent) {
        let p = point(e)
        // Wheel deltas in web pixels (positive dy = toward the end), like the GTK host: trackpads report
        // precise pixel deltas; a mouse wheel reports lines, one notch ~= 53px as in Chromium.
        // Precise deltas pass through 1:1, momentum phase included (AppKit keeps sending them while the scroll coasts).
        let precise = e.hasPreciseScrollingDeltas
        let scale = precise ? 1.0 : 53.0
        let dx = -Double(e.scrollingDeltaX) * scale, dy = -Double(e.scrollingDeltaY) * scale
        guard dx != 0 || dy != 0 else { return }
        input?.scroll(dx: dx, dy: dy, x: p.x, ctrl: Self.modifiers(e).zoomsWheel, shift: e.modifierFlags.contains(.shift), precise: precise)
    }

    /// Trackpad pinch arrives in Chromium as a ctrl+wheel; do the same so the timeline zooms.
    override func magnify(with e: NSEvent) {
        let p = point(e)
        let dy = -Double(e.magnification) * 100
        guard dy != 0 else { return }
        input?.scroll(dx: 0, dy: dy, x: p.x, ctrl: true, shift: false)
    }

    // MARK: Keys
    /// ⌘-shortcuts reach the focused editor view before the menu bar (the editor gets keys first and the menu
    /// runs an accelerator only when the editor did not handle it), so ⌘Z/⌘C/⌘V/⌘= etc. drive the editor.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        defer { refreshCursor() }
        guard e.type == .keyDown, e.modifierFlags.contains(.command), window?.firstResponder === self,
              let k = MacCanvasHost.key(e), input?.keyDown(k) == true else { return super.performKeyEquivalent(with: e) }
        return true
    }
    override func keyDown(with e: NSEvent) {
        defer { refreshCursor() }
        guard let k = MacCanvasHost.key(e), input?.keyDown(k) == true else { super.keyDown(with: e); return }
    }
    override func keyUp(with e: NSEvent) {
        defer { refreshCursor() }
        guard let k = MacCanvasHost.key(e) else { super.keyUp(with: e); return }
        input?.keyUp(k)
    }

    /// F1…F12 as AppKit reports them in `charactersIgnoringModifiers`.
    static let functionKeys = [NSF1FunctionKey, NSF2FunctionKey, NSF3FunctionKey, NSF4FunctionKey, NSF5FunctionKey, NSF6FunctionKey,
                               NSF7FunctionKey, NSF8FunctionKey, NSF9FunctionKey, NSF10FunctionKey, NSF11FunctionKey, NSF12FunctionKey]

    static func key(_ e: NSEvent) -> EditorKey? {
        let code: EditorKey.Code
        switch e.keyCode {
        case 49: code = .space
        case 123: code = .left
        case 124: code = .right
        case 126: code = .up
        case 125: code = .down
        case 115: code = .home
        case 119: code = .end
        case 117: code = .delete        // forward delete
        case 51: code = .backspace      // the key labelled "delete"
        case 53: code = .escape
        case 36, 76: code = .enter      // return, keypad enter
        case 48: code = .tab
        default:
            // Shift is kept (like a GDK keyval), other modifiers are not; function keys are private-use scalars:
            // F1…F12 become EditorKey.Code.function, the others are dropped.
            guard let scalar = e.charactersIgnoringModifiers?.unicodeScalars.first, scalar.value > 32 else { return nil }
            if let n = Self.functionKeys.firstIndex(of: Int(scalar.value)) { code = .function(n + 1); break }
            guard !(0xF700...0xF8FF).contains(scalar.value) else { return nil }
            code = .char(Character(scalar))
        }
        let f = e.modifierFlags
        return EditorKey(code, shift: f.contains(.shift), ctrl: f.contains(.control), alt: f.contains(.option),
                         meta: f.contains(.command), isRepeat: e.type == .keyDown && e.isARepeat)
    }
}

private final class MacCanvasAccessibilitySwitch: NSAccessibilityElement {
    private let action: () -> Void
    init(parent: Any, label: String, value: Bool, frame: NSRect, press: @escaping () -> Void) {
        action = press
        super.init()
        // NSAccessibilityElement's role/frame/label/parent constructor is a class method, not an init.
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(label)
        setAccessibilityParent(parent)
        setAccessibilityFrameInParentSpace(frame)
        setAccessibilityValue(value)
    }
    override func accessibilityPerformPress() -> Bool { action(); return true }
}
#endif
