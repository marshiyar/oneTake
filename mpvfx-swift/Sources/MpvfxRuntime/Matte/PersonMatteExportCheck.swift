// Export pre-flight for the person-matte effect: a clip whose matte is missing, damaged or incomplete is refused,
// never exported without it, so the file never differs from what was previewed after analysis.
import Foundation
import MpvfxShared

/// One issue per clip with an enabled person-matte effect whose cache does not cover its source range, for
/// `planExport` (for example "Interview 2: the person matte is not analysed for 00:12–00:20").
/// `range` limits the check to clips the export reaches.
func personMatteExportIssues(_ project: NativeProjectDocument, projectDir: String, range: ExportFrameRange?) -> [String] {
    let visible = nativeExportVisibleProject(project)
    let assets = Dictionary(visible.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let fps = visible.frameRate.denominator != 0 ? visible.frameRate.numerator / visible.frameRate.denominator : 30
    var issues: [String] = []
    for track in visible.sequence.tracks { for clip in track.clips {
        guard let matte = PersonMatteEffect.active(clip), let asset = assets[clip.assetId], asset.kind == .video,
              let source = asset.source, !source.isEmpty else { continue }
        if let range, clip.startFrame + clip.durationFrames <= range.startFrame || clip.startFrame >= range.endFrame { continue }
        let path = PosixPath.resolve(projectDir, source)
        if !personMatteIsComplete(clip: clip, asset: asset, mediaPath: path, fps: fps, quality: matte.parameters.quality, projectDir: projectDir) {
            let from = clip.startFrame / fps, to = (clip.startFrame + clip.durationFrames) / fps
            issues.append("\(asset.name): the person matte is not analysed for \(clock(from))–\(clock(to))")
        }
    } }
    return issues
}

/// Whether the cache holds a readable matte for every frame of the clip's source range.
func personMatteIsComplete(clip: NativeProjectClip, asset: NativeProjectAsset, mediaPath: String, fps: Double, quality: String,
                           projectDir: String) -> Bool {
    guard let key = PersonMatteEffect.cacheKey(clip: clip, asset: asset, mediaPath: mediaPath, projectFPS: fps, quality: quality),
          case .reader(let reader) = PersonMatteCacheStore().outcome(for: key, projectDir: projectDir) else { return false }
    return reader.frameCount == key.expectedFrameCount(fps: reader.header.fps) && reader.verifiesEveryFrame()
}

private func clock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded(.down)))
    return String(format: "%02d:%02d", s / 60, s % 60)
}
