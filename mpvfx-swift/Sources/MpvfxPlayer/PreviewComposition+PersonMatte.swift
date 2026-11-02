// Person matte in the composition: which clips carry the effect, and the cached matte frame each layer is drawn with.
import Foundation
import MpvfxShared

/// A clip's person-matte effect resolved against the cache: the file it reads and the edge controls.
struct PersonMatteBinding {
    var key: PersonMatteCacheKey?
    var parameters: PersonMatteEffect.Parameters
    var projectDir: String
    var store: PersonMatteCacheStore

    /// nil when the clip has no enabled, readable person-matte effect.
    static func forClip(_ clip: NativeProjectClip, asset: NativeProjectAsset, mediaPath: String, projectDir: URL?, fps: Double,
                        store: PersonMatteCacheStore, digests: inout [String: String?]) -> PersonMatteBinding? {
        guard let active = PersonMatteEffect.active(clip) else { return nil }
        let digest: String?
        if let known = digests[mediaPath] { digest = known }
        else { digest = PersonMatteMediaDigest.digest(path: mediaPath); digests[mediaPath] = .some(digest) }
        let key = digest.flatMap { PersonMatteEffect.cacheKey(clip: clip, asset: asset, mediaPath: mediaPath, projectFPS: fps,
                                                              quality: active.parameters.quality, digest: $0) }
        return PersonMatteBinding(key: key, parameters: active.parameters, projectDir: projectDir?.path ?? ".", store: store)
    }
}

extension PreviewComposition {
    /// Sets the layer's matte: the cache frame at the layer's source time (the nearest earlier analysed frame, never
    /// blended). A clip whose cache is missing, damaged or short of this time draws without it and is marked
    /// `matteNeedsAnalysis` (the corruption is reported once, by the store).
    func attachPersonMatte(_ e: Entry, to layer: inout PreviewLayer, at time: Double) {
        guard let binding = e.personMatte else { return }
        guard let key = binding.key else { layer.matteNeedsAnalysis = true; return }
        guard case .reader(let reader) = binding.store.outcome(for: key, projectDir: binding.projectDir) else {
            layer.matteNeedsAnalysis = true; return
        }
        let sourceTime = layer.sourceTime(at: time)
        guard let frame = reader.frame(atSourceSeconds: sourceTime) else {
            layer.matteNeedsAnalysis = true
            let local = sourceTime - Double(reader.header.sourceStartMs) / 1000
            if local >= -1e-6, local < Double(reader.header.sourceDurationMs) / 1000 { binding.store.reportUndecodable(path: key.path(projectDir: binding.projectDir)) }
            return
        }
        let index = max(0, Int(((sourceTime - Double(reader.header.sourceStartMs) / 1000) * reader.header.fps + 1e-6).rounded(.down)))
        layer.matte = PreviewMatte(identity: "\(key.name)#\(min(index, reader.frameCount - 1))", frame: frame,
                                   shrink: binding.parameters.shrink, soften: binding.parameters.soften, invert: binding.parameters.invert)
    }
}
