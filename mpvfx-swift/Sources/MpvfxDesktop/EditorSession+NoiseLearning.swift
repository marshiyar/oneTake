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
import Foundation
import MpvfxAudio
import MpvfxAudioGraph

extension EditorSession {
    /// Clean up noise › Learn noise: reads the noise of the clip's sound off the UI thread, then keeps the profile with the
    /// effect as one undo step. Learning again replaces it; nothing else ever does.
    func learnNoise(clipId: String, nodeIndex: Int, source: NoiseLearning.Source, post: @escaping (@escaping () -> Void) -> Void) {
        let document = editor.document, directory = projectDir
        let inPoint = playback.inPoint, outPoint = playback.outPoint
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try NoiseLearning.learn(source, clipId: clipId, document: document, projectDir: directory,
                                                          inPoint: inPoint, outPoint: outPoint) }
            post { self?.finishLearningNoise(result, clipId: clipId, nodeIndex: nodeIndex) }
        }
    }

    func finishLearningNoise(_ result: Result<[Double], Error>, clipId: String, nodeIndex: Int) {
        let title = "Could not learn the noise"
        switch result {
        case .failure(let error):
            onError(title, (error as? NoiseLearning.Failure)?.description ?? "The sound of this clip could not be read. Check that its file is still there, then try again.")
        case .success(let profile):
            guard let clip = editor.document.sequence.tracks.flatMap(\.clips).first(where: { $0.id == clipId }),
                  let text = clip.audioFxChain, var chain = try? AudioFx.parseChain(text),
                  chain.nodes.indices.contains(nodeIndex), chain.nodes[nodeIndex].type == "denoise" else {
                onError(title, "The effect changed while the noise was being read. Learn the noise again."); return
            }
            chain.nodes[nodeIndex].noiseProfile = profile
            guard editor.setClipFxChain(clipId: clipId, AudioFx.serializeChain(chain)) else {
                onError(title, "The clip could not be changed. Unlock its track, then try again."); return
            }
            playback.duration = editor.duration
            syncStage(); redraw()
        }
    }
}
