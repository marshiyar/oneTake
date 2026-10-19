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

final class BarrierHost: SaveBarrierHost {
    var isLoadingMainFrame = false
    var prepared: [String] = [], cancelled: [String] = []
    var timers: [(Double, () -> Void, Bool)] = []
    func sendPrepareClose(_ id: String) { prepared.append(id) }
    func sendCancelClose(_ id: String) { cancelled.append(id) }
    func schedule(after seconds: Double, _ body: @escaping () -> Void) -> () -> Void {
        let i = timers.count; timers.append((seconds, body, false))
        return { [weak self] in self?.timers[i].2 = true }
    }
    func fire() { for t in timers where !t.2 { t.1() } }
}

func failure(_ r: Result<Void, SaveBarrierError>?) -> SaveBarrierError? {
    if case .failure(let e)? = r { return e }; return nil
}

final class SaveBarrierTests: XCTestCase {
    var n = 0
    func make(_ host: BarrierHost) -> SaveBarrier { SaveBarrier(host: host) { [unowned self] in n += 1; return "id\(n)" } }

    func testSuccessAndDedup() {
        let host = BarrierHost(), b = make(host)
        var results: [Result<Void, SaveBarrierError>] = []
        b.flush { results.append($0) }; b.flush { results.append($0) }
        XCTAssertEqual(host.prepared, ["id1"])
        XCTAssertEqual(host.timers.first?.0, 120)
        b.closePrepared(id: .string("other"), error: .null)
        XCTAssertTrue(results.isEmpty)
        b.closePrepared(id: .string("id1"), error: .null)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(host.cancelled.isEmpty)
        XCTAssertTrue(host.timers[0].2, "timeout cancelled")
        b.flush { _ in }; XCTAssertEqual(host.prepared, ["id1", "id2"])   // a new operation afterwards
    }

    func testRendererErrorsAndCancelClose() {
        let host = BarrierHost(), b = make(host)
        var r: Result<Void, SaveBarrierError>?
        b.flush { r = $0 }
        b.closePrepared(id: .string("id1"), error: .string("disk full"))
        XCTAssertEqual(r.map { if case .failure(let e) = $0 { return e.description }; return "ok" }, "disk full")
        XCTAssertEqual(host.cancelled, ["id1"])
        b.flush { r = $0 }
        b.closePrepared(id: .string("id2"), error: .number(3))
        XCTAssertEqual(failure(r), SaveBarrierError.notConfirmed)
    }

    func testTimeoutWaitsForLoadAndDestroyed() {
        let host = BarrierHost(); host.isLoadingMainFrame = true
        let b = make(host)
        var r: Result<Void, SaveBarrierError>?
        b.flush { r = $0 }
        XCTAssertTrue(host.prepared.isEmpty)
        b.loadFinished(); XCTAssertEqual(host.prepared, ["id1"])
        host.fire()
        XCTAssertEqual(failure(r), SaveBarrierError.timedOut)
        XCTAssertEqual(host.cancelled, ["id1"])
        b.flush { r = $0 }
        b.pageDestroyed()
        XCTAssertEqual(failure(r), SaveBarrierError.closedEarly)
        XCTAssertEqual(host.cancelled, ["id1"], "no cancel-close to a destroyed page")
        var ok = false; b.flush(destroyed: true) { if case .success = $0 { ok = true } }; XCTAssertTrue(ok)
    }
}
