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

// The registry of every audio effect, its
// parameters, and the chain document codec.

public enum FxScale: String, Sendable { case linear, log }

public enum FxParamDef: Sendable {
    case number(key: String, label: String, unit: String, min: Double, max: Double, step: Double, defaultValue: Double, scale: FxScale?, automatable: Bool)
    case enumeration(key: String, label: String, options: [(value: String, label: String)], defaultValue: String)

    public var key: String {
        switch self { case let .number(key, _, _, _, _, _, _, _, _): return key; case let .enumeration(key, _, _, _): return key }
    }
    public var label: String {
        switch self { case let .number(_, label, _, _, _, _, _, _, _): return label; case let .enumeration(_, label, _, _): return label }
    }
}

/// A parameter value as the chain file carries it: numbers for knobs, strings for enums.
public enum FxParamValue: Equatable, Sendable {
    case number(Double)
    case string(String)

    public var number: Double {
        switch self { case let .number(n): return n; case let .string(s): return jsStringToNumber(s).isNaN ? 0 : jsStringToNumber(s) }
    }
    public var string: String {
        switch self { case let .number(n): return jsNumberToString(n); case let .string(s): return s }
    }
    var json: JSONValue { switch self { case let .number(n): return .number(n); case let .string(s): return .string(s) } }
}

/// Ordered parameter record (`Record<string, number | string>`; key order follows the registry).
public struct FxParams: Equatable, Sendable {
    public var entries: [(String, FxParamValue)]
    public init(_ entries: [(String, FxParamValue)] = []) { self.entries = entries }
    public subscript(key: String) -> FxParamValue? {
        get { entries.first(where: { $0.0 == key })?.1 }
        set {
            if let i = entries.firstIndex(where: { $0.0 == key }) {
                if let v = newValue { entries[i].1 = v } else { entries.remove(at: i) }
            } else if let v = newValue { entries.append((key, v)) }
        }
    }
    public func num(_ key: String) -> Double { self[key]?.number ?? 0 }
    public static func == (a: FxParams, b: FxParams) -> Bool {
        a.entries.count == b.entries.count && zip(a.entries, b.entries).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
    var json: JSONValue { .object(entries.map { ($0.0, $0.1.json) }) }
}

public struct FxDef: Sendable {
    public let id: String
    public let label: String
    public let group: String
    public let params: [FxParamDef]
    public let implementation: String
}

private func freq(_ key: String = "frequency", _ label: String = "Frequency", _ def: Double = 1000, _ min: Double = 20, _ max: Double = 20000) -> FxParamDef {
    .number(key: key, label: label, unit: "Hz", min: min, max: max, step: 1, defaultValue: def, scale: .log, automatable: true)
}
private func qParam(_ def: Double = 0.707) -> FxParamDef {
    .number(key: "q", label: "Q", unit: "", min: 0.1, max: 20, step: 0.01, defaultValue: def, scale: .log, automatable: true)
}
private func gainDb(_ min: Double = -40, _ max: Double = 40, _ def: Double = 0) -> FxParamDef {
    .number(key: "gain", label: "Gain", unit: "dB", min: min, max: max, step: 0.1, defaultValue: def, scale: nil, automatable: true)
}
private let poles = FxParamDef.enumeration(key: "poles", label: "Slope", options: [("1", "6 dB/oct"), ("2", "12 dB/oct")], defaultValue: "2")
private func num(_ key: String, _ label: String, _ unit: String, _ min: Double, _ max: Double, _ step: Double, _ def: Double, scale: FxScale? = nil, automatable: Bool = false) -> FxParamDef {
    .number(key: key, label: label, unit: unit, min: min, max: max, step: step, defaultValue: def, scale: scale, automatable: automatable)
}

public enum AudioFx {
    public static let attribute = "data-fx-chain"
    public static let chainVersion = 1

