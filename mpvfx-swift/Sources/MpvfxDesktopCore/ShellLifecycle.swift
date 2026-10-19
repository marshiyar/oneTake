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
// Native-shell window/app lifecycle as a host-independent state machine.
// Covers window "close", single instance and second instance,
// before-quit and the app's close sequence.
import Foundation

/// What the native toolkit must do in response to a lifecycle event.
public enum ShellAction: Equatable, Sendable {
    case createWindow
    case presentWindow          // restore if minimized + focus
    case closeWindow            // re-issue close now that it is approved
    case destroyWindowAndQuit   // before-quit after cleanup
    case showError(title: String, message: String)
    case none
}

/// The editor side of prepareClose/closePrepared/cancelClose. In the native app this is the
/// Swift editor (MpvfxEditor, not yet ported); it must answer `closePrepared` with the id.
public protocol EditorSaveChannel: AnyObject {
    var isLoading: Bool { get }
    func prepareClose(id: String)
    func cancelClose(id: String)
}

/// Adapts an EditorSaveChannel + a timer source to SaveBarrierHost.
public final class NativeSaveBarrierHost: SaveBarrierHost {
    public weak var editor: EditorSaveChannel?
    private let scheduler: (Double, @escaping () -> Void) -> () -> Void
    public init(editor: EditorSaveChannel?, scheduler: @escaping (Double, @escaping () -> Void) -> () -> Void) {
        self.editor = editor; self.scheduler = scheduler
    }
    public var isLoadingMainFrame: Bool { editor?.isLoading ?? false }
    public func sendPrepareClose(_ id: String) { editor?.prepareClose(id: id) }
    public func sendCancelClose(_ id: String) { editor?.cancelClose(id: id) }
    public func schedule(after seconds: Double, _ body: @escaping () -> Void) -> () -> Void { scheduler(seconds, body) }
}

/// One per process. All calls on the toolkit main thread. `perform` runs toolkit actions.
public final class ShellLifecycle {
    public static let saveErrorTitle = "MpVFX could not finish saving"
    public let barrier: SaveBarrier
    public private(set) var hasWindow = false
    public private(set) var closeApproved = false
    public private(set) var closeInProgress = false
    public private(set) var quitInProgress = false
    public private(set) var stopping = false
    /// True once the editor document is gone (window destroyed); flush then succeeds immediately.
    private var editorGone = true
    private let perform: (ShellAction) -> Void

    public init(barrier: SaveBarrier, perform: @escaping (ShellAction) -> Void) {
        self.barrier = barrier; self.perform = perform
    }

    /// First launch and every second launch (GApplication "activate" / a second instance).
    public func activate() {
        if hasWindow { perform(.presentWindow); return }
        if stopping || quitInProgress { return }   // already shutting down
        perform(.createWindow)
    }

    public func windowCreated() { hasWindow = true; editorGone = false; closeApproved = false; closeInProgress = false }

    /// Close request (delete-event / WM_CLOSE). Returns true to keep the window open for now.
    public func closeRequested() -> Bool {
        if closeApproved { return false }
        if closeInProgress || quitInProgress { return true }
        closeInProgress = true
        barrier.flush(destroyed: editorGone) { [self] result in
            switch result {
            case .success: closeApproved = true; perform(.closeWindow)
            case .failure(let e): closeInProgress = false; perform(.showError(title: Self.saveErrorTitle, message: e.description))
            }
        }
        return true
    }

    /// app.quit() (signals, File > Quit) -> before-quit.
    public func quitRequested() {
        if quitInProgress { return }
        quitInProgress = true
        barrier.flush(destroyed: editorGone) { [self] result in
            switch result {
            case .success: stopping = true; closeApproved = true; perform(.destroyWindowAndQuit)
            case .failure(let e): quitInProgress = false; perform(.showError(title: Self.saveErrorTitle, message: e.description))
            }
        }
    }

    /// The host's backend.close() failed in before-quit. The error box
    /// is shown, quitInProgress = false so a later quit retries, but close() has
    /// already detached the runtime and destroyed the window, so `stopping` stays true and
    /// activate() (relaunch / dock click) does nothing: the app lives on with no window.
    public func closeFailed() {
        quitInProgress = false; closeInProgress = false
    }

    /// Window "closed": the editor is gone; closing the last window quits on Linux/Windows.
    /// Returns true when the app should shut down.
    public func windowDestroyed() -> Bool {
        editorGone = true
        barrier.pageDestroyed()
        hasWindow = false
        stopping = true
        return true
    }
}
