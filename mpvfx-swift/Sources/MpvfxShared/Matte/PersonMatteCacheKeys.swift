// The cache key of the matte a clip needs.
import Foundation

public extension PersonMatteEffect {
    /// The media file's digest, the source range the clip plays (`sourceInFrame` for `durationFrames` at its playback
    /// rate), the quality and the analysis size. nil when the media file cannot be read or its picture size is not known.
    static func cacheKey(clip: NativeProjectClip, asset: NativeProjectAsset, mediaPath: String, projectFPS fps: Double,
                         quality: String, digest: String? = nil) -> PersonMatteCacheKey? {
        guard fps.isFinite, fps > 0, let aspect = asset.naturalSize?.aspect,
              let digest = digest ?? PersonMatteMediaDigest.digest(path: mediaPath) else { return nil }
        let start = sourceFrameValue(NativeSourcePosition(sourceInFrame: clip.sourceInFrame, sourceInFraction: clip.sourceInFraction)) / fps
        let rate = clip.playbackRate.flatMap { $0.denominator != 0 && $0.numerator > 0 ? $0.numerator / $0.denominator : nil } ?? 1
        let length = clip.durationFrames / fps * rate
        let size = analysisSize(aspect: aspect)
        return PersonMatteCacheKey(digest: digest, sourceStartMs: Int((start * 1000).rounded()),
                                   sourceDurationMs: max(1, Int((length * 1000).rounded())), quality: quality,
                                   width: size.width, height: size.height)
    }
}
