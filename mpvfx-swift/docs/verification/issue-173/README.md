# Design inspector legibility (#173)

These are native Core Graphics renders of the actual inspector draw path, at the fitted panel width for 1440×900 and 1280×800 viewports. Each sheet compares the unchanged inspector on the left with this change on the right: wheels, curves/hint/Finish, and an active effect. The new `InspectorLegibilityTests` additionally renders Grade defaults, primary controls, open scopes, effect catalog, Transform and Media in both appearances at both viewport sizes.

- [1440×900 dark](dark-1440x900.png)
- [1440×900 light](light-1440x900.png)
- [1280×800 dark](dark-1280x800.png)
- [1280×800 light](light-1280x800.png)

The before images were rendered with only the panel drawing changes reversed; additive tokens and the same test fixture stayed in place. The recorder fails against the original drawing paths and passes after the change. Set `MPVFX_SNAPSHOT_DIR` when running `MpvfxPanelsTests.InspectorLegibilityTests` to regenerate individual PNGs on macOS.

Review: group titles remain 12 px, section headings are 11.5 px, hints/values are at least 11 px. Panel geometry and the wheel/curve editing layout stay unchanged. The narrow three-wheel layout already truncates Amount; the larger font preserves truncation rather than overlapping adjacent fields. The separate wording work in #186 overlaps these labels. These are panel renders, not full application screenshots; media preview rendering and GPU output were not exercised.

Validation: strict builds of `MpvfxPanelsTests` and `MpvfxThemeTests` pass. Both new inspector tests and all eight `VisualSpecTests` pass. The complete Panels suite runs 423 tests and retains the pristine baseline's 63 failed assertions with identical failure signatures. The full Theme suite has three existing assertions concerning raw colors and raw-error wording in untouched files. The required `scripts/check.sh` reproduces the two existing copyright-block failures and cannot build/test using its default sandboxed cache location. The crash-construct ratchet reports existing baseline excesses in MaskCoverageRasterizer, WindowsSpeechTranscriptionService and ThemeTokens; this change introduces no crash constructs.

Integration: held drafts #499 (target sizes) and #502 (wording) touch these same inspector drawing files and need reconciliation when integrated. This change does not implement their target-size or wording features.
