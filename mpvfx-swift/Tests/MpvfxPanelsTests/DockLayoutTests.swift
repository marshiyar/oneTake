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
@testable import MpvfxPanels

/// Checks every structural invariant `DockLayout.normalizeTree` and `repair` promise.
func assertDockInvariants(_ layout: DockLayout, _ registry: DockRegistry, file: StaticString = #filePath, line: UInt = #line) {
    let open = layout.openPanels
    XCTAssertEqual(open.count, Set(open).count, "a panel is open twice", file: file, line: line)
    for id in open { XCTAssertTrue(registry.contains(id), "unregistered \(id) open", file: file, line: line) }
    for id in layout.closed.keys { XCTAssertFalse(open.contains(id), "\(id) both open and closed", file: file, line: line) }
    for spec in registry.specs where !spec.closable { XCTAssertTrue(open.contains(spec.id), "\(spec.id) missing", file: file, line: line) }
    let ids = layout.groups.map(\.id)
    XCTAssertEqual(ids.count, Set(ids).count, "duplicate group ids \(ids)", file: file, line: line)
    checkNode(layout.root, parentAxis: nil, isRoot: true, file: file, line: line)
}

private func checkNode(_ node: DockNode, parentAxis: DockAxis?, isRoot: Bool, file: StaticString, line: UInt) {
    switch node {
    case .group(let g):
        if !isRoot || !g.panels.isEmpty {
            XCTAssertFalse(g.panels.isEmpty, "empty group \(g.id)", file: file, line: line)
            XCTAssertTrue(g.panels.contains(g.active), "group \(g.id) active \(g.active) not in \(g.panels)", file: file, line: line)
        }
    case .split(let s):
        XCTAssertGreaterThanOrEqual(s.children.count, 2, "split with one child", file: file, line: line)
        XCTAssertNotEqual(s.axis, parentAxis, "split inside a split of the same axis", file: file, line: line)
        XCTAssertEqual(s.weights.count, s.children.count, file: file, line: line)
        XCTAssertTrue(s.weights.allSatisfy { $0.isFinite && $0 > 0 }, "weights \(s.weights)", file: file, line: line)
        XCTAssertEqual(s.weights.reduce(0, +), 1, accuracy: 1e-9, file: file, line: line)
        for child in s.children { checkNode(child, parentAxis: s.axis, isRoot: false, file: file, line: line) }
    }
}

final class DockRegistryTests: XCTestCase {
    func testRegisterAPanelWithIdTitleDefaultDockAndMinimumSize() throws {
        var r = DockRegistry.editor
        try r.register(DockPanelSpec(id: "easing", title: "Easing", defaultDock: .right, minSize: CanvasSize(240, 160)))
        let spec = try XCTUnwrap(r.spec("easing"))
        XCTAssertEqual(spec.title, "Easing")
        XCTAssertEqual(spec.defaultDock, .right)
        XCTAssertEqual(spec.minSize, CanvasSize(240, 160))
        XCTAssertTrue(spec.closable)
        XCTAssertEqual(r.specs.map(\.id).last, "easing", "the Window menu lists panels in registration order")
    }

    func testInvalidRegistrationsAreTypedErrors() {
        var r = DockRegistry.editor
        func attempt(_ spec: DockPanelSpec) -> DockRegistryError? {
            do { try r.register(spec); return nil } catch let e as DockRegistryError { return e } catch { return nil }
        }
        let ok = CanvasSize(10, 10)
        XCTAssertEqual(attempt(DockPanelSpec(id: "media", title: "Again", defaultDock: .left, minSize: ok)), .duplicateID("media"))
        for bad in ["", "Media", "9lives", "a b", "a/b", String(repeating: "a", count: 33), "é"] {
            XCTAssertEqual(attempt(DockPanelSpec(id: bad, title: "T", defaultDock: .left, minSize: ok)), .invalidID(bad), bad)
        }
        XCTAssertEqual(attempt(DockPanelSpec(id: "x", title: "   ", defaultDock: .left, minSize: ok)), .invalidTitle("x"))
        XCTAssertEqual(attempt(DockPanelSpec(id: "x", title: String(repeating: "T", count: 41), defaultDock: .left, minSize: ok)), .invalidTitle("x"))
        for size in [CanvasSize(.nan, 1), CanvasSize(-1, 1), CanvasSize(1, .infinity), CanvasSize(5000, 1)] {
            XCTAssertEqual(attempt(DockPanelSpec(id: "x", title: "T", defaultDock: .left, minSize: size)), .invalidSize("x"))
        }
        XCTAssertEqual(r, DockRegistry.editor, "a refused registration adds nothing")
    }

