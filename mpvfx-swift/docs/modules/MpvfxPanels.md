# MpvfxPanels module memory

## Design wording (#186, 2026-10-21)

Rotation about Z is edited once, in Transform's existing Rotation row. The duplicate Roll row was removed from
3D transform; the cube still reads that same rotation value when rendering its pose. Depth, Tilt X, Tilt Y and
Perspective remain in the 3D disclosure, with the same parameter IDs, reset commands and keyframe behavior.

Primary and secondary correction call `temperature` Temperature. Display casing is sentence case; named grade
presets keep their catalog names. Icon controls keep word labels as their tooltip/accessibility source.

## Animated curves and secondaries (#228, 2026-11-02)

Grade curve points and secondary settings animate as numeric tracks: `grade.curves.<channel>.<point>.<x|y>`,
`grade.hueCurves.<channel>.<point>.<x|y>` and `grade.secondaries.<n>.<field>`. The keyframe engine evaluates numbers
only (number, vec2, rgba), not point lists, so a curve animates per coordinate and a secondary per setting.

A track belongs to a point or secondary by position. While anything in a curve or in the secondaries is animated, the
point count of that curve and the number of secondaries are fixed: add, remove and reset are refused until the
stopwatch is turned off, which keeps the playhead's values. A track whose point or secondary no longer exists is
ignored when the grade is read. One stopwatch keys all points of the shown curve together; secondary settings key one
by one. Preview and export read the tracks through the same path, so export matches preview frame for frame
(`ExportPreviewMatchTests`).
