# Live spectrum for the audio FX rack

This note describes the live spectrum shown for each effect chain in the audio FX rack. It covers what is measured, where the work runs, how the result reaches the screen, and what is left out.

Code: `Sources/MpvfxAudioGraph/SpectrumAnalyzer.swift` and `Sources/MpvfxAudioGraph/FxMeters.swift`.
Tests: `Tests/MpvfxAudioGraphTests/SpectrumTests.swift`.

## What is analysed

- Two curves per chain: the chain input and the chain output, so the user can see what an effect changed.
- Each curve is analysed from the mono sum of the channels at that point.
- Window: 4096-point FFT with a Hann window.
- Hop: 2048 samples, so consecutive windows overlap by half.
- Bands: 1/6-octave bands from 20 Hz to 20 kHz. FFT bins are grouped into the band that contains their centre frequency.
- Level: each band is shown in dBFS on a fixed range from -90 to 0. Anything below -90 is clamped to -90.
- Smoothing: a one-pole filter on the band levels, with a time constant of about 100 ms. The coefficient is derived from the hop size and the sample rate, so the look stays the same at different rates.

## Where it runs

- The analysis runs on the feeder thread, the same thread that already feeds audio through the chain. It does not add a thread.
- It does no allocation and takes no lock. The FFT plan, window, scratch buffers, band table and smoothing state are all created up front, when the chain is set up or the sample rate changes.
- Samples are collected into a fixed ring. When 2048 new samples have arrived, one window is analysed. If the feeder is busy, the analyser drops old input rather than wait.

## How it reaches the UI

- Each chain owns a fixed-size slot of band values. The slot sits next to the module meter rings in `Sources/MpvfxAudioGraph/FxMeters.swift`.
- The feeder writes the slot with lock-free stores. It never waits on the reader.
- The UI reads the slot at 30 Hz. It always gets a complete set of bands from one analysis pass, never a mix of two.
- If the UI stops reading, nothing builds up: the slot is overwritten in place.

## Out of scope

- Dynamic EQ driven by the spectrum.
- Linear-phase modes.
- Loudness measurement in LUFS. The spectrum is a picture of level by frequency, not a loudness meter.
- Per-module spectra. Only the chain input and output are analysed.

## Checks

`Tests/MpvfxAudioGraphTests/SpectrumTests.swift` is the place for the checks on band edges, level range, smoothing and the slot read and write.
