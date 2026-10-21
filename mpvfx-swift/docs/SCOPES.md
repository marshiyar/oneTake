# Video scopes

What the scopes measure, the standards they follow, and the conventions that are the product's own choice.
The engine is `Sources/MpvfxScopes` (Foundation only, no UI); the tests are `Tests/MpvfxScopesTests`.

## Sources

Every number below comes from these documents (each fetched 2026-10-21) or is derived from them by the formula given.

| Document | Link | Used for |
| --- | --- | --- |
| Rec. ITU-R BT.709-6 (06/2015) | <https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.709-6-201506-I!!PDF-E.pdf> | item 1.2 transfer function; item 3.2 luma `0.2126 R' + 0.7152 G' + 0.0722 B'`; item 3.3 `CB = (B' - Y') / 1.8556`, `CR = (R' - Y') / 1.5748`; item 3.4 quantisation `D = INT[(219 E + 16) 2^(n-8)]`; item 4.6 10-bit black 64, nominal peak 940 |
| Rec. ITU-R BT.601-7 (03/2011) | <https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.601-7-201103-I!!PDF-E.pdf> | § 2.5.1 luma `0.299 R' + 0.587 G' + 0.114 B'`; § 2.5.2 divisors 1.772 and 1.402 |
| Rec. ITU-R BT.2020-2 (10/2015) | <https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.2020-2-201510-I!!PDF-E.pdf> | Table 4 luma `0.2627 R' + 0.6780 G' + 0.0593 B'`, divisors 1.8814 and 1.4746 |
| Rec. ITU-R BT.471-1 (07/1986) | <https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.471-1-198607-I!!PDF-E.pdf> | colour-bar nomenclature: 100/0/75/0 bars carry the colours at 75 % of R'G'B', 100/0/100/0 at 100 %; bars in descending luminance |
| Rec. ITU-R BT.1729-0 (04/2005) | <https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.1729-0-200504-I!!PDF-E.pdf> | the HDTV bar pattern (100 % yellow to blue, white bar at 100 % luminance) |
| Rec. ITU-R BT.470-6 (11/1998) | <https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.470-6-199811-S!!PDF-E.pdf> | § 2.5 NTSC `E'I = -0.27 (B'-Y') + 0.74 (R'-Y')`, `E'Q = 0.41 (B'-Y') + 0.48 (R'-Y')`; Fig. 4 axes |

## What is measured

- **Input:** an RGBA8 frame with straight alpha, rows top to bottom, non-linear (gamma-encoded) full-range R'G'B', the bytes the preview draws. BT.709 defines luma from these non-linear components (item 3.2), so nothing is linearised. Pixels with alpha 0 are not part of the picture and are skipped; every other pixel counts once.
- **Matrix:** BT.709 by default (projects grade in `rec709` and export tags BT.709); BT.601 and BT.2020 are selectable. Kg = 1 - Kr - Kb, CB divisor 2(1 - Kb), CR divisor 2(1 - Kr), which reproduce the published divisors (`ScopeStandardTests.testDivisorsMatchThePublishedRecommendations`).
- **Luma:** fixed point, weights rounded to 1/65536 and the green weight taking the remainder, so the three sum to exactly 65536 and a neutral grey's luma equals its code value.
- **Levels:** 256 per channel, level 0 black, 255 the 8-bit peak.
- **Waveform:** per column, counts of Y', R', G', B' at each level. Columns: 512 across the frame (fewer when the frame is narrower). RGB overlay and RGB parade read the R', G', B' planes.
- **Histogram:** the waveform summed over its columns, per plane.
- **Vectorscope:** a square grid of 2r + 1 bins (r = 128) over CB, CR = -0.5...+0.5, centre bin achromatic, `col = r + round(2 r zoom CB)`, `row = r - round(2 r zoom CR)` (+CR up, +CB right). Zoom 1 to 8; samples beyond the zoomed grid are counted as off-scale, never piled on the edge.
- **Clipping:** samples at level 0 and 255 per plane, and per waveform column (the clipping marks).
- **Density:** every pixel up to 1920 x 1080 samples; larger frames are point-sampled on a uniform grid (a 3840 x 2160 frame reads every second pixel of every second row: 1920 x 1080 samples). Samples are never averaged, so a clipped pixel stays clipped.

## Scales

- **Percent:** 0 (black) to 100 (nominal peak); lines every 10, labels every 20.
- **10-bit:** the BT.709 10-bit code of the value, `INT[876 E + 64]`: black 64, nominal peak 940; lines at 64, 128, 256 ... 896 and 940, labels 64, 256, 512, 768, 940. Full-range R'G'B' input never goes below 64 or above 940 on this scale.

## Vectorscope references

Derived from the matrix, never typed in (`ScopeTargets`):

- **Targets:** the six coloured bars at 75 % and 100 % (BT.471-1). BT.709 100 % positions (CB, CR): R (-0.1146, +0.5000), Yl (-0.5000, +0.0458), G (-0.3854, -0.4542), Cy (+0.1146, -0.5000), B (+0.5000, -0.0458), Mg (+0.3854, +0.4542); 75 % targets are at exactly 3/4 of those (the matrix is linear).
- **Skin-tone line:** the NTSC +I axis, the colours with `E'Q = 0` and `E'I > 0` (BT.470-6 § 2.5): `(B'-Y') : (R'-Y') = -0.48/0.41 : 1`. In the BT.709 CB/CR plane that is **134.8 degrees** counter-clockwise from +CB (BT.601: 132.8, BT.2020: 132.5). The often quoted 123 degrees is the same axis in the composite U/V plane (BT.470-6 Fig. 4), whose axes carry the weights 0.493 and 0.877 instead of 1/1.8556 and 1/1.5748; drawing 123 degrees on a component scope puts the line about 12 degrees off.

## False colour (product convention)

No standard defines false-colour bands. MpvfxScopes uses these, on Y' (`FalseColor.bands`):

| Band | Y' range | Colour |
| --- | --- | --- |
| Crushed | 0 to 2 % | purple |
| Near black | 2 to 10 % | blue |
| Middle grey | 35.9 to 46.5 %: the BT.709 transfer function of 18 % reflectance, plus or minus 1/3 stop | green |
| Skin | 52.6 to 67.1 %: one stop over middle grey (36 %), plus or minus 1/3 stop | pink |
| Near clip | 90 to 98 % | yellow |
| Clipped | 98 to 100 % | red |

Levels between bands show the pixel's own luma as grey, so the picture stays readable.

## Speed

`MpvfxScopes` is compiled with `-O` in debug builds too (`Package.swift`): its per-pixel loop is about 9 times slower unoptimised. Rows are split across up to 8 threads (one per 131 072 samples), each with its own counters, merged at the end; the result does not depend on the thread count (`ScopeEngineAccuracyTests.testTheNumberOfWorkersDoesNotChangeTheResult`).

Budget: a full-density 1080p frame in at most 25 ms (`ScopeEngineBudgetTests`). Measured 2026-10-21 on a shared 4-vCPU Intel Xeon @ 2.10 GHz Linux machine with other builds running (load average 3.2): 12.7 ms median at 1080p, 13.8 ms at 2160p (sampled to 1080p).

The GPU renderers (`ColorRendering`: Metal, Vulkan, Direct3D 11) run grade jobs; a scope needs counting with atomics and a job type of its own on each host, so the scopes run on the CPU.

<!-- markdownlint-disable-file MD043 -- the required-headings rule has no heading list configured, so any heading fails it -->