    func testPreviewAndTimelineAreNotClosable() {
        let r = DockRegistry.editor
        XCTAssertFalse(r.isClosable(DockPanels.preview))
        XCTAssertFalse(r.isClosable(DockPanels.timeline))
        for id in [DockPanels.media, DockPanels.inspector, DockPanels.renders] { XCTAssertTrue(r.isClosable(id), id) }
    }
}

final class DockLayoutTests: XCTestCase {
    let registry = DockRegistry.editor
    var layout: DockLayout { DockDefaults.layout(registry) }

    func group(_ l: DockLayout, _ panel: DockPanelID) throws -> DockGroup { try XCTUnwrap(l.root.group(containing: panel), panel) }

    // MARK: Default

    func testDefaultLayoutPutsMediaLeftPreviewCentreDesignAndRendersRightTimelineBottom() throws {
        let l = layout
        guard case .split(let column) = l.root else { return XCTFail("root is not a split") }
        XCTAssertEqual(column.axis, .column)
        guard case .split(let row) = column.children[0] else { return XCTFail("top is not a row") }
        XCTAssertEqual(row.axis, .row)
        XCTAssertEqual(row.children.map(\.panels), [["media"], ["preview"], ["inspector", "renders"]])
        XCTAssertEqual(column.children[1].panels, ["timeline"])
        XCTAssertEqual(try group(l, "inspector").active, "inspector")
        XCTAssertEqual(row.weights[0], 370 / 1440, accuracy: 1e-9)
        XCTAssertEqual(column.weights[1], (360 + PanelTabStrip.height) / (900 - ShellStatusLine.height - PanelTheme.seamWidth), accuracy: 1e-9,
                       "the timeline's 360 pt content plus its tab strip")
        assertDockInvariants(l, registry)
    }

    func testARegisteredPanelJoinsItsDefaultZoneInTheDefaultLayout() throws {
        var r = registry
        try r.register(DockPanelSpec(id: "easing", title: "Easing", defaultDock: .right, minSize: CanvasSize(240, 160)))
        let l = DockDefaults.layout(r)
        XCTAssertEqual(try group(l, "easing").panels, ["inspector", "renders", "easing"])
        assertDockInvariants(l, r)
    }

    func testSeedsFromTheOldPanelSizesSetTheDefaultShares() throws {
        let l = DockDefaults.layout(registry, seeds: DockSeeds(leftWidth: 288, rightWidth: 432, bottomHeight: 406.5))   // + the 32 pt strip = half of 877
        guard case .split(let column) = l.root, case .split(let row) = column.children[0] else { return XCTFail("shape") }
        XCTAssertEqual(row.weights[0], 288 / 1440, accuracy: 1e-9)
        XCTAssertEqual(row.weights[2], 432 / 1440, accuracy: 1e-9)
        XCTAssertEqual(column.weights[1], 0.5, accuracy: 1e-9)
    }

    // MARK: Drag: stack, reorder, split, window edge

    func testDropOnATabBarStacksThePanelAtThatIndexAndActivatesIt() throws {
        var l = layout
        let right = try group(l, "inspector")
        try l.move("media", to: .stack(group: right.id, index: 1))
        XCTAssertEqual(try group(l, "media").panels, ["inspector", "media", "renders"])
        XCTAssertEqual(try group(l, "media").active, "media")
        XCTAssertEqual(l.groups.count, 3, "the emptied left group is gone")
        assertDockInvariants(l, registry)
    }

