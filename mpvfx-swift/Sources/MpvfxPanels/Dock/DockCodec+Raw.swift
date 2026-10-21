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
import Foundation

// The file's JSON shape. Every field is optional and every value `Lenient`, so a wrong value (a number where a panel
// id belongs, a string among the weights) is dropped or repaired with a note instead of failing the whole file;
// only the version and the tree's shape (a node is a group or a split) are structural.

struct RawVersion: Decodable { var version: Int? }

struct RawFile: Codable {
    var version: Int
    var current: Lenient<String>?
    var workspaces: [String: RawLayout]?
}

struct RawLayout: Codable {
    var root: RawNode?
    var closed: [String: RawPlace]?

    init(_ layout: DockLayout) {
        root = RawNode(layout.root)
        closed = layout.closed.mapValues(RawPlace.init)
    }
}

indirect enum RawNode: Codable {
    case group(RawGroup)
    case split(RawSplit)

    enum CodingKeys: String, CodingKey { case group, split }

    init(_ node: DockNode) {
        switch node {
        case .group(let g): self = .group(RawGroup(g))
        case .split(let s): self = .split(RawSplit(s))
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let g = try c.decodeIfPresent(RawGroup.self, forKey: .group) { self = .group(g); return }
        if let s = try c.decodeIfPresent(RawSplit.self, forKey: .split) { self = .split(s); return }
        throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "a node is neither a group nor a split"))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .group(let g): try c.encode(g, forKey: .group)
        case .split(let s): try c.encode(s, forKey: .split)
        }
    }

    /// (tree depth, node count); recursion is bounded by `DockCodec.maxJSONDepth`, checked before parsing.
    var measure: (depth: Int, count: Int) {
        guard case .split(let s) = self else { return (1, 1) }
        let kids = (s.children ?? []).map(\.measure)
        return (1 + (kids.map(\.depth).max() ?? 0), 1 + kids.map(\.count).reduce(0, +))
    }
}

struct RawGroup: Codable {
    var id: Lenient<String>?
    var panels: [Lenient<String>]?
    var active: Lenient<String>?

    init(_ g: DockGroup) { id = Lenient(g.id); panels = g.panels.map(Lenient.init); active = Lenient(g.active) }
}

struct RawSplit: Codable {
    var axis: Lenient<String>?
    var children: [RawNode]?
    var weights: [Lenient<Double>]?

    init(_ s: DockSplit) { axis = Lenient(s.axis.rawValue); children = s.children.map(RawNode.init); weights = s.weights.map(Lenient.init) }
}

struct RawPlace: Codable {
    var mates: [Lenient<String>]?
    var index: Lenient<Int>?
    var neighbour: [Lenient<String>]?
    var edge: Lenient<String>?
    var fraction: Lenient<Double>?

    init(_ p: DockPlace) {
        mates = p.mates.map(Lenient.init); index = Lenient(p.index); neighbour = p.neighbour.map(Lenient.init)
        edge = p.edge.map { Lenient($0.rawValue) }; fraction = p.fraction.map(Lenient.init)
    }
}

/// One value of the file that may hold the wrong type: it reads as nil (and is dropped or defaulted with a note)
/// instead of refusing the whole file. Other decoding errors (bytes that are not JSON) still refuse it.
struct Lenient<Value: Codable & Sendable>: Codable, Sendable {
    let value: Value?
    init(_ value: Value) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        do {
            value = try c.decode(Value.self)
        } catch DecodingError.typeMismatch {
            value = nil   // an object, array, number or string where the other kind belongs
        } catch DecodingError.valueNotFound {
            value = nil   // null
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let value { try c.encode(value) } else { try c.encodeNil() }
    }
}

extension DockCodec {
    static func sanitize(_ raw: RawFile, registry: DockRegistry) -> Result<Decoded, DockLayoutError> {
        var notes: [String] = []
        var workspaces: [String: DockLayout] = [:]
        for (name, rawLayout) in (raw.workspaces ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard workspaces.count < maxWorkspaces else { notes.append("dropped workspaces beyond \(maxWorkspaces)"); break }
            guard DockRegistry.isValidID(name) else { notes.append("dropped workspace \(quoted(name))"); continue }
            switch layout(rawLayout, registry: registry, notes: &notes) {
            case .success(let l?): workspaces[name] = l
            case .success(nil): notes.append("dropped workspace \(quoted(name)) without a layout")
            case .failure(let e): return .failure(e)
            }
        }
        guard let first = workspaces.keys.sorted().first else { return .failure(.noWorkspace) }
        let current = raw.current?.value.flatMap { workspaces[$0] == nil ? nil : $0 }
            ?? (workspaces[DockFile.defaultWorkspace] == nil ? first : DockFile.defaultWorkspace)
        return .success(Decoded(file: DockFile(current: current, workspaces: workspaces), notes: notes))
    }

