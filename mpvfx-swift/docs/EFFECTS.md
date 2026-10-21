# Color grading and stylize effects: the clip effect JSON

How a clip stores its color grade and its stylize effects in `project.json` (grading contract v3, grading
engine 0.8.20) and how the app reads, edits and renders it. One schema serves preview and export: `Sources/MpvfxColor` (`ColorGradeParams`, `GradeShader`,
`ColorGradeRenderer`, `CubeLUT`) is the grading shader on the CPU, the player grades each decoded frame
with it (3fe63d2) and export grades each graded clip with the same pass before compositing (5dbd897). The
inspector edits it through `Sources/MpvfxPanels/ColorGrading.swift` and `TimelineEditor.setColorGrading`.

## Where it lives

The grade is one entry of the clip's `effects` array (`NativeClipEffect`):

```json
{
  "id": "clip:a",
  "effects": [
    { "id": "fx-1", "effectId": "color-grading", "enabled": true, "parameters": { "...grade object below..." } }
  ]
}
```

- `effectId` is always `"color-grading"`. A clip has at most one; the panels and both renderers use the first.
- `enabled: false` on the effect, or `"enabled": false` inside the grade, switches the whole grade (and its stylize
  effects) off. Nothing is drawn.
- The stylize effects are not separate effect entries: they are the `effects` object **inside** the grade.
- Any other `effectId` on a clip is kept in the document and listed in the inspector's Clip effects group, but
  neither renderer draws it, and export refuses a clip that has one enabled (`exportSupportsEffect`).
- Grades are not keyframed: a clip has one grade for its whole length. Grain, film dust, tape damage, glitch and
  waving hatch lines move with the clip's timeline time (`isTimeVarying`), seeded per clip (`colorGradeSeed`,
  FNV-1a of the clip key).

## The grade object

Top-level keys: `enabled, version, preset, intensity, adjust, pivot, wheels, balance, curves, hueCurves,
secondaries, details, effects, palette, lut, colorSpace`. A grade authored outside the app should write `"version": 3`. Every key is optional. Reading normalizes the object the
way `normalizeHfColorGrading` does (`ColorGradeParams.init(json:)`): missing values come from the named preset,
or from the contract defaults when there is no preset; every number is clamped to its limit; a non-finite number
reads as 0; malformed curves fall back to identity.