    func testReorderTabsWithinAGroup() throws {
        var l = layout
        let g = try group(l, "inspector")
        try l.move("inspector", to: .stack(group: g.id, index: 2))   // the gap after "renders"
        XCTAssertEqual(try group(l, "inspector").panels, ["renders", "inspector"])
        try l.move("inspector", to: .stack(group: g.id, index: 0))
        XCTAssertEqual(try group(l, "inspector").panels, ["inspector", "renders"])
        try l.move("media", to: .stack(group: g.id, index: nil))
        try l.move("inspector", to: .stack(group: g.id, index: 2))   // the gap between "renders" and "media"
        XCTAssertEqual(try group(l, "inspector").panels, ["renders", "inspector", "media"])
        assertDockInvariants(l, registry)
    }

    func testDropOnAGroupEdgeSplitsThatGroup() throws {
        var l = layout
        let centre = try group(l, "preview")
        try l.move("renders", to: .split(group: centre.id, edge: .bottom))
        let path = try XCTUnwrap(l.root.path(toGroup: try group(l, "renders").id))
        guard case .split(let s)? = l.root.node(at: Array(path.dropLast())) else { return XCTFail("no parent split") }
        XCTAssertEqual(s.axis, .column)
        XCTAssertEqual(s.children.map(\.panels), [["preview"], ["renders"]])
        XCTAssertEqual(s.weights, [0.5, 0.5])
        XCTAssertEqual(try group(l, "inspector").panels, ["inspector"])
        assertDockInvariants(l, registry)
    }

    func testDropOnTheGroupsOwnEdgeSplitsItsOtherTabsOff() throws {
        var l = layout
        let right = try group(l, "inspector")
        try l.move("renders", to: .split(group: right.id, edge: .right))
        XCTAssertEqual(try group(l, "renders").panels, ["renders"])
        XCTAssertNotEqual(try group(l, "renders").id, try group(l, "inspector").id)
        assertDockInvariants(l, registry)
    }

    func testDropOnAWindowEdgeSpansTheWholeWindow() throws {
        var l = layout
        try l.move("media", to: .window(.bottom), fraction: 0.2)
        guard case .split(let column) = l.root else { return XCTFail("root") }
        XCTAssertEqual(column.axis, .column)
        XCTAssertEqual(column.children.last?.panels, ["media"])
        XCTAssertEqual(column.weights.last ?? 0, 0.2, accuracy: 1e-9)
        try l.move("renders", to: .window(.left))
        guard case .split(let row) = l.root else { return XCTFail("root") }
        XCTAssertEqual(row.axis, .row)
        XCTAssertEqual(row.children.first?.panels, ["renders"])
        assertDockInvariants(l, registry)
    }

    func testALoneTabDroppedOnItsOwnBarOrSplitOffItselfChangesNothing() throws {
        var l = layout
        let before = l
        let left = try group(l, "media")
        try l.move("media", to: .stack(group: left.id, index: 0))
        XCTAssertEqual(l, before)
        XCTAssertThrowsError(try l.move("media", to: .split(group: left.id, edge: .left))) { XCTAssertEqual($0 as? DockOpError, .invalidTarget) }
        XCTAssertEqual(l, before)
    }

    // MARK: Swap

    func testSwapExchangesTwoPanelsBetweenGroups() throws {
        var l = layout
        try l.swap("media", "renders")
        XCTAssertEqual(try group(l, "media").panels, ["inspector", "media"])
        XCTAssertEqual(try group(l, "renders").panels, ["renders"])
        XCTAssertEqual(try group(l, "renders").active, "renders")
        assertDockInvariants(l, registry)
    }

    func testSwapWithinAGroupExchangesTabOrderAndKeepsTheActiveTab() throws {
        var l = layout
        try l.swap("inspector", "renders")
        XCTAssertEqual(try group(l, "inspector").panels, ["renders", "inspector"])
        XCTAssertEqual(try group(l, "inspector").active, "inspector")
    }

    // MARK: Close and open

    func testCloseRemovesThePanelAndOpenRestoresItToItsTabSlot() throws {
        var l = layout
        try l.close("inspector", registry: registry)
        XCTAssertFalse(l.isOpen("inspector"))
        XCTAssertEqual(try group(l, "renders").panels, ["renders"])
        try l.open("inspector", registry: registry)
        XCTAssertEqual(try group(l, "inspector").panels, ["inspector", "renders"])
        XCTAssertEqual(try group(l, "inspector").active, "inspector")
        XCTAssertNil(l.closed["inspector"])
        assertDockInvariants(l, registry)
    }

