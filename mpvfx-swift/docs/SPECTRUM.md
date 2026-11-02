# Live spectrum for the audio FX rack

This note describes the spectrum analyser for the audio FX rack: what it measures, where the work runs, how a result is handed to the UI, and what is left out.

Code: `Sources/MpvfxAudioGraph/SpectrumAnalyzer.swift` (analysis) and `Sources/MpvfxAudioGraph/FxSpectrumRing.swift` (hand-off to the UI).
Tests: `Tests/MpvfxAudioGraphTests/SpectrumTests.swift`.

Status: the analyser, the ring and the tap in the chain processor are in place. The tap analyses the input and output of one watched module (`GraphAudioSource.watchSpectrum`) and the rack reads them for the heard time (`GraphAudioSource.fxSpectrum`). Drawing the spectrum behind the EQ curve belongs to the parametric EQ (#207).

## What is analysed

- One `SpectrumAnalyzer` looks at one point in a chain. Use two, at the chain input and output, to show what an effect changed.
- `push(_:)` takes planar channels and averages them to mono. Non-finite samples count as 0. Channels of unequal length use the channels present at each sample.
- Window: 4096-point FFT (`fftSize`) with a periodic Hann window.
- Hop: 2048 samples, so consecutive windows overlap by half. `push` returns true when at least one new spectrum was produced. Before 4096 samples have arrived the window is padded with silence.
- Bands: 60 bands (`bandCount`), 1/6 octave each, from 20 Hz to about 20 kHz. Band `i` runs from `20 * 2^(i/6)` to `20 * 2^((i+1)/6)` Hz; `bandCenter(_:)` gives its geometric centre.
- Band level: the power of the FFT bins whose frequency falls in the band is summed. A band narrower than one bin (the lowest ones) instead interpolates between the two bins around its centre, so it does not read empty. Bands above Nyquist stay at the floor.
- Scale: the amplitude scaling makes a full-scale sine read about 0 dBFS. Levels are clamped to -90 (floor) and 0 (cap).
- Smoothing: a one-pole filter on the dB values with a time constant of about 100 ms. The coefficient is `1 - exp(-hop / (sampleRate * 0.1))`, so the look is the same at different rates. The sample rate is fixed when the analyser is made; make a new one if it changes.

## Where it runs

- All access belongs to the feeder thread. The analyser adds no thread and takes no lock.
- The FFT tables, window, scratch buffers, band table and smoothing state are all created in `init`. `push` allocates nothing of its own.
- On the feeder, read the levels with `withUnsafeBands` and publish them straight into the ring. `bands` is an allocating copy for tests and tools.

## How it reaches the UI

- `FxSpectrumRing` is a ring of 16 spectra with one writer (the feeder) and any reader (the UI). It is built like `FxMeterRing`; each chain's `FxChainMeters` (in `FxMeters.swift`) holds one ring for the watched module's input and one for its output.
- The bands live in preallocated storage. `publish(frame:bands:)` copies into the next slot, then advances an atomic count with release ordering. It takes no lock and never waits on the reader.
- Each spectrum is tagged with the frame it was taken for, as meter readings are. The reader calls `reading(atOrBefore:)` and gets the newest spectrum for a frame no later than the one asked for, or nil when none that recent is held.
- The reader copies a slot, then checks that the writer has not come back to it. If it has, the reader returns nil rather than a mix of two analysis passes. The reader polls at the UI rate (30 Hz is enough); the 2048-sample hop is about 21 spectra per second at 44.1 kHz.
- If the UI stops reading, nothing builds up: old slots are overwritten in place.

## Out of scope

- Dynamic EQ driven by the spectrum.
- Linear-phase modes.
- Loudness measurement in LUFS. The spectrum is a picture of level by frequency, not a loudness meter.
- Spectra of several modules at once. One module is watched at a time, because each analysis is a 4096-point transform per 2048 frames on the feeder.

## Checks

`SpectrumTests.swift` covers: a 1 kHz sine peaking within a sixth of an octave, the peak following the frequency across the range, silence reading the floor, band coverage from 20 Hz to 20 kHz, a spectrum being reported only once per hop, all bands staying in range, and channels being summed to mono.

The ring's write and read behaviour is covered by `FxSpectrumRingTests.swift`, and the tap by `AudioMeterTests.testTheWatchedModulesSpectrumPeaksAtTheSine` and the allocation test in the same file.