    /// Every effect, in panel order (HF_AUDIO_FX).
    public static let definitions: [FxDef] = [
        FxDef(id: "gain", label: "Gain", group: "dynamics", params: [gainDb(-60, 12, 0)], implementation: "gain"),
        FxDef(id: "peaking", label: "Peaking EQ", group: "filter", params: [freq("frequency", "Frequency", 1000), gainDb(-40, 40, 0), qParam(1)], implementation: "biquad-peaking"),
        FxDef(id: "lowshelf", label: "Low Shelf", group: "filter", params: [freq("frequency", "Frequency", 200, 20, 2000), gainDb(-40, 40, 0)], implementation: "biquad-lowshelf"),
        FxDef(id: "highshelf", label: "High Shelf", group: "filter", params: [freq("frequency", "Frequency", 4000, 500, 20000), gainDb(-40, 40, 0)], implementation: "biquad-highshelf"),
        FxDef(id: "highpass", label: "High-pass", group: "filter", params: [freq("frequency", "Cutoff", 300, 20, 20000), qParam(0.707), poles], implementation: "biquad-highpass"),
        FxDef(id: "lowpass", label: "Low-pass", group: "filter", params: [freq("frequency", "Cutoff", 8000, 100, 20000), qParam(0.707), poles], implementation: "biquad-lowpass"),
        FxDef(id: "compressor", label: "Compressor", group: "dynamics", params: [
            num("threshold", "Threshold", "dB", -60, 0, 0.5, -24), num("ratio", "Ratio", ":1", 1, 20, 0.1, 4),
            num("attack", "Attack", "ms", 0.01, 2000, 0.1, 20, scale: .log), num("release", "Release", "ms", 0.01, 9000, 1, 250, scale: .log),
            num("knee", "Knee", "", 1, 8, 0.01, 2.83), num("makeup", "Makeup", "dB", 0, 36, 0.1, 0), num("mix", "Mix", "", 0, 1, 0.01, 1),
        ], implementation: "compressor"),
        FxDef(id: "limiter", label: "Limiter", group: "dynamics", params: [
            num("limit", "Ceiling", "dB", -24, 0, 0.1, -1), num("attack", "Attack", "ms", 0.1, 80, 0.1, 5),
            num("release", "Release", "ms", 1, 8000, 1, 50, scale: .log), num("level_out", "Output", "dB", -24, 24, 0.1, 0),
        ], implementation: "limiter"),
        FxDef(id: "gate", label: "Noise Gate", group: "dynamics", params: [
            num("threshold", "Threshold", "dB", -80, 0, 0.5, -35), num("range", "Range", "dB", -80, 0, 0.5, -24),
            num("ratio", "Ratio", ":1", 1, 20, 0.1, 10), num("attack", "Attack", "ms", 0.01, 9000, 0.1, 1, scale: .log),
            num("release", "Release", "ms", 0.01, 9000, 1, 100, scale: .log), num("knee", "Knee", "", 1, 8, 0.01, 2.83),
        ], implementation: "gate"),
        FxDef(id: "saturate", label: "Saturation", group: "nonlinear", params: [
            .enumeration(key: "type", label: "Curve", options: [("tanh", "Tanh"), ("atan", "Arctan"), ("cubic", "Cubic"), ("exp", "Exponential"), ("alg", "Algebraic"),
                                                                 ("quintic", "Quintic"), ("sin", "Sine"), ("erf", "Error function"), ("hard", "Hard clip")], defaultValue: "tanh"),
            num("threshold", "Threshold", "dB", -40, 0, 0.1, -6), num("output", "Output", "dB", -24, 24, 0.1, 0, automatable: true),
            num("oversample", "Oversample", "x", 1, 8, 1, 4),
        ], implementation: "waveshaper"),
        FxDef(id: "bitcrush", label: "Bitcrush", group: "nonlinear", params: [
            num("bits", "Bit depth", "bit", 1, 32, 0.1, 8), num("samples", "Sample hold", "x", 1, 250, 1, 1), num("mix", "Mix", "", 0, 1, 0.01, 1),
        ], implementation: "bitcrusher"),
        FxDef(id: "pitchshift", label: "Pitch shift", group: "time", params: [
            num("semitones", "Semitones", "st", -12, 12, 1, 0), num("mix", "Mix", "", 0, 1, 0.01, 1),
        ], implementation: "pitch-shift"),
        FxDef(id: "delay", label: "Delay", group: "time", params: [
            num("time", "Time", "ms", 1, 5000, 1, 250, scale: .log, automatable: true), num("feedback", "Feedback", "", 0.01, 0.95, 0.01, 0.35, automatable: true),
            num("mix", "Mix", "", 0, 1, 0.01, 0.4, automatable: true),
        ], implementation: "delay-feedback"),
        FxDef(id: "chorus", label: "Chorus", group: "time", params: [
            num("delay", "Delay", "ms", 1, 100, 0.1, 7, automatable: true), num("depth", "Depth", "ms", 0, 10, 0.01, 2, automatable: true),
            num("speed", "Rate", "Hz", 0.01, 10, 0.01, 1, automatable: true), num("mix", "Mix", "", 0, 1, 0.01, 0.5, automatable: true),
        ], implementation: "chorus-lfo"),
        FxDef(id: "phaser", label: "Phaser", group: "time", params: [
            num("in_gain", "Input", "", 0, 1, 0.01, 0.4, automatable: true), num("out_gain", "Output", "", 0, 2, 0.01, 0.74, automatable: true),
            num("delay", "Delay", "ms", 0.1, 5, 0.1, 3), num("decay", "Decay", "", 0, 0.99, 0.01, 0.4),
            num("speed", "Rate", "Hz", 0.1, 2, 0.01, 0.5, automatable: true),
            .enumeration(key: "type", label: "Waveform", options: [("0", "Triangular"), ("1", "Sinusoidal")], defaultValue: "0"),
        ], implementation: "allpass-phaser"),
        FxDef(id: "reverb", label: "Reverb", group: "time", params: [
            num("size", "Room size", "", 0.05, 1, 0.01, 0.7), num("damping", "Damping", "", 0, 1, 0.01, 0.5),
            num("wet", "Wet", "", 0, 1, 0.01, 0.35, automatable: true), num("dry", "Dry", "", 0, 1, 0.01, 0.7, automatable: true),
        ], implementation: "convolver"),
    ]

