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

## Speech to captions

- `TranscriptionService` turns a clip's own sound over its trimmed range into words with source-media millisecond
  times, on the device only (there is no network path). The engine decodes the range to 16 kHz mono 16-bit WAV
  pieces of at most 50 s in `.studio-render-tmp/transcribe-<uuid>/` inside the project, removed when the job ends,
  fails or is cancelled. `planTranscriptCaptions` (`NativeTranscriptCaptionPlan.swift`) maps the words through the
  clip's start, trim and speed into sequence cues as one undoable document step; the platform adapters are
  `MacSpeechTranscriptionService` (Speech framework, on-device only) and `WindowsSpeechTranscriptionService`
  (in-process SAPI 5 from the WAV file), and Linux reports `platformHasNoOnDeviceRecognizer`. State and gaps are in
  the Captions row of [STATUS.md](STATUS.md).

## Captions (SRT)

- `sequence.captions` holds cue times as whole milliseconds, the unit SRT writes, so an SRT import keeps its exact
  times instead of rounding them to frames (`Sources/MpvfxShared/Project/NativeCaptionTrack.swift`). The field is
  optional: documents written before captions existed have no `captions` key, open unchanged and save without one,
  so the schema version stays 1.
- The SRT format has no standard; the reader and writer follow two published descriptions: the Library of Congress,
  "SubRip Subtitle format (SRT)", fdd000569, <https://www.loc.gov/preservation/digital/formats/fdd/fdd000569.shtml>
  (last significant update 2025-05-27; read 2026-10-21), and Matroska, "Subtitles", section "SRT Subtitles",
  <https://www.matroska.org/technical/subtitles.html> (read 2026-10-21). Both describe a counter line, a timing line
  `HH:MM:SS,mmm --> HH:MM:SS,mmm`, the text lines and a blank line; the LoC page notes that SRT has no character
  encoding standard (SubRip writes Windows-1252 by default, or UTF-8 or UTF-16 with or without a byte order mark).
- Decisions: import reads UTF-8 (with or without a byte order mark) and UTF-16 with one, and refuses any other
  encoding with the line of the first byte that is not text rather than guess a code page; a dot is accepted in place
  of the comma; overlapping cues are refused (the document allows no overlap); a cue must end after it starts.
  Export writes UTF-8 without a byte order mark, CRLF line endings and a comma, through the durable write path.
  A cue's text may not hold a blank line, `-->`, a control character other than a tab, or U+FFFD (what the
  document reader makes of an invalid UTF-8 byte), so every stored cue exports and reads back unchanged.

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
