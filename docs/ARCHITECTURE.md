# Architecture

Xenyn is a single SwiftUI app built with Swift Package Manager. It has no Xcode project and no third-party Swift dependencies.

## Signal flow

Call engine (one `AVAudioEngine`, output bound to BlackHole 2ch):

```
microphone ─► MicCapture ─► ring ─► source ─► upmix ─► voice effect ─► voiceOut ─┐
(AVCaptureSession)                  (mono)   (→stereo) (TimePitch/Graillon)      ├─► callMix ─┬─► main mixer ─► BlackHole 2ch ─► FaceTime
                                                        clipPlayer ──────────────┘            │        ▲
                                                                                              ▼        │ muted
caller ─► SystemAudioCapture ─► callerRing ─► callerSource ───────────────────────────► recordMixer ─► recordSink
(ScreenCaptureKit, or an input device)                                                  └─ tap ─► .m4a
```

Monitor engine (output bound to the system default output):

```
monitorPlayer ─► main mixer ─► headphones
```

## Design decisions

- **One engine per output device.** Each `AVAudioEngine` has its output node bound to exactly one device through `kAudioOutputUnitProperty_CurrentDevice`. That avoids aggregate devices and the channel mapping that comes with them.
- **The mic comes in through AVCaptureSession, not the engine's input node.** That keeps the mic independent of the output device. The capture output is set to mono Float32 at the call engine's sample rate, so the ring buffer never resamples.
- **The ring buffer absorbs clock drift.** The mic and BlackHole run on separate clocks. `RingBuffer` holds about 40 ms. It drops the oldest audio when it drifts more than 4× ahead, and it outputs silence and re-primes when it runs dry.
- **Clips are decoded per engine format.** `ClipLibrary` converts each file into an `AVAudioPCMBuffer` that matches each engine's sample rate (mono clips are duplicated to both channels) and caches the result. The monitor engine plays the same clip in step with the call engine.
- **Swapping the voice effect.** Switching between the built-in pitch shifter and Graillon stops the call engine, rewires `upmix → effect → voiceOut`, then restarts it. Bypassing uses `AUAudioUnit.shouldBypassEffect`.
- **Recording mixes both sides off to one side.** `callMix` (your voice and clips) fans out to the main mixer and to `recordMixer`. The caller's audio feeds only `recordMixer`. A tap on `recordMixer` writes an AAC `.m4a`. `recordSink` is muted, so its branch keeps rendering without the caller's audio reaching BlackHole. The tap owns the `AVAudioFile`, so removing the tap releases the file and finalizes it.
- **Caller audio comes from ScreenCaptureKit.** A display-wide `SCStream` captures audio only, with `excludesCurrentProcessAudio` set, at the call engine's sample rate in mono. It runs only while recording and needs Screen Recording permission. Any input device can be used instead, through `MicCapture`. Core Audio process taps would be tidier but need macOS 14.2.
- **Hotkeys use Carbon `RegisterEventHotKey`.** They work while FaceTime is in front and don't need Accessibility permission.
- **BlackHole is excluded from the mic list.** Picking it would feed the call mix back into itself.

## Files

| File | Role |
|---|---|
| `XenynApp.swift` | App entry point, window, lifecycle |
| `AppModel.swift` | State, actions, ramble timing, hotkey bindings |
| `ContentView.swift` | UI |
| `AudioRig.swift` | Both engines, the graph, voice swapping, clip playback, recording |
| `MicCapture.swift` | AVCaptureSession input (mic, or caller device) → ring buffer |
| `SystemAudioCapture.swift` | ScreenCaptureKit system audio (caller) → ring buffer |
| `RingBuffer.swift` | Drift-tolerant mono FIFO, sample-buffer ingest |
| `ClipLibrary.swift` | Clips folder scan, decoding, caching |
| `AudioDevices.swift` | Core Audio device lookup and output binding |
| `HotKeys.swift` | Global hotkeys |
| `Errors.swift` | Error messages |

## Build

`scripts/bundle.sh` runs `swift build -c release`, copies the binary and `Resources/Info.plist` into `dist/Xenyn.app`, and ad-hoc signs it. The bundle is needed for the microphone permission prompt: a bare `swift run` binary gets its permission through the terminal app instead.