    func testAPanelAloneInItsGroupReopensOnTheSameSideOfItsNeighbour() throws {
        var l = layout
        let centre = try group(l, "preview")
        try l.move("renders", to: .split(group: centre.id, edge: .bottom), fraction: 0.3)
        try l.close("renders", registry: registry)
        XCTAssertEqual(l.closed["renders"]?.edge, .bottom)
        XCTAssertEqual(l.closed["renders"]?.neighbour, ["preview"])
        try l.open("renders", registry: registry)
        let path = try XCTUnwrap(l.root.path(toGroup: try group(l, "renders").id))
        guard case .split(let s)? = l.root.node(at: Array(path.dropLast())) else { return XCTFail("no parent split") }
        XCTAssertEqual(s.children.map(\.panels), [["preview"], ["renders"]])
        XCTAssertEqual(s.weights[1], 0.3, accuracy: 1e-9)
    }

    func testAPanelWhoseNeighboursAreGoneReopensAtItsDefaultZone() throws {
        var l = layout
        let right = try group(l, "inspector")
        try l.move("media", to: .split(group: right.id, edge: .bottom))
        try l.close("media", registry: registry)
        XCTAssertEqual(l.closed["media"]?.neighbour, ["inspector", "renders"])
        try l.close("inspector", registry: registry)
        try l.close("renders", registry: registry)
        try l.open("media", registry: registry)
        guard case .split(let column) = l.root, case .split(let row) = column.children[0] else { return XCTFail("shape") }
        XCTAssertEqual(row.children.first?.panels, ["media"], "its zone is the left, beside the preview")
        var r = registry
        try r.register(DockPanelSpec(id: "scopes", title: "Scopes", defaultDock: .right, minSize: CanvasSize(200, 150)))
        try l.open("scopes", registry: r)
        XCTAssertEqual(try group(l, "scopes").panels, ["scopes"], "no right group: it opens right of the preview")
        l.closed["inspector"] = nil
        try l.open("inspector", registry: r)
        XCTAssertEqual(try group(l, "inspector").panels, ["scopes", "inspector"], "a panel without a place joins its zone's group")
        assertDockInvariants(l, r)
    }

    func testAZoneWithoutAGroupOpensBesideThePreview() throws {
        var l = layout
        try l.close("inspector", registry: registry)
        try l.close("renders", registry: registry)
        l.closed = [:]   // forget both places
        try l.open("renders", registry: registry)
        guard case .split(let column) = l.root, case .split(let row) = column.children[0] else { return XCTFail("shape") }
        XCTAssertEqual(row.children.last?.panels, ["renders"])
    }

    func testPreviewAndTimelineCannotBeClosed() {
        var l = layout
        let before = l
        for id in [DockPanels.preview, DockPanels.timeline] {
            XCTAssertThrowsError(try l.close(id, registry: registry)) { XCTAssertEqual($0 as? DockOpError, .notClosable(id)) }
        }
        XCTAssertEqual(l, before)
    }

    func testOpeningAnOpenPanelActivatesIt() throws {
        var l = layout
        try l.open("renders", registry: registry)
        XCTAssertEqual(try group(l, "renders").active, "renders")
        XCTAssertEqual(l.openPanels.filter { $0 == "renders" }.count, 1)
    }

    func testFailedOperationsThrowTypedErrorsAndChangeNothing() {
        var l = layout
        let before = l
        XCTAssertThrowsError(try l.open("nope", registry: registry)) { XCTAssertEqual($0 as? DockOpError, .unknownPanel("nope")) }
        XCTAssertThrowsError(try l.move("media", to: .stack(group: "g99", index: 0))) { XCTAssertEqual($0 as? DockOpError, .unknownGroup("g99")) }
        XCTAssertThrowsError(try l.move("nope", to: .window(.left))) { XCTAssertEqual($0 as? DockOpError, .notOpen("nope")) }
        XCTAssertThrowsError(try l.swap("media", "nope")) { XCTAssertEqual($0 as? DockOpError, .notOpen("nope")) }
        XCTAssertThrowsError(try l.setWeights(at: [0], [1, .nan, 1])) { XCTAssertEqual($0 as? DockOpError, .invalidWeights) }
        XCTAssertThrowsError(try l.setWeights(at: [7], [1, 1])) { XCTAssertEqual($0 as? DockOpError, .invalidTarget) }
        XCTAssertEqual(l, before)
    }

