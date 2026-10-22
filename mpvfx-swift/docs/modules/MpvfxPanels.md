# MpvfxPanels module memory

## Design wording (#186, 2026-10-21)

Rotation about Z is edited once, in Transform's existing Rotation row. The duplicate Roll row was removed from
3D transform; the cube still reads that same rotation value when rendering its pose. Depth, Tilt X, Tilt Y and
Perspective remain in the 3D disclosure, with the same parameter IDs, reset commands and keyframe behavior.

Primary and secondary correction call `temperature` Temperature. Display casing is sentence case; named grade
presets keep their catalog names. Icon controls keep word labels as their tooltip/accessibility source.
