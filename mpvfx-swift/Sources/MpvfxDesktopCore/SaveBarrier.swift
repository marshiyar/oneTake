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
// The save barrier (flush unsaved edits before a window closes or the app quits) as a host-independent state machine.
import Foundation

public enum SaveBarrierError: Error, Equatable, CustomStringConvertible {
    case failed(String)
    public var description: String { if case .failed(let m) = self { return m }; return "" }
    public static let notConfirmed = SaveBarrierError.failed("The editor did not confirm its saves")
    public static let closedEarly = SaveBarrierError.failed("The editor closed before confirming its saves")
    public static let timedOut = SaveBarrierError.failed("The editor is still saving or did not respond. The window has been kept open.")
}

public protocol SaveBarrierHost: AnyObject {
    var isLoadingMainFrame: Bool { get }
    func sendPrepareClose(_ id: String)
    func sendCancelClose(_ id: String)
    /// Returns a cancel function.
    func schedule(after seconds: Double, _ body: @escaping () -> Void) -> () -> Void
}

/// One barrier per window. All calls on the host's main thread.
public final class SaveBarrier {
    public static let timeoutSeconds: Double = 120
    public private(set) var pendingId: String?
    private var waiters: [(Result<Void, SaveBarrierError>) -> Void] = []
    private var cancelTimeout: (() -> Void)?
    private var waitingForLoad = false
    private unowned let host: SaveBarrierHost
    private let makeId: () -> String

    public init(host: SaveBarrierHost, makeId: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.host = host; self.makeId = makeId
    }

    /// flushRendererSaves: concurrent callers share one operation.
    public func flush(destroyed: Bool = false, _ completion: @escaping (Result<Void, SaveBarrierError>) -> Void) {
        if destroyed { completion(.success(())); return }
        waiters.append(completion)
        if pendingId != nil { return }
        let id = makeId()
        pendingId = id
        cancelTimeout = host.schedule(after: Self.timeoutSeconds) { [weak self] in self?.finish(.failure(.timedOut)) }
        if host.isLoadingMainFrame { waitingForLoad = true } else { host.sendPrepareClose(id) }
    }

    /// did-finish-load
    public func loadFinished() {
        guard waitingForLoad, let id = pendingId else { return }
        waitingForLoad = false
        host.sendPrepareClose(id)
    }

    /// mpvfx:close-prepared from the main frame. error: nil = JSON null, .some(string|other)
    public func closePrepared(id: JSONValue, error: JSONValue) {
        guard let pendingId, id.string == pendingId else { return }
        switch error {
        case .null: finish(.success(()))
        case .string(let s): finish(.failure(.failed(s)))
        default: finish(.failure(.notConfirmed))
        }
    }

    /// webContents "destroyed"
    public func pageDestroyed() { if pendingId != nil { finish(.failure(.closedEarly), pageGone: true) } }

    private func finish(_ result: Result<Void, SaveBarrierError>, pageGone: Bool = false) {
        guard let id = pendingId else { return }
        pendingId = nil; waitingForLoad = false
        cancelTimeout?(); cancelTimeout = nil
        if case .failure = result, !pageGone { host.sendCancelClose(id) }
        let w = waiters; waiters = []
        for c in w { c(result) }
    }
}
