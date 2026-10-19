# Implementation notes

Decisions in `MpvfxShared` and `MpvfxRuntime` that a reader of the code would not guess, and the places where the
behaviour is fixed on purpose because saved data depends on it.

## Data formats kept stable on purpose

- `.studio/project.json` is schema version 1 in canonical JSON (keys sorted by UTF-16 code unit, 2-space indent).
  `mediaEngine` is written as `"native"`; `"ffmpeg"` (a legacy value written by older versions) and a missing field are read as the
  native timeline, so the first save after opening an older project migrates it and changes nothing else.
- Element assets whose clips carry no `text` are layers from an earlier version of the editor that the renderer
  cannot draw. They stay in the document byte for byte, preview and export skip them
  (`NativeProjectDocument.isUndrawnElementClip`), and the editor shows one notice when such a project opens.
- Transaction journals live in `.hyperframes/studio-transactions/`; the folder name and journal byte format are
  fixed so an interrupted write from an earlier version is still recovered.
- Some JavaScript string semantics are kept where they decide data: `jsToLowerCase`, `jsTrim`,
  `jsEncodeURIComponent` (`Sources/MpvfxShared/Media/JSStringParity.swift`) and the locale-independent sort used
  for clip IDs (`NativeJSONValue.swift`). Changing them changes IDs, paths or sort order in saved documents.
- Export resolution: an `in`-style lookup of `EXPORT_RESOLUTION_PRESETS` also accepts inherited
  `Object.prototype` keys (for example `"constructor"`); this is kept as `ExportResolutionChoice.objectPrototypeKey`
  (`ExportPolicy.swift`) so saved render settings naming one read the same.

## Edge cases

- Numbers: source-time math runs in overflow-checked Int64; a value that does not fit throws
  `NativeSourceTimeRangeError` and the edit is rejected (`NativeSourceTime.swift`).
- Baked keyframe samples (gap 2): a number track read outside its samples returns NaN (`BakedKeyframeEngine.swift`).
- Library payloads keep unknown keys and key order and re-encode them verbatim, but a command with an unknown
  `type` throws `UnknownType` (`Sources/MpvfxShared/Library/Library.swift`).
- `preferredMediaImportMimeType` looks the extension up in a dictionary, so an extension such as `constructor`
  returns nil (`MediaImportPolicy.swift`).
- File copies never try a reflink (FICLONE); they are always a byte copy (`PublishFile.swift`).
- Timestamps parsed from journals accept only the `toISOString` format the store writes (`FileTransaction.swift`).
- `localeCompare` is a fixed code-unit comparison, so clip ordering does not depend on the user's system locale;
  the strings where ICU would differ are listed in `LocaleCompareFixtureTests.swift`.
- The velocity ease fitter belongs to the stage's gesture commit (`MpvfxPlayer/GestureRecording.swift`), so the
  shared gesture recording tests do not cover it.

## Platform gaps

- Filesystem code goes through `NativeFile` (`Projects/NativeFile*.swift`): POSIX descriptors on Linux and macOS,
  Win32 handles on Windows (built and tested on Windows only by the CI mirror, `docs/STATUS.md` row "Windows").
  On Windows: `FileInfo.dev`/`ino` are the volume serial number and file index, `ctimeNs` is ChangeTime; directories cannot be fsynced (callers already tolerate EISDIR);
  the library lock is a share-mode-0 handle that refuses reparse points; mkdtemp is emulated (no 0700 mode);
  Explorer file drops arrive only on release (WM_DROPFILES), so the drop zone shows no hover state while dragging.
- Importing a large file is slow in debug builds: the in-repo SHA-256 hashes a 501 MiB import in about 280 s
  (`LibraryServiceTests`). Release builds are much faster but not measured.

## Test fixtures

JSON fixtures under `Tests/**/Fixtures/` are recorded reference values, captured once and kept as data. Golden-value
tests compare the Swift code against them; a recorded value is never changed to make a test pass. The generators
are not part of this repository.
