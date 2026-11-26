# Xenyn

*ZEE-nin* · a soundboard and voice changer for messing with scam callers, on macOS.

Take a phone call on your Mac through FaceTime and Xenyn sits between you and the caller. It mixes your voice (pitch-shifted, if you want) with audio clips you trigger with global hotkeys, or that play hands-free on their own.

> Xenyn is NYNEX backwards, a nod to the old Baby Bell.

```
microphone ─► voice effect ─┐
                            ├─► BlackHole 2ch ─► FaceTime ─► caller
clips (hotkeys / ramble) ───┤
                            └─► your headphones (clips only)
```

## Features

- **Voice.** Built-in pitch shifting (±12 semitones). If Graillon 3 is installed, you can use it instead for formant shifting and more.
- **Clips.** Put audio files in a folder and trigger them from any app with ⌃⌥1–9.
- **Ramble.** Plays random clips with varied gaps between them, so you don't have to.
- **Panic.** One key stops the clips and turns the voice effect off, so you sound like yourself again.
- **Monitor.** Hear your clips in your headphones while they play into the call.
- **Record.** Save both sides of the call, you and the caller, as an `.m4a` file.

## Requirements

- macOS 13 Ventura or later
- [BlackHole 2ch](https://existential.audio/blackhole/), a free, open-source virtual audio driver
- Xcode or the Command Line Tools (`xcode-select --install`), to build
- For phone calls: an iPhone signed in to the same Apple Account, with calling on other devices turned on
- Optional: [Graillon 3](https://www.auburnsounds.com/products/Graillon.html) (the Free Edition works)

## Install

```bash
brew install blackhole-2ch
git clone https://github.com/donliggett/xenyn.git
cd xenyn
./scripts/bundle.sh
open dist/Xenyn.app
```

If you don't use Homebrew, get the BlackHole installer from its website. You can move `dist/Xenyn.app` to `/Applications`. The first time Xenyn launches, it asks for microphone access.

## Set up calls

1. **iPhone:** in the Phone settings, turn on **Calls on Other Devices** and allow your Mac.
2. **Mac:** in FaceTime → Settings, turn on **Calls from iPhone**.
3. **FaceTime microphone:** in FaceTime's **Video** menu, choose **BlackHole 2ch** as the microphone.
4. **During a call:** open Control Center → **Mic Mode** and choose **Standard**. Voice Isolation treats clips as background noise and muffles them.

Use headphones so the caller's voice doesn't leak back through your mic.

## Clips

Put audio files in `~/Music/Xenyn/Clips` (the **Folder** button opens it), then press **Reload**. Xenyn reads WAV, AIFF, CAF, MP3, M4A/AAC and FLAC.

Clips are sorted by name, and the first nine get hotkeys. To control the order, start the file names with numbers: `1-hello.m4a`, `2-what.m4a`.

## Recording

**Record** saves both sides of the call to `~/Music/Xenyn/Recordings`. Your side is exactly what Xenyn sends to the call. The caller's voice is only written to the file and is never sent back into the call.

**Caller audio** sets where the caller's side comes from:

- **System audio** (default) captures everything your Mac is playing except Xenyn itself, so mute other apps while you record. The first recording asks for **Screen Recording** permission, which macOS requires for capturing system audio. Xenyn records no video.
- **An input device**, such as BlackHole 16ch, if you route your Mac's output through it with a Multi-Output Device in Audio MIDI Setup.

Recording laws vary. Many places require everyone on a call to consent to being recorded, so check the rules where you and the caller are.

## Hotkeys

These work from any app, including while FaceTime is in front.

| Keys | Action |
|---|---|
| ⌃⌥1 – ⌃⌥9 | Play clip 1–9 |
| ⌃⌥0 | Stop clip and ramble |
| ⌃⌥R | Ramble on/off |
| ⌃⌥M | Mic on/off |
| ⌃⌥V | Voice effect on/off |
| ⌃⌥E | Record on/off |
| ⌃⌥Space | Panic: stop everything, clean voice |

## Handing a real call to your iPhone

Answer calls on the Mac. If the caller turns out to be legitimate, move the call to your iPhone: on the iPhone, swipe up and hold to open the App Switcher, then tap the Phone banner at the bottom. Once the call is on the iPhone, Xenyn is no longer in the audio path.

## Notes

- Builds are ad-hoc signed, so macOS may ask for microphone access again after you rebuild.
- How it works inside: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- Xenyn isn't affiliated with Apple, Existential Audio or Auburn Sounds.

## License

[MIT](LICENSE)