    public static let ids: [String] = definitions.map(\.id)
    private static let byId: [String: FxDef] = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })

    public static func definition(_ id: String) -> FxDef? { byId[id] }

    public static func defaultParams(_ id: String) -> FxParams {
        guard let def = byId[id] else { return FxParams() }
        return FxParams(def.params.map { p in
            switch p {
            case let .number(key, _, _, _, _, _, d, _, _): return (key, .number(d))
            case let .enumeration(key, _, _, d): return (key, .string(d))
            }
        })
    }

    /// `normalizeAudioFxParams`: drop unknown keys, fill defaults, clamp numbers, validate enums.
    public static func normalize(_ id: String, _ values: [String: JSONValue]?) -> FxParams {
        guard let def = byId[id] else { return FxParams() }
        var out = FxParams()
        for p in def.params {
            let raw = values?[p.key]
            switch p {
            case let .enumeration(key, _, options, d):
                if case let .string(s)? = raw, options.contains(where: { $0.value == s }) { out.entries.append((key, .string(s))) }
                else { out.entries.append((key, .string(d))) }
            case let .number(key, _, _, mn, mx, _, d, _, _):
                var n = Double.nan
                if case let .number(v)? = raw { n = v }
                else if case let .string(s)? = raw, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { n = jsStringToNumber(s) }
                out.entries.append((key, .number(n.isFinite ? Swift.min(mx, Swift.max(mn, n)) : d)))
            }
        }
        return out
    }

    public static func normalize(_ id: String, _ params: FxParams?) -> FxParams {
        normalize(id, params.map { Dictionary($0.entries.map { ($0.0, $0.1.json) }, uniquingKeysWith: { _, b in b }) })
    }
}

public struct FxNode: Equatable, Sendable {
    public var type: String
    public var id: String?
    public var fromCarve: Bool?
    public var fromPreset: String?
    public var label: String?
    public var fromEq: String?
    public var fromLeveller: Bool?
    public var presetAmount: Double?
    public var enabled: Bool?
    public var params: FxParams?

    public init(type: String, id: String? = nil, fromCarve: Bool? = nil, fromPreset: String? = nil, label: String? = nil, fromEq: String? = nil,
                fromLeveller: Bool? = nil, presetAmount: Double? = nil, enabled: Bool? = nil, params: FxParams? = nil) {
        self.type = type; self.id = id; self.fromCarve = fromCarve; self.fromPreset = fromPreset; self.label = label; self.fromEq = fromEq
        self.fromLeveller = fromLeveller; self.presetAmount = presetAmount; self.enabled = enabled; self.params = params
    }
}

public struct FxChain: Equatable, Sendable {
    public var version: Int = AudioFx.chainVersion
    public var nodes: [FxNode]
    public init(nodes: [FxNode] = []) { self.nodes = nodes }

    /// `enabledAudioFxNodes`.
    public var enabledNodes: [FxNode] { nodes.filter { $0.enabled != false } }

    /// `mintAudioFxNodeId`: `n1`, `n2`, … counted, never random.
    public func mintNodeId() -> String {
        let taken = Set(nodes.compactMap(\.id).filter { !$0.isEmpty })
        var i = 1
        while taken.contains("n\(i)") { i += 1 }
        return "n\(i)"
    }
}

public struct AudioFxChainError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