    /// One workspace's layout; nil when it has no tree at all.
    static func layout(_ raw: RawLayout, registry: DockRegistry, notes: inout [String]) -> Result<DockLayout?, DockLayoutError> {
        guard let rawRoot = raw.root else { return .success(nil) }
        let m = rawRoot.measure
        guard m.depth <= maxDepth else { return .failure(.tooDeep) }
        guard m.count <= maxNodes else { return .failure(.tooManyNodes) }
        var seen = Set<DockPanelID>()
        let root = node(rawRoot, registry: registry, seen: &seen, notes: &notes)
        var layout = DockLayout(root: root ?? DockLayout.empty.root)
        layout.closed = places(raw.closed ?? [:], registry: registry, open: seen, notes: &notes)
        let before = Set(layout.openPanels)
        layout.repair(registry: registry)
        for id in layout.openPanels where !before.contains(id) { notes.append("added missing panel \(quoted(id))") }
        return .success(layout)
    }

    static func node(_ raw: RawNode, registry: DockRegistry, seen: inout Set<DockPanelID>, notes: inout [String]) -> DockNode? {
        switch raw {
        case .group(let g):
            return .group(group(g, registry: registry, seen: &seen, notes: &notes))
        case .split(let s):
            let named = s.axis?.value ?? ""
            let axis = DockAxis(rawValue: named)
            if axis == nil { notes.append("unknown split axis \(quoted(named)), using row") }
            let children = s.children ?? []
            // A missing or wrong weight is NaN here; `fixedWeights` makes it the mean of the others.
            let weights = (s.weights ?? []).map { $0.value ?? .nan }
            var kids: [DockNode] = [], kept: [Double] = []
            for (i, child) in children.enumerated() {
                guard let n = node(child, registry: registry, seen: &seen, notes: &notes) else { continue }
                kids.append(n); kept.append(i < weights.count ? weights[i] : .nan)
            }
            return .split(DockSplit(axis: axis ?? .row, children: kids, weights: kept))
        }
    }

    /// A group keeps the registered panels it lists that no earlier group took.
    static func group(_ g: RawGroup, registry: DockRegistry, seen: inout Set<DockPanelID>, notes: inout [String]) -> DockGroup {
        var panels: [DockPanelID] = []
        for entry in g.panels ?? [] {
            guard let id = entry.value else { notes.append("dropped a panel entry that is not a name"); continue }
            if !registry.contains(id) { notes.append("dropped unknown panel \(quoted(id))"); continue }
            if !seen.insert(id).inserted { notes.append("dropped duplicate panel \(quoted(id))"); continue }
            panels.append(id)
        }
        return DockGroup(id: g.id?.value ?? "", panels: panels, active: g.active?.value)
    }

    /// Closed panels' places: only registered, closable panels that are not open; ids in a place that are not
    /// registered are dropped, index and fraction are clamped.
    static func places(_ raw: [String: RawPlace], registry: DockRegistry, open: Set<DockPanelID>,
                       notes: inout [String]) -> [DockPanelID: DockPlace] {
        var out: [DockPanelID: DockPlace] = [:]
        for (id, p) in raw.sorted(by: { $0.key < $1.key }) {
            guard registry.contains(id), registry.isClosable(id), !open.contains(id) else {
                notes.append("dropped closed entry \(quoted(id))"); continue
            }
            out[id] = place(p, of: id, registry: registry)
        }
        return out
    }

    static func place(_ p: RawPlace, of id: DockPanelID, registry: DockRegistry) -> DockPlace {
        let known = { (ids: [Lenient<String>]?) in
            Array((ids ?? []).compactMap(\.value).filter { registry.contains($0) && $0 != id }.prefix(64))
        }
        let fraction = p.fraction?.value.flatMap { $0.isFinite && $0 > 0 && $0 < 1 ? $0 : nil }
        var place = DockPlace.beside(known(p.neighbour), edge: p.edge?.value.flatMap(DockEdge.init(rawValue:)), fraction: fraction)
        place.mates = known(p.mates)
        place.index = min(max(0, p.index?.value ?? 0), 64)
        return place
    }

    /// A value from the file as it appears in a note: quoted, at most 40 characters.
    static func quoted(_ s: String) -> String {
        let short = s.count > 40 ? String(s.prefix(40)) + "…" : s
        return "\"\(short)\""
    }
}
