# Memory

## Why this exists

A user on macOS watched MpVFX climb to about 120 GB of memory during a long editing session. The cause was not one
big cache. It was thousands of small buffers that were never freed:

- At the time, every place that read raw frames or audio from the external decoder subprocess older versions of
  the app used (preview decoding, the audio stream, export grading) read the pipe with `FileHandle.read`. Each read returns a new `Data` of about 64 KB, and on macOS that is
  an autoreleased object.
- Autoreleased objects are freed when the surrounding autorelease pool drains. A pool normally drains when code
  returns to the run loop. Our decoders, the audio feeder, export and the Metal grader run long `while` loops on
  background threads that never return to a run loop, so nothing ever drained. Every byte ever read stayed alive
  until the loop ended, which for playback means until the app quit.

Linux never showed this because Foundation there has no autorelease pools; the same code freed each chunk at once.

The app no longer runs FFmpeg: the in-house media engine (a prebuilt library loaded in-process, `binaries.lock`) hands decoded frames
and samples over in memory, so no pipe is read any more. The pool and budget rules below still apply to every long
background loop.

## What changed

- **No pipe reads remain.** The subprocess frame and audio streams, and `PipeRead` that read their pipe straight
  into the destination array, are deleted; the engine hands decoded frames and samples over in memory instead.
- **Long loops drain a pool every step.** `withAutoreleasePool` (a real pool on Apple platforms, a plain call on
  Linux) wraps each step of: the preview decode lane (one decoded frame), the audio feeder (one block), the live
  audio graph updater (one rebuild), export grading (one frame), the preview grader (one grade) and Metal grading
  (one command buffer). The decode queues also drain per work item.
- **Every cache has a byte budget sized from the machine.** `MemoryBudget`:
  - decoded preview frames: 10% of RAM, at most 2 GB, at least 256 MB (`MPVFX_PREVIEW_CACHE_MB` overrides it);
  - graded preview pictures: 2% of RAM, 64 to 256 MB;
  - media bin thumbnails, filmstrips: 2% of RAM, 64 to 256 MB;
  - idle Metal grade targets: at most 6 sizes and 256 MB.
  Least recently used entries go first.
- **Memory pressure gives memory back.** `MemoryPressureMonitor` listens to macOS memory warnings. On a warning the
  frame cache drops to half its budget, thumbnails trim to half, the grader keeps only its most recent picture, and
  the Metal pool empties. On a critical warning the caches empty completely. Views re-request what they need.
- **Removed clips and closed projects release their memory.** When a clip leaves the timeline its cached frames and
  graded pictures are freed and its decoder ends. Opening another project frees every decoder and cache of the old one.
- **Measuring it.** `ResidentMemory.footprintBytes()` reads `phys_footprint` on macOS (the number Activity Monitor
  shows) and `VmRSS` on Linux.

## Behavior change a user may notice

- On a machine with less memory, less decode-ahead and scrub history is kept, so scrubbing far back may decode again
  instead of showing a cached frame. On a 16 GB Mac the frame cache is about 1.6 GB, more than the old fixed 384 MB.
- After a macOS memory warning, the next few draws may show a stand-in frame or an ungraded frame for a moment while
  the caches refill.
- Thumbnails of media not looked at recently may redraw after a short delay.

## Risks

- Budgets are estimates of picture bytes. Allocator overhead and the media engine's own working memory (decoder state) are not counted, so the real
  footprint sits somewhat above the sum of the budgets.
- Dropping graded pictures under budget pressure costs a re-grade (a GPU pass on macOS, CPU time on Linux) when that
  clip is shown again.
- The macOS-only paths (Metal pool budget, the system memory-pressure source, `phys_footprint`) are exercised only on
  the Mac CI runner.

## How to check it

- Tests: `MemoryBudgetTests` (budgets, footprint reader, pressure observers, pipe reader, pool wrapper),
  `PreviewMemoryTests` (frame cache budget and eviction, pressure, removed clips, grader budget, a long
  play / scrub / grade / reverse session, and a 600-frame read loop whose footprint must stay flat),
  `MetalPoolMemoryTests` (Metal pool within budget, emptied on pressure).
- Smoke run: `MPVFX_SMOKE_MEMORY=<rounds>` launches the app, drives the open project through rounds of play, scrub,
  grade edits, reverse and replay, simulates a memory warning halfway, and exits 0 (`PASS`) or 4 (`FAIL`) with a
  footprint report. `MPVFX_SMOKE_MEMORY_LIMIT_MB` sets the allowed growth beyond what the caches hold (default 256),
  `MPVFX_SMOKE_MEMORY_MEDIA` puts media files (`:`-separated) on the timeline first, and
  `MPVFX_SMOKE_MEMORY_VERBOSE=1` prints every round.
