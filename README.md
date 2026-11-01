# RoomEQ

A macOS menu bar app that applies a room-correction EQ to all your Mac's audio, except the apps you exclude.

*Italian guide: [LEGGIMI.md](LEGGIMI.md).*

<!-- TODO: screenshot of the panel goes here -->

RoomEQ is for people who measure their listening room with [REW](https://www.roomeqwizard.com) (Room EQ Wizard) and want the resulting correction filters applied system-wide on a Mac, without routing audio through a virtual device or a third-party driver. It captures the system output with a Core Audio process tap, runs it through a parametric EQ, and plays it on the same output device. Apps that do their own correction, such as a DAW with an EQ on the master, can be excluded so their audio is not corrected twice.

## Features

- **No sample-rate conversion.** Audio is processed at the output device's own sample rate. If the rates do not match, RoomEQ refuses to start instead of resampling.
- **Any output device.** USB or Thunderbolt audio interfaces, the built-in speakers, headphones. On interfaces with at least four output channels you choose which stereo pair to use.
- **Per-app exclusion.** Excluded apps bypass the correction and play straight to the output. Nothing is excluded by default: add your DAW, or any other app that does its own correction, in **Excluded Apps**.
- **Output rules.** For each output device, choose "Current preset", a specific preset, or "No correction". With "No correction" RoomEQ steps aside completely: the audio goes straight to the device with no added latency. Rules apply automatically when the macOS output changes.
- **Presets.** Save, rename, duplicate and delete named sets of filters plus preamp.
- **REW import.** Load the text file REW exports (Export filter settings as text, Generic equalizer).
- **Low latency.** The latency shown in the status line is the total output latency, estimated by the app. It includes the latency of the output device itself, which is there even without RoomEQ. On the author's interface it is about 6 ms with a 64-frame buffer. Your result depends on your device and buffer size; the panel shows the estimate for yours.
- **Safe failure.** If RoomEQ quits or crashes, the apps' audio returns to normal on its own: the apps are muted only while RoomEQ is running (checked by force-quitting RoomEQ with `kill -9` during playback).
- **English and Italian.** The interface follows the macOS language.

## Requirements

- macOS 15 (Sequoia) or later to run the app.
- To build: Xcode 26 or later (Swift 6.2 or later toolchain). The code uses APIs from the macOS 26 SDK (`CATapDescription.bundleIDs` and `isProcessRestoreEnabled`), behind a runtime availability check, so the app still runs on macOS 15 but needs the macOS 26 SDK to compile. The project is built with plain Swift Package Manager; there is no Xcode project.
- The **Screen & System Audio Recording** permission. macOS asks for it the first time RoomEQ starts the correction (System Settings › Privacy & Security › Screen & System Audio Recording). macOS may also show a microphone prompt because audio interfaces have inputs; RoomEQ does not record the microphone and uses the interface only as an output.

## Build and install

There are no prebuilt binaries. Build from source:

```bash
./build.sh        # compile, check translations, assemble and sign build/RoomEQ.app
./run-tests.sh    # unit tests (no audio hardware or permissions needed)
./install.sh      # copy build/RoomEQ.app to /Applications
open /Applications/RoomEQ.app
```

You can also run `build/RoomEQ.app` directly without installing it. "Open at login" works best from `/Applications`.

**About the signature.** `build.sh` signs the app ad-hoc (`codesign --sign -`), so no Apple developer account is needed. This has a few consequences:

- macOS ties privacy permissions to the app's signature and location, so it may ask for the audio permission again after each rebuild or reinstall.
- The app is not notarized. An app you build on your own Mac runs normally, but if you copy the built app to another Mac through a download or AirDrop, Gatekeeper will likely block it and you will have to allow it manually.

## Quick start

1. In REW, open the **EQ** window, select the **Generic** equalizer, and choose **Export filter settings as text**.
2. Click the RoomEQ icon in the menu bar, open **Filters & Preamp**, click **Import from REW…** and pick the file.
3. If RoomEQ says "The curve boosts up to…", click **Apply** to set the suggested preamp and avoid clipping. Do this before saving, because the preamp is part of the preset.
4. Click **Save** to keep the filters and preamp in the current preset (or **Save As…** from the Preset menu to give them a name).
5. Turn on the **Correction** switch at the top.
6. If you use a DAW (or another app) that already applies its own correction, add it in **Excluded Apps**, so it is not corrected twice.

On the first launch RoomEQ has no filters, one empty preset named "Untitled", no excluded apps and the **Correction** switch off, so nothing changes until you import your filters and turn the switch on. If you turn it on with no filters, the audio passes through unchanged.

## Everyday use

The panel opens under the menu bar icon. At the top is the **Correction** switch (off means the audio goes straight through, with no added latency), a status line, the **Preset** menu and the level meters. Below are collapsible sections: **Filters & Preamp**, **Output & Interface**, **Output Rules**, **Excluded Apps**, **Startup** and **Diagnostics**. At the bottom is **Quit**. The menu bar icon shows whether the correction is being applied.

See the [user guide](docs/USER_GUIDE.md) for every control, and for how to check the filters with a measurement.

## Known limitations and non-goals

- Stereo only. RoomEQ corrects two channels and writes them to one pair of output channels; it does not handle surround or multichannel output.
- Only parametric peaking (PK) filters, up to 16. Other REW filter types (shelves, low/high pass) are skipped on import with a warning.
- RoomEQ follows the macOS default output device. Only that device is corrected.
- No sample-rate conversion, by design. Changing the sample rate in RoomEQ changes it for every app using that device.
- Not a measurement tool and not a room-correction calculator: you compute the filters in REW (or any tool that can export REW-style text) and RoomEQ applies them.
- No prebuilt, notarized or App Store release.
- The REW import relies on REW's Generic equalizer defining Q the same way as RoomEQ's filters (the standard "cookbook" peaking filter). The author verified this on November 1, 2026 with a loopback measurement: the two agree within about 0.05 dB. You can repeat the check on your own setup, see the user guide.

## Privacy

Audio never leaves your Mac. RoomEQ makes no network connections: the source code contains no networking code, and it does not record audio to disk. Settings (filters, presets, rules, excluded apps) are stored locally in the app's preferences (`defaults read com.federicociapi.RoomEQ`). If you change the bundle identifier in `Resources/Info.plist` for your own fork, use your identifier in this and the other `defaults` commands. Diagnostic messages go to the macOS system log on your machine only (you can read them in Console); they include the names of your audio devices and the bundle identifiers of the apps that are running.

## Documentation

- [User guide](docs/USER_GUIDE.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Contributing](CONTRIBUTING.md)
- [Guida in italiano](LEGGIMI.md)
- [License](LICENSE) (GNU GPL 3.0)
