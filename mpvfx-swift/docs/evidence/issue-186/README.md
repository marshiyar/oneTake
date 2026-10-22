# Design wording captures (#186)

Native Core Graphics offscreen renders of the Design inspector, in dark and light, at the 409 px inspector width
used in 1440×900 and 1280×800 windows. These are panel renders, not full application screenshots. Each comparison
has the baseline panel at left and the updated panel at right, with Text, Transform and Grade stacked vertically.

- [Dark, 1440×900](comparison-dark-1440x900.png)
- [Light, 1440×900](comparison-light-1440x900.png)
- [Dark, 1280×800](comparison-dark-1280x800.png)
- [Light, 1280×800](comparison-light-1280x800.png)

The capture test also renders Media (with crop active) and Effects in every size/appearance combination. Set
`MPVFX_WORDING_CAPTURES` to an output directory and run `DesignWordingTests.testCaptureDesignWording` in the
MpvfxPanelsTests bundle. The before set was rendered from the unchanged base source using the same harness, then
the source edits were restored and rebuilt for the after set. No snapshot goldens were changed.