extension AudioFx {
    /// `parseAudioFxChain`.
    public static func parseChain(_ json: String) throws -> FxChain {
        let raw: JSONValue
        do { raw = try parseJSON(json) } catch { throw AudioFxChainError(message: "Chain file is not valid JSON: \(error)") }
        // `typeof raw === "object"` admits arrays, which then have no `version`.
        let pairs: [(String, JSONValue)]
        switch raw {
        case let .object(p): pairs = p
        case .array: pairs = []
        default: throw AudioFxChainError(message: "Chain file must be a JSON object.")
        }
        let obj = Dictionary(pairs, uniquingKeysWith: { _, b in b })
        guard case .number(Double(chainVersion))? = obj["version"] else {
            throw AudioFxChainError(message: "Unsupported chain version: \(jsDisplay(obj["version"]))")
        }
        guard case let .array(items)? = obj["nodes"] else { throw AudioFxChainError(message: "Chain file is missing a `nodes` array.") }
        return FxChain(nodes: try items.enumerated().map { try parseNode($0.element, $0.offset) })
    }

    private static func parseNode(_ n: JSONValue, _ i: Int) throws -> FxNode {
        let pairs: [(String, JSONValue)]
        switch n {
        case let .object(p): pairs = p
        case .array: pairs = []
        default: throw AudioFxChainError(message: "Node \(i) is not an object.")
        }
        let o = Dictionary(pairs, uniquingKeysWith: { _, b in b })
        guard case let .string(type)? = o["type"], definition(type) != nil else {
            throw AudioFxChainError(message: "Node \(i) has unknown effect type: \(jsDisplay(o["type"]))")
        }
        var params: [String: JSONValue]? = nil
        if case let .object(pp)? = o["params"] { params = Dictionary(pp, uniquingKeysWith: { _, b in b }) }
        return FxNode(type: type, id: nonEmpty(o["id"]), fromCarve: onlyTrue(o["fromCarve"]), fromPreset: nonEmpty(o["fromPreset"]),
                      label: nonEmpty(o["label"]), fromEq: nonEmpty(o["fromEq"]), fromLeveller: onlyTrue(o["fromLeveller"]),
                      presetAmount: clampedAmount(o["presetAmount"]), enabled: o["enabled"] != .bool(false),
                      params: normalize(type, params))
    }

    /// `serializeAudioFxChain`.
    public static func serializeChain(_ chain: FxChain) -> String {
        stringifyJSON(.object([("version", .number(Double(chainVersion))), ("nodes", .array(chain.nodes.map(nodeJSON)))]))
    }

    static func nodeJSON(_ node: FxNode) -> JSONValue {
        var pairs: [(String, JSONValue)] = [("type", .string(node.type))]
        if let id = node.id, !id.isEmpty { pairs.append(("id", .string(id))) }
        if node.fromCarve == true { pairs.append(("fromCarve", .bool(true))) }
        if let p = node.fromPreset, !p.isEmpty { pairs.append(("fromPreset", .string(p))) }
        if let l = node.label, !l.isEmpty { pairs.append(("label", .string(l))) }
        if let e = node.fromEq, !e.isEmpty { pairs.append(("fromEq", .string(e))) }
        if node.fromLeveller == true { pairs.append(("fromLeveller", .bool(true))) }
        if let a = node.presetAmount, a != 1, a.isFinite { pairs.append(("presetAmount", .number(min(1, max(0, a))))) }
        if node.enabled == false { pairs.append(("enabled", .bool(false))) }
        pairs.append(("params", normalize(node.type, node.params).json))
        return .object(pairs)
    }

    private static func nonEmpty(_ v: JSONValue?) -> String? { if case let .string(s)? = v, !s.isEmpty { return s }; return nil }
    private static func onlyTrue(_ v: JSONValue?) -> Bool? { v == .bool(true) ? true : nil }
    private static func clampedAmount(_ v: JSONValue?) -> Double? {
        guard case let .number(n)? = v, n.isFinite else { return nil }
        return min(1, max(0, n))
    }
}

/// `String(value)` for the error messages the chain readers build.
func jsDisplay(_ v: JSONValue?) -> String {
    switch v {
    case nil: return "undefined"
    case .null?: return "null"
    case let .bool(b)?: return b ? "true" : "false"
    case let .number(n)?: return jsNumberToString(n)
    case let .string(s)?: return s
    case let .array(a)?: return a.map { jsDisplay($0) }.joined(separator: ",")
    case .object?: return "[object Object]"
    }
}
