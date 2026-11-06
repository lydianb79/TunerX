# TunerX — high-precision guitar tuner for macOS

A native macOS app written in Swift / SwiftUI. The scale is drawn with **Metal**, audio comes in through **CoreAudio (AUHAL)**, and the DSP runs on **Accelerate**.

## Features
- **Input device and channel selection**: built-in mic, or any channel of a USB/Thunderbolt audio interface (or "Mix all").
- **Output device selection**, used for a pure-sine **reference tone** (it can follow the detected note, or be set to a fixed string note) and for low-latency **input monitoring**.
- **Buffer size** (16–4096 samples, limited to what the device supports) and **sample rate** selection. Shows the active buffer size and the input latency.
- **Automatic note detection**: chromatic, from about 25 Hz to 2 kHz (7-string low B, bass-range notes, and the highest frets).
- **Four Metal instruments**, drawn at up to 120 fps with 4× MSAA:
  1. **Strobe**: three virtual strobe bands. The pattern stands still when the note is in tune and drifts left (flat) or right (sharp), faster the further off it is.
  2. **Chromatic wide scale**: a scrolling tape covering ±6 semitones, with note names, 10-cent ticks and an in-tune window.
  3. **Fine scale**: ±50 cents with 1-cent divisions.
  4. **Micro scale**: ±5 cents with 0.1-cent divisions.
- The header shows the note, the deviation to 0.01 cent, the measured frequency and the target frequency to 0.0001 Hz, the deviation in Hz, and the detection clarity.
- Adjustable A4 reference (400–480 Hz, 0.1 Hz steps), analysis window length, smoothing and noise gate. Settings are kept between launches.

## Precision
Pitch detection works in two stages:
1. **McLeod Pitch Method** (NSDF from an FFT autocorrelation) gives a robust estimate without octave errors, accurate to about ±1 cent.
2. A **phase-difference refinement** measures two Hann-windowed segments at the estimated frequency. The phase advance between them gives the fundamental frequency with very fine resolution.

Simulated guitar tones (7 inharmonic partials, decaying envelope, noise at −40 dB, 48 kHz) gave these worst-case errors from E1 to E6:

| Window | Size @48k | Worst error |
|---|---|---|
| Fast | 4096 | ~0.9 ¢ (low notes fall back to stage 1) |
| Balanced | 8192 | ~0.8 ¢ at E1, < 0.02 ¢ from E2 up |
| **Precise** (default) | 16384 | **< 0.035 ¢** |
| Ultra | 32768 | **< 0.005 ¢** |

The audio buffer size only changes **latency**. Precision depends on the analysis window, which is independent of the buffer size.

## Build & run
Requirements: macOS 13 or later, and Xcode 15 or later (or the Swift 5.9+ command-line tools).

```bash
cd TunerX
./build_app.sh          # builds build/TunerX.app (release, ad-hoc signed)
open build/TunerX.app
```
On first launch macOS asks for microphone access. That permission is also what lets TunerX read audio interfaces.

To develop in Xcode: run `open Package.swift`, then build. For microphone permission, launch the app from the bundle produced by `build_app.sh`. A bare executable run from Xcode has no `NSMicrophoneUsageDescription` and gets no input.

## Project layout
```
Package.swift
Sources/TXCore/            lock-free C11 ring buffer (realtime-safe)
Sources/TunerX/
  TunerXApp.swift          app entry point
  AudioDevices.swift       CoreAudio HAL: devices, channels, buffer sizes, sample rates, latency
  AudioEngine.swift        AUHAL input and output units, realtime callbacks, reference tone, monitoring
  PitchDetector.swift      MPM + phase-difference refinement (Accelerate)
  TunerModel.swift         settings, device handling, analysis thread, note tracking and smoothing
  TunerRenderer.swift      Metal renderer (strobe, wide scale, ±50 ¢, ±5 ¢)
  Shaders.swift            MSL source, compiled at runtime
  GlyphAtlas.swift         CoreText → Metal texture for on-GPU labels
  Views.swift              SwiftUI header, settings sidebar, level meter
Resources/                 Info.plist, entitlements
build_app.sh
```

## Notes
- Changing the buffer size changes the device's IO buffer for TunerX's process only. Changing the sample rate changes the device's nominal rate, which affects the whole system.
- Monitoring and the reference tone use the input sample rate; the AUHAL converts to the output device rate.
- If you monitor through speakers with a microphone input, the tuner will hear its own reference tone. Use headphones.
