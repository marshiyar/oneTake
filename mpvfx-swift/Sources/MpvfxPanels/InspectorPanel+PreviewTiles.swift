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
import MpvfxCanvas
import MpvfxShared

/// What the look and effect tiles show: the 16:9 frame's picture, its "Rendering" caption, or its typed placeholder,
/// and the demo grade each Effects catalog tile previews on the host's sample picture.
extension InspectorPanel {
    /// One tile's demo: `key` names the tile, `grade` is the grade JSON it shows, on `clipId`'s frame when that clip
    /// has a picture (nil: always the sample picture).
    struct TileDemo {
        let key: String
        let grade: NativeJSONObject
        var clipId: String?
    }

    /// A look as clicking its tile applies it: `base.applying(p)`, keeping `base`'s LUT unless `lut` is given.
    static func lookDemo(_ p: ColorGrading.Preset, base: ColorGrading = ColorGrading(), lut: ColorGrading.Lut? = nil,
                         clipId: String? = nil) -> TileDemo {
        var g = base.applying(p)
        g.lut = lut ?? base.lut
        return TileDemo(key: "look:\(p.id)", grade: g.json, clipId: clipId)
    }

    /// An effect as "Add effect" applies it: `base` with the effect at its `EffectSpecs.applyDefaults` values.
    static func effectDemo(_ spec: EffectSpecs.Spec, base: ColorGrading = ColorGrading(), clipId: String? = nil) -> TileDemo {
        let g = EffectSpecs.adding(spec, to: base)
        return TileDemo(key: "fx:\(spec.key)", grade: g.json, clipId: clipId)
    }

    /// The largest tile picture asked for, in device pixels. A wide high-DPI panel would otherwise ask for ~1 MB per
    /// tile, a grid's tiles would outgrow the hosts' preview caches, and each finished tile (which redraws) would evict
    /// another, so the grid never settles. 18 tiles at this size are about 4.1 MB.
    public static let maxTilePixels = (width: 320, height: 180)

    /// The device-pixel size to ask for a tile frame `sw` drawn at `scale`, at most `maxTilePixels`.
    static func tilePixels(_ sw: CanvasRect, scale: Double) -> (width: Int, height: Int) {
        let s = min(max(1, scale), Double(maxTilePixels.width) / max(1, sw.width), Double(maxTilePixels.height) / max(1, sw.height))
        return (Int((sw.width * s).rounded()), Int((sw.height * s).rounded()))
    }

    /// `demo` at `w` x `h` device pixels from the host (the clip's frame, else the sample picture); a typed failure
    /// without a host renderer.
    func samplePreview(_ demo: TileDemo, _ w: Int, _ h: Int) -> PresetPreviewState {
        let req = EffectPreviewRequest(key: demo.key, grade: demo.grade, clipId: demo.clipId, pixelWidth: w, pixelHeight: h)
        return effectPreview?(req) ?? .failed(.noRenderer)
    }

    /// A Grade preset tile: the clip's frame graded with the preset (`presetPreview`); when the clip has no picture,
    /// the sample picture with the look instead, so the tile still shows what the preset does.
    func lookPreview(_ req: PresetPreviewRequest) -> PresetPreviewState {
        let own = presetPreview?(req) ?? .unavailable
        guard case .unavailable = own else { return own }
        guard let p = ColorGrading.preset(req.presetId) else { return .failed(.noPicture) }
        let lut = req.lutSrc.map { ColorGrading.Lut(src: $0, intensity: req.lutIntensity) }
        return samplePreview(Self.lookDemo(p, lut: lut), req.pixelWidth, req.pixelHeight)
    }

    /// The tile's 16:9 frame `sw`: the `bg-black/20` scrim, then the picture (`object-contain`), a "Rendering"
    /// caption in the bottom-left corner while it renders, or a placeholder naming why there is no picture.
    static func drawPreviewFrame(_ c: CanvasContext, _ sw: CanvasRect, _ state: PresetPreviewState) {
        c.fillRect(sw, PanelTheme.stageScrim.withAlpha(0.2))
        switch state {
        case .ready(let img):
            c.withState {
                c.clip(sw)
                c.drawImage(img, in: containRect(img.width, img.height, in: sw))
            }
        case .rendering:
            PanelDraw.text(c, "Rendering…", in: CanvasRect(x: sw.x + 6, y: sw.maxY - 17, width: sw.width - 12, height: 13.5),
                           font: PanelTheme.font(11), color: PanelTheme.inspectorText)
        case .unavailable:
            drawPlaceholder(c, sw, .noPicture)
        case .failed(let why):
            drawPlaceholder(c, sw, why)
        }
    }

    /// "No preview" over the reason, centred in the frame, on a hairline inset so the tile reads as a placeholder.
    static func drawPlaceholder(_ c: CanvasContext, _ sw: CanvasRect, _ why: PreviewFailure) {
        c.strokeRect(sw.insetBy(4.5), PanelTheme.panelHairline, width: 1)
        let line = CanvasRect(x: sw.x + 8, y: sw.midY - 15, width: sw.width - 16, height: 15)
        PanelDraw.text(c, "No preview", in: line, font: PanelTheme.font(11, .medium), color: PanelTheme.inspectorText, align: .center)
        PanelDraw.text(c, why.reason, in: CanvasRect(x: line.x, y: line.maxY + 1, width: line.width, height: 13.5),
                       font: PanelTheme.font(11), color: PanelTheme.inspectorText, align: .center)
    }
}
