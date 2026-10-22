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
import MpvfxAudioGraph

extension InspectorPanel {
    /// Standard inspector descriptors provide Tab/Enter/Space activation and arrow-key strength adjustment.
    func voiceCleanupRows(_ chain: FxChain, write: @escaping (FxChain) -> Void) -> [InspectorRow] {
        guard VoiceCleanup.isApplied(chain) else {
            return [.init(.buttons([.init(key: "voice-cleanup:apply", label: "Clean up voice", style: .muted) {
                write(VoiceCleanup.apply(chain))
            }]))]
        }
        let strength = VoiceCleanup.strength(chain)
        let display: (Double) -> String = { "\(Int($0.rounded()))%" }
        return [
            .init(.heading("Voice clean-up", trailing: nil)),
            .init(.slider(.init(key: "voice-cleanup:strength", label: "Strength", position: strength * 100,
                min: 0, max: 100, display: display(strength * 100), format: display, tier: .explicitCustom,
                commit: { write(VoiceCleanup.settingStrength(chain, $0 / 100)) },
                reset: { write(VoiceCleanup.settingStrength(chain, VoiceCleanup.defaultStrength)) }))),
            .init(.buttons([
                .init(key: "voice-cleanup:listen", label: VoiceCleanup.isEnabled(chain) ? "Listen before" : "Listen after", style: .muted) {
                    write(VoiceCleanup.settingEnabled(chain, !VoiceCleanup.isEnabled(chain)))
                },
                .init(key: "voice-cleanup:remove", label: "Remove clean-up", style: .muted) {
                    write(VoiceCleanup.remove(chain))
                },
            ])),
        ]
    }
}
