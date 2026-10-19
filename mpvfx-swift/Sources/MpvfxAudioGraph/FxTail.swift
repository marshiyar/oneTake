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

// FX tails: how long an effect chain keeps sounding after its input stops.
public enum FxTail {
    public static let maxSeconds = 5.0
    static let floor = 0.001

    static func knobMax(_ node: FxNode, _ key: String, _ automation: Automation?) -> Double {
        let fallback = AudioFx.normalize(node.type, node.params)[key]?.number ?? 0
        let safe = fallback.isFinite ? fallback : 0
        guard let id = node.id, let automation else { return safe }
        guard let lane = automation.lanes.first(where: { $0.target == AudioAutomation.fxTarget(id, key) }), !lane.points.isEmpty else { return safe }
        return lane.points.reduce(-Double.infinity) { jsMax($0, $1.v) }
    }

    static func delayTail(_ time: Double, _ feedback: Double) -> Double {
        let gap = min(5, time / 1000)
        if gap <= 0 { return 0 }
        let fb = max(0, min(0.999, feedback))
        if fb <= 0 { return gap }
        return (log(floor) / log(fb)).rounded(.up) * gap
    }

    static func nodeTail(_ node: FxNode, _ a: Automation?) -> Double {
        if node.enabled == false { return 0 }
        switch node.type {
        case "reverb": return knobMax(node, "wet", a) > 0 ? 0.6 + max(0, min(1, knobMax(node, "size", a))) * 2.6 : 0
        case "delay": return knobMax(node, "mix", a) > 0 ? delayTail(knobMax(node, "time", a), knobMax(node, "feedback", a)) : 0
        case "chorus": return knobMax(node, "mix", a) > 0 ? knobMax(node, "delay", a) / 1000 : 0
        case "pitchshift": return knobMax(node, "mix", a) > 0 ? 0.2 : 0
        default: return 0
        }
    }

    /// `chainTailSeconds`: summed over the serial chain, capped at five seconds.
    public static func chainSeconds(_ chain: FxChain, _ automation: Automation? = nil) -> Double {
        min(maxSeconds, chain.nodes.reduce(0) { $0 + nodeTail($1, automation) })
    }
}