    func testSetWeightsNormalizesTheShares() throws {
        var l = layout
        try l.setWeights(at: [0], [1, 2, 1])
        guard case .split(let row)? = l.root.node(at: [0]) else { return XCTFail("row") }
        XCTAssertEqual(row.weights, [0.25, 0.5, 0.25])
    }

    func testSharesKeepAOnePercentFloorAndHugeValuesDoNotOverflow() {
        let tiny = DockLayout.fixedWeights([1e-9, 1, 1], count: 3)
        XCTAssertEqual(tiny[0], DockLayout.minShare, accuracy: 1e-12)
        XCTAssertEqual(tiny.reduce(0, +), 1, accuracy: 1e-12)
        XCTAssertEqual(DockLayout.fixedWeights([1e308, 1e308], count: 2), [0.5, 0.5])
        let many = DockLayout.fixedWeights([1e-6] + Array(repeating: 1, count: 199), count: 200)
        XCTAssertEqual(many[0], 1.0 / 200, accuracy: 1e-12, "more than 100 children: the floor is 1 / count")
        XCTAssertEqual(DockLayout.fixedWeights([.nan, -1, 2], count: 4), [0.25, 0.25, 0.25, 0.25])
    }

    // MARK: Invariants

    /// Thousands of arbitrary moves, swaps, closes and opens (a fixed SplitMix64 sequence): the invariants hold after each, and the required panels
    /// stay open.
    func testInvariantsHoldAfterArbitraryOperationSequences() throws {
        var r = registry
        try r.register(DockPanelSpec(id: "easing", title: "Easing", defaultDock: .right, minSize: CanvasSize(240, 160)))
        try r.register(DockPanelSpec(id: "scopes", title: "Scopes", defaultDock: .bottom, minSize: CanvasSize(200, 150)))
        var seq = SplitMix64(seed: 0xD0C)
        var l = DockDefaults.layout(r)
        let ids = r.specs.map(\.id)
        for _ in 0..<3000 {
            arbitraryOperation(&l, r, ids, &seq)
            assertDockInvariants(l, r)
            XCTAssertLessThanOrEqual(l.root.depth, ids.count + 1)
        }
    }

    private func arbitraryOperation(_ l: inout DockLayout, _ r: DockRegistry, _ ids: [DockPanelID], _ seq: inout SplitMix64) {
        let a = seq.pick(ids) ?? "media", b = seq.pick(ids) ?? "preview"
        let group = seq.pick(l.groups)?.id ?? "g1"
        let edge = seq.pick(DockEdge.allCases) ?? .left
        do {
            switch seq.below(7) {
            case 0: try l.move(a, to: .stack(group: group, index: seq.below(6) - 1))
            case 1: try l.move(a, to: .split(group: group, edge: edge), fraction: seq.unit() * 3 - 1)
            case 2: try l.move(a, to: .window(edge))
            case 3: try l.swap(a, b)
            case 4: try l.close(a, registry: r)
            case 5: try l.open(a, registry: r)
            default: l.activate(a)
            }
        } catch is DockOpError {
            return
        } catch {
            XCTFail("untyped error \(error)")
        }
    }
}

/// SplitMix64: a fixed, repeatable sequence of numbers, so the fuzz runs see the same cases on every run and machine.
/// Test inputs only; nothing secret depends on it.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// 0 ..< n (0 when n ≤ 0).
    mutating func below(_ n: Int) -> Int { n > 0 ? Int(next() % UInt64(n)) : 0 }
    /// 0 ..< 1.
    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
    mutating func pick<T>(_ items: [T]) -> T? { items.isEmpty ? nil : items[below(items.count)] }
}