| Key | Type | Meaning, limits, default |
| --- | --- | --- |
| `enabled` | bool | `false` turns the grade off. Default on. |
| `version` | number | Grading contract the grade was written under. `3` (written by the inspector for every new grade): Warmth and Tint scale the R, G and B channels, normalized so a grey keeps its luma, and black stays black. Absent or anything below 3: contract 2, where Warmth and Tint add a fixed offset to every pixel (how grades saved before 2026-10-21 render). Editing a grade keeps its version; resetting the whole grade starts a contract 3 grade. The secondary correction's Warmth and Tint follow the same rule. |
| `preset` | string or null | Preset id (table below). Its values fill every key the object leaves out. |
| `intensity` | number 0…1 | Mix of the primary grade (adjust, wheels, curves, secondaries, LUT) over the source. Default 1, or the preset's. Vignette, grain and stylize effects are not scaled by it. |
| `adjust` | object | Primary correction. `exposure` −2…2 (stops); `contrast, highlights, shadows, whites, blacks, temperature, tint, vibrance, saturation` −1…1. Default 0. UI labels: Exposure, Contrast, Highlights, Shadows, White Point, Black Point, Warmth, Tint, Vibrance, Saturation. |
| `wheels` | object | `shadows`, `midtones`, `highlights`, each `{ "hue": 0…360 (wrapped), "amount": 0…1, "level": −1…1 }`. Default all 0. |
| `balance` | object | Lift / Gamma / Gain / Offset: `lift`, `gamma`, `gain`, `offset`, each `{ "hue": 0…360 (wrapped), "amount": 0…1, "level": −1…1 }`. Lift adds `0.25·level` (plus `0.2·amount` along the hue) scaled by (1 − x), so black moves and white stays; gain multiplies by 1 + `0.5·level` (+ `0.4·amount`), so black stays; gamma raises to 1 / (1 + `0.5·level` + `0.3·amount`), so 0 and 1 stay; offset adds `0.25·level` (+ `0.2·amount`). Applied after the primary grade, before the tonal wheels. Default all 0 (no effect). |
| `pivot` | number 0…1 | The luma contrast pivots on: a pixel of luma `pivot` keeps its value. Default 0.5. |
| `curves` | object | `master, red, green, blue`: arrays of `[x, y]` points in 0…1, 2…16 points, sorted by x, no duplicate x; endpoints `[0,0]` / `[1,1]` are added when missing. Default identity `[[0,0],[1,1]]`. Sampled as a monotone cubic (`ColorCurveMath`). |
| `hueCurves` | object | `hueVsHue` (y in −180…180 degrees), `hueVsSaturation`, `hueVsLuma` (y in −1…1): `[hueDegrees, delta]` points, 3…16, periodic over hue. Fewer than 3 points means off. Default `[]`. |
| `secondaries` | array (≤ 4) | HSL qualifier plus correction, below. |
| `details` | object | `vignette` 0…1 (0), `vignetteMidpoint` 0…1 (0.5), `vignetteRoundness` −1…1 (0), `vignetteFeather` 0…1 (0.65), `grain` 0…1 (0), `grainSize` 0…1 (0.25), `grainRoughness` 0…1 (0.5). |
| `effects` | object | Stylize effect amounts and their settings, below. |
| `palette` | array of 2…6 `#rrggbb` strings, or null | Ink/paper colors for the print and art effects. Invalid entries drop the whole palette. Default (null): black/white, or `#1a1a1a`/`#f5f5dc` when engraving or crosshatch is on. |
| `lut` | `{ "src": path, "intensity": 0…1 }`, a bare path string, or null | A `.cube` 3D LUT (project-relative path; the inspector's LUT import copies the file into the project). `intensity` defaults to 1. Sampled trilinearly or tetrahedrally (`CubeLUT`). |
| `colorSpace` | string | Always `"rec709"`. |

### Secondaries

```json
{
  "enabled": true,
  "key": {
    "hue":        { "center": 0, "range": 30, "softness": 20 },
    "saturation": { "min": 0, "max": 1, "softness": 0.1 },
    "luma":       { "min": 0, "max": 1, "softness": 0.1 }
  },
  "correction": { "hueShift": 0, "saturation": 0, "luma": 0, "temperature": 0, "tint": 0 }
}
```

- `hue.center` is wrapped to 0…360; `hue.range` (half-width) 0…180, default 180 when missing on read;
  `hue.softness` 0…(180 − range).
- `saturation` / `luma`: `min`, `max` 0…1 (swapped if reversed), `softness` 0…0.5 (default 0.05 on read).
- `correction.hueShift` −180…180 degrees; `saturation`, `luma`, `temperature`, `tint` −1…1.
- A secondary changes pixels only when enabled and at least one correction is non-zero. Entries beyond the fourth
  are ignored. The inspector creates new selections with range 30 / softness 20 and soft ranges of 0.1.

### When a grade draws anything

`ColorGradeParams.isActive`: vignette, grain or any stylize amount above 0 always draws; otherwise, with
`intensity` 0 nothing draws; else any non-zero adjust value, wheel amount/level, non-identity RGB curve, non-zero
hue curve point, active secondary or LUT with non-zero intensity draws. An inactive grade costs nothing in preview
or export.

## Stylize effects (`effects` inside the grade)

Eighteen effects (`HF_COLOR_GRADING_ACTIVE_EFFECT_KEYS`), each switched on by its amount key being above 0. All
keys are 0…1 unless a range is shown. The other keys are that effect's settings. "Applied when added" is
`HF_COLOR_GRADING_EFFECT_APPLY_DEFAULTS`, the values an effect is added with
(the native Effects group currently exposes the amount sliders only; see FEATURES.md).

### Essentials (`essentials`)

| Effect (amount key) | Label | Settings keys (default) | Applied when added from the menu |
| --- | --- | --- | --- |
| `blur` | Blur | — | `blur`: 0.45 |
| `pixelate` | Pixelate | — | `pixelate`: 0.55 |
| `bloom` (range 0…3) | Bloom | `bloomRadius` (8, 1…100) | `bloom`: 0.55, `bloomRadius`: 8 |

### Retro & Glitch (`retro-glitch`)

| Effect (amount key) | Label | Settings keys (default) | Applied when added from the menu |
| --- | --- | --- | --- |
| `chromaBleed` | Chroma Softening | — | `chromaBleed`: 0.55 |
| `tapeDamage` | Tape Damage | `tapeTracking` (0), `tapeNoise` (1), `tapeSpeed` (0.5) | `tapeDamage`: 0.65, `tapeTracking`: 0.55, `tapeNoise`: 0.25, `tapeSpeed`: 0.5 |
| `filmArtifacts` | Film Artifacts | — | `filmArtifacts`: 0.55 |
| `scanlines` | Scanlines | `scanlineCount` (0), `scanlineSoftness` (0) | `scanlines`: 0.35, `scanlineCount`: 0.17, `scanlineSoftness`: 1 |
| `crtCurvature` | CRT Curvature | — | `crtCurvature`: 0.2 |
| `chromaticAberration` | Channel Separation | `chromaticAngle` (0) | `chromaticAberration`: 0.15, `chromaticAngle`: 0 |
| `digitalGlitch` | Digital Glitch | `digitalGlitchColorSplit` (0), `digitalGlitchLineTear` (0), `digitalGlitchPixelate` (0), `digitalGlitchBlockAmount` (0), `digitalGlitchBlockDisplacement` (0), `digitalGlitchBlockOpacity` (0), `digitalGlitchSpeed` (0) | `digitalGlitch`: 0.55, `digitalGlitchColorSplit`: 0.25, `digitalGlitchLineTear`: 0.25, `digitalGlitchPixelate`: 0.15, `digitalGlitchBlockAmount`: 0.5, `digitalGlitchBlockDisplacement`: 0.25, `digitalGlitchBlockOpacity`: 0, `digitalGlitchSpeed`: 0.5 |

### Print (`print`)

| Effect (amount key) | Label | Settings keys (default) | Applied when added from the menu |
| --- | --- | --- | --- |
| `halftone` | Halftone | `halftoneSize` (0) | `halftone`: 0.94, `halftoneSize`: 0.36 |
| `twoInkPrint` | Two-Ink Print | `twoInkPrintSize` (0) | `twoInkPrint`: 1, `twoInkPrintSize`: 0.42 |
| `dither` | Ordered Dither | `ditherSize` (0) | `dither`: 1, `ditherSize`: 0.5 |
| `monoScreen` | Mono Screen | `monoScreenSize` (0), `monoScreenAngle` (0), `monoScreenSpread` (0), `monoScreenShape` (0, 0…4), `monoScreenInvert` (0) | `monoScreen`: 1, `monoScreenSize`: 0.35, `monoScreenAngle`: 0.25, `monoScreenSpread`: 0.3, `monoScreenShape`: 0, `monoScreenInvert`: 0 |

### Art (`art`)

| Effect (amount key) | Label | Settings keys (default) | Applied when added from the menu |
| --- | --- | --- | --- |
| `ascii` | ASCII | `asciiSize` (0.0658), `asciiInvert` (0), `asciiStyle` (0, 0…7), `asciiColor` (1), `asciiRotation` (0) | `ascii`: 1, `asciiSize`: 0.06578947368421052, `asciiInvert`: 0, `asciiStyle`: 0, `asciiColor`: 1, `asciiRotation`: 0 |
| `engraving` | Engraving | `engravingSpacing` (0.4118), `engravingMinThickness` (0.2), `engravingMaxThickness` (0.4571), `engravingAngle` (0.25), `engravingContrast` (0.4667), `engravingSharpness` (0.59), `engravingWave` (0.2), `engravingWaveFrequency` (0.2222) | `engraving`: 1, `engravingSpacing`: 0.4117647058823529, `engravingMinThickness`: 0.2, `engravingMaxThickness`: 0.4571428571428572, `engravingAngle`: 0.25, `engravingContrast`: 0.4666666666666667, `engravingSharpness`: 0.59, `engravingWave`: 0.2, `engravingWaveFrequency`: 0.2222222222222222 |
| `crosshatch` | Crosshatch | `crosshatchSpacing` (0.28), `crosshatchThickness` (0.25), `crosshatchAngle` (0.25), `crosshatchContrast` (0.3333), `crosshatchEdges` (0.5), `crosshatchLineWeight` (0), `crosshatchWave` (0.33), `crosshatchWaveFrequency` (0.2222) | `crosshatch`: 1, `crosshatchSpacing`: 0.28, `crosshatchThickness`: 0.25, `crosshatchAngle`: 0.25, `crosshatchContrast`: 0.3333333333333333, `crosshatchEdges`: 0.5, `crosshatchLineWeight`: 0, `crosshatchWave`: 0.33, `crosshatchWaveFrequency`: 0.2222222222222222 |
| `kuwahara` | Kuwahara Paint | `kuwaharaRadius` (0.1429), `kuwaharaSharpness` (0.3125), `kuwaharaSaturation` (0.5) | `kuwahara`: 1, `kuwaharaRadius`: 0.14285714285714285, `kuwaharaSharpness`: 0.3125, `kuwaharaSaturation`: 0.5 |

Blur, bloom and Kuwahara run extra neighbourhood passes, and every stylize effect works in pixel units, so the
result depends on the frame size. Preview and export both grade at the size the clip is drawn
(`exportGradeSize`: the media contain-fitted into the clip box), which keeps their pixels the same.

## Presets

`preset` names one of these (`HF_COLOR_GRADING_PRESETS` = grade presets followed by effect presets). A preset is
the contract defaults overlaid with its own `intensity`, `adjust`, `details` and `effects`; keys written on the
grade override it.

### Grade presets

| id | Label | intensity |
| --- | --- | --- |
| `neutral` | Neutral | 1 |
| `warm-daylight` | Warm Daylight | 1 |
| `clean-studio` | Clean Studio | 1 |
| `skin-soft` | Skin Soft | 1 |
| `food-pop` | Food Pop | 1 |
| `night-lift` | Night Lift | 1 |
| `muted-editorial` | Muted Editorial | 1 |
| `vintage-wash` | Vintage Wash | 1 |
| `mono-clean` | Mono Clean | 1 |
| `mono-fade` | Mono Fade | 1 |
| `soft-boost` | Soft Boost | 1 |
| `bright-pop` | Bright Pop | 1 |
| `deep-contrast` | Deep Contrast | 1 |

### Effect presets

| id | Label | Stylize effects it turns on |
| --- | --- | --- |
| `creator-camcorder` | Creator Camcorder | chromaBleed |
| `vhs-playback` | VHS Playback | chromaBleed, tapeDamage, scanlines, chromaticAberration, digitalGlitch |
| `home-movie-8mm` | 8mm Home Movie | filmArtifacts |
| `editorial-halftone` | Editorial Halftone | halftone |
| `two-ink-print` | Two-Ink Print | twoInkPrint |

## Palettes (`HF_COLOR_GRADING_PALETTES`)

Offered for the print/art effects; stored as the grade's `palette` array.

| id | Label | Group | Colors |
| --- | --- | --- | --- |
| `noir` | Noir | Classic | #000000 #ffffff |
| `ink-paper` | Ink & Paper | Classic | #1a1a2e #f5f5dc |
| `terminal` | Terminal | Classic | #001100 #00ff00 |
| `amber-glow` | Amber Glow | Classic | #1a0f00 #ffcc00 |
| `handheld-green` | Handheld Green | Classic | #0f380f #306230 #8bac0f #9bbc0f |
| `golden-hour` | Golden Hour | Mood | #1a1205 #4a3510 #8b6914 #d4a017 #fff8dc |
| `deep-sea` | Deep Sea | Mood | #0a1628 #1a3a5c #2d6187 #5ba4c9 #a8dce8 |
| `arctic-night` | Arctic Night | Mood | #0a0a14 #1a2a4a #3a5a8a #6a9aca #cae8ff |
| `synthwave` | Synthwave | Mood | #120458 #7b2cbf #e040fb #ff6ec7 #fff59d |
| `vaporwave` | Vaporwave | Mood | #1a0a2e #3d1a5c #ff71ce #01cdfe #fffb96 |
| `forest` | Forest | Mood | #1a2e1a #2d4a2d #4a7c4a #7ab37a #c8e6c8 |
| `sepia` | Sepia | Mono | #1a1610 #3d3020 #6b5a40 #a89070 #e8dcc8 |
| `blueprint` | Blueprint | Mono | #001830 #003060 #0050a0 #0080e0 #e0f0ff |
| `warm-print` | Warm Print | HyperFrames | #17121a #824c50 #e09873 #f7ddb1 |
| `electric-ink` | Electric Ink | HyperFrames | #080717 #3c185f #7e2278 #d9339f #ff6b66 #aafae0 |

## Example

```json
{
  "id": "fx-grade", "effectId": "color-grading", "enabled": true,
  "parameters": {
    "enabled": true, "preset": "warm-daylight", "intensity": 0.8,
    "adjust": { "contrast": 0.12, "saturation": -0.05 },
    "wheels": { "midtones": { "hue": 187, "amount": 0.3, "level": 0 } },
    "curves": { "master": [[0, 0], [0.4, 0.45], [1, 1]] },
    "hueCurves": { "hueVsSaturation": [[0, 0], [120, 0.5], [240, 0]] },
    "secondaries": [],
    "details": { "vignette": 0.2, "grain": 0.1 },
    "effects": { "scanlines": 0.35, "scanlineCount": 0.17, "scanlineSoftness": 1 },
    "palette": null,
    "lut": { "src": "luts/film.cube", "intensity": 0.7 },
    "colorSpace": "rec709"
  }
}
```

## Sources

- Contract and preset values: recorded reference values in the panels lane's `grading.json`.
- Swift: `Sources/MpvfxColor/ColorGradeParams.swift` (normalization and limits), `GradeShader.swift`,
  `ColorGradeRenderer.swift`, `CubeLUT.swift`, `Sources/MpvfxPanels/ColorGrading.swift` (editing model and
  presets), `Sources/MpvfxRuntime/Export/ExportColorGrade.swift`.
## Colour key

An enabled clip effect with `effectId: "color-key"` stores this versioned object:

```json
{"v":1,"kind":"chroma","color":[0,1,0],"similarity":0.1,"smoothness":0.1,"spill":0}
```

`v` and `kind` are required. The other fields are optional and are omitted when they
have the displayed defaults. RGB and all three amounts are finite numbers in `0...1`.
The matte is `smoothstep(similarity, similarity + smoothness, distance)` where distance
is Euclidean distance in BT.709 Cb/Cr coordinates. It multiplies the source alpha.
Spill suppresses the key colour's own hue in the graded colour: for the key's strongest
channel (green, else blue, else red) it removes the amount by which that channel exceeds the
larger of the other two; at `1` it removes all such excess without changing neutral pixels. Preview and export consume the same RGBA result.

Objects with an unknown `v` or `kind` remain in the project unchanged but are not drawn.
They do not change `schemaVersion`, which remains `1`.
