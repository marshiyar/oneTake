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

/// One control over the existing noise reducer and dynamics processor. The ordinary FX-chain fields store the
/// strength and bypass, so project validation, live playback and offline export use their existing shared path.
public enum VoiceCleanup {
    public static let presetId = "voice-cleanup"
    public static let defaultStrength = 0.65

    public static func contains(_ node: FxNode) -> Bool { node.fromPreset == presetId }
    public static func isApplied(_ chain: FxChain) -> Bool { chain.nodes.contains(where: contains) }
    public static func isEnabled(_ chain: FxChain) -> Bool {
        let nodes = chain.nodes.filter(contains)
        return !nodes.isEmpty && nodes.allSatisfy { $0.enabled != false }
    }
    public static func strength(_ chain: FxChain) -> Double {
        guard let node = chain.nodes.first(where: { contains($0) && $0.type == "denoise" }) else { return defaultStrength }
        return normalized(AudioFx.normalize(node.type, node.params).num("amount"))
    }
    static func normalized(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : defaultStrength
    }

    /// Install once, preserving the other effects and their IDs/order. A repeated apply is a no-op.
    public static func apply(_ chain: FxChain, strength: Double = defaultStrength) -> FxChain {
        guard !isApplied(chain) else { return chain }
        var next = chain
        let amount = normalized(strength)
        let stages: [(String, String, [String: JSONValue])] = [
            ("denoise", "Voice Noise Reduction", ["amount": .number(amount), "learn": .number(500)]),
            ("compressor", "Voice Levelling", ["threshold": .number(-24), "ratio": .number(1 + 2 * amount),
                "attack": .number(12), "release": .number(180), "makeup": .number(3 * amount), "mix": .number(1)]),
        ]
        for (type, label, params) in stages {
            next.nodes.append(FxNode(type: type, id: next.mintNodeId(), fromPreset: presetId, label: label,
                                     enabled: true, params: AudioFx.normalize(type, params)))
        }
        return next
    }

    public static func settingStrength(_ chain: FxChain, _ strength: Double) -> FxChain {
        var next = chain
        let amount = normalized(strength)
        for i in next.nodes.indices where contains(next.nodes[i]) {
            var params = AudioFx.normalize(next.nodes[i].type, next.nodes[i].params)
            if next.nodes[i].type == "denoise" { params["amount"] = .number(amount) }
            if next.nodes[i].type == "compressor" {
                params["ratio"] = .number(1 + 2 * amount)
                params["makeup"] = .number(3 * amount)
            }
            next.nodes[i].params = params
            // Keep both stages fully wet: a dry mix around a latency-bearing noise reducer would move the
            // dry branch ahead of the voice. Their parameters provide the strength, with zero exactly neutral.
            next.nodes[i].presetAmount = nil
        }
        return next
    }

    /// Before/after changes only these two stages. The strength remains intact when listening to the original.
    public static func settingEnabled(_ chain: FxChain, _ enabled: Bool) -> FxChain {
        var next = chain
        for i in next.nodes.indices where contains(next.nodes[i]) { next.nodes[i].enabled = enabled }
        return next
    }

    public static func remove(_ chain: FxChain) -> FxChain { FxChain(nodes: chain.nodes.filter { !contains($0) }) }
}
