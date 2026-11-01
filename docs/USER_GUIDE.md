# RoomEQ user guide

This guide covers every control in the RoomEQ panel, how to import filters from REW, how to check that the correction is accurate, and what to do when something goes wrong. For a short introduction and build instructions, see the [README](../README.md).

Interface labels below match the English interface. If your Mac is set to Italian, RoomEQ shows the Italian texts; the Italian guide is [LEGGIMI.md](../LEGGIMI.md).

## Contents

- [How it works in one paragraph](#how-it-works-in-one-paragraph)
- [The menu bar icon](#the-menu-bar-icon)
- [The panel](#the-panel)
- [Importing filters from REW](#importing-filters-from-rew)
- [Checking that the filters are right](#checking-that-the-filters-are-right)
- [Checking an EQ in your DAW](#checking-an-eq-in-your-daw)
- [Troubleshooting](#troubleshooting)
- [Updating and uninstalling](#updating-and-uninstalling)

## How it works in one paragraph

RoomEQ asks Core Audio for a "process tap" on the current macOS output device. The tap captures the audio of all apps except the ones you excluded (and RoomEQ itself), and silences them on the device while RoomEQ is reading. RoomEQ runs the captured audio through the EQ and plays the result on the same device. There is no virtual audio device and no sample-rate conversion. RoomEQ is designed so that, if it quits or crashes, the tap disappears and the apps play directly to the device again, without RoomEQ having to do anything.

## The menu bar icon

Click the icon in the menu bar to open the panel. Click it again, or click anywhere outside the panel, to close it.

| Icon | Meaning |
|---|---|
| Equalizer sliders at different heights | The correction is applied. |
| Sliders lined up and crossed out | The correction is **not** applied: it is switched off, or paused for this output because of an output rule. |
| Three dots | Starting up, or waiting for the audio device to be ready. After launch, after resuming, and after a change of the macOS output, RoomEQ keeps trying for up to about 30 seconds, because a device that has just been switched on or plugged in is often not ready right away. |
| Exclamation mark | Error. Open the panel and read the message. |

## The panel

### At the top

- **Correction** switch. This is the only on/off control. When it is off, nothing runs and audio goes straight to the output with no added latency. RoomEQ remembers the switch position between launches. On the first launch it is off, and there are no filters yet: import them from REW, then turn it on.
- **Status line** under the switch, for example "Correction on · *device name* · 6.3 ms" (the output device and the estimated total output latency). The number is the total, so it includes the latency of the output device itself, which is present even without RoomEQ; it is not all added by RoomEQ. **Diagnostics** shows the breakdown.
- **Preset** menu, described below.
- **Level meters** for the left and right output channels. The **CLIP** badge appears when any peak went over 0 dB. Under it the panel says why: either the correction itself pushes the signal over 0 dB (with a button that sets a lower preamp), or the signal already arrives above 0 dB from the app. Click the badge to reset it.

### At the bottom

- **Quit** removes RoomEQ completely, and audio returns to normal.

### Presets

A preset is a named set of filters plus a preamp value.

- The **Preset** menu lists your presets and the actions **Save As…**, **Rename…**, **Duplicate** and **Delete…**.
- An orange dot (●) next to the preset name means there are unsaved changes. A **Save** button then appears next to the menu. If you switch preset with unsaved changes, RoomEQ asks what to do with them.
- Preset names can be up to 40 characters and must be unique. You cannot delete the last remaining preset.
- On the first launch there is one empty preset, "Untitled". After your first import, **Save** stores the filters in it; rename it from the Preset menu if you like.

### Sections

All sections start collapsed. Click a title to open it; the right side of each title shows a short summary even when collapsed (all sections except Diagnostics). RoomEQ remembers which sections you opened.

**Filters & Preamp**

- A graph of the correction curve and the list of filters. Each filter has a frequency, a gain and a Q, and can be switched off, edited or deleted. **Add Filter** adds a neutral one (1 kHz, 0 dB, Q 1).
- Limits: up to 16 filters, all parametric peaking; frequency 10 Hz to 20 kHz (and no higher than 0.45 times the sample rate); gain −30 to +30 dB; Q 0.1 to 100. A filter outside these limits is kept in the list but not applied, with a warning.
- **Preamp**: from −24 dB to 0 dB. It only attenuates, never boosts. If the curve boosts anywhere, RoomEQ shows "The curve boosts up to … : suggested preamp …" with an **Apply** button. Use it to avoid clipping.
- **Import from REW…**: see [Importing filters from REW](#importing-filters-from-rew).

**Output & Interface**

- **Audio output**: the macOS output device. Choosing one here changes the macOS default output, and RoomEQ follows it.
- **Channels**: which pair of output channels to use (1–2, 3–4, …). It appears only on devices with at least four output channels.
- **Sample rate**: the rates the device offers. This is a setting of the device itself, so it applies to every app that uses it, including the excluded ones, not only RoomEQ. For that reason RoomEQ asks for confirmation, and restarts for a moment if the correction is running. If a DAW is open and playing, change the rate with the DAW closed or idle.
- **Buffer**: the I/O buffer size in frames (64, 128 or 256, limited to what the device accepts). Smaller buffers give lower latency. The default is 64; if you hear crackling, choose 128.

**Output Rules**

Rules are always active. For each output device RoomEQ has seen, choose:

- **Current preset**: no rule. The sound stays as it is, corrected with whatever preset is current.
- **a preset**: when this output becomes the macOS output, RoomEQ switches to that preset automatically (for example one preset for the studio monitors and another for headphones).
- **No correction**: RoomEQ steps aside. The audio goes straight to the device with no added latency, and the status line says the correction is paused for this output. This suits outputs that do not need correction, such as the built-in speakers. When you switch back to a corrected output, RoomEQ starts again by itself.

Unsaved edits you made on an output are remembered for it ("unsaved changes kept") if an automatic preset switch replaces them. Rules are tied to the device's Core Audio UID; a device that changes UID, which some USB devices do when moved to another port, appears as a new output.

**Excluded Apps**

Apps listed here are not captured: their audio does not go through RoomEQ. The list is empty at first, so nothing is excluded until you add an app. If you use a DAW or another app that applies its own correction, add it here, or its audio will be corrected twice. Use **Add App…** to choose from the apps that are currently open (the ones playing audio are marked) or **Choose from Applications…** to pick any app. Exclusion works by the app's bundle identifier and includes its helper processes.

- RoomEQ is always excluded automatically and never listed.
- **Do not exclude REW** if you want to measure the corrected sound: its sweeps must pass through RoomEQ. RoomEQ warns you if you exclude it.

**Startup**

**Open at login** starts RoomEQ when you log in. If the correction was on, it starts on. This works best with the app in `/Applications`. If macOS needs your approval, a button opens Login Items & Extensions in System Settings.

**Diagnostics**

Technical numbers: estimated latency and its breakdown, the tap format, ring-buffer delay, underruns, clip counters, overloads and input/output peaks. It is only useful for understanding a problem.

## Importing filters from REW

1. In REW, open the **EQ** window and select the **Generic** equalizer. Other equalizer models may define filters differently.
2. Choose **Export filter settings as text**.
3. In RoomEQ, open **Filters & Preamp** and click **Import from REW…**, then choose the file.
4. RoomEQ asks for confirmation if the import would replace unsaved changes. Imported filters replace the current ones.
5. Check any warnings that appear (skipped filters, unsupported types, and so on).
6. If "The curve boosts up to …" appears, click **Apply** to set the suggested preamp.
7. Click **Save** or **Save As…** to keep the result as a preset. Do this after the previous step, because the preamp is part of the preset.

What the importer does:

- Reads parametric peaking (`PK`) filters. Filters set to `None` are ignored. Filters that are `OFF` are imported as disabled.
- Skips other types (shelves, low/high pass and so on) with a warning.
- If the file has more than 16 PK filters, it imports 16: the first 16 enabled ones in file order and, if fewer than 16 are enabled, it fills the remaining places with disabled ones. It warns about the filters left out.
- Accepts a decimal comma as well as a decimal point, and frequencies in kHz.
- Refuses files larger than 1 MB or that are not text, and leaves your current filters unchanged if it finds no usable filter.

RoomEQ assumes that REW's Generic equalizer defines Q the same way as RoomEQ's filters (the standard "cookbook" peaking filter). The author verified this on November 1, 2026 with a loopback measurement (see the next section): the two agree within about 0.05 dB.

Whenever you take a new measurement in REW and compute new filters, repeat these steps. If a DAW with its own EQ is excluded from RoomEQ and you want the same correction there, enter the same filters in that EQ by hand.

## Checking that the filters are right

You can verify the whole chain with a measurement that does not need a microphone, by recording the interface output through an internal loopback. Many audio interfaces offer one: a pair of inputs that carries a copy of a chosen output. If yours has none, a physical cable from an output to an input does the same job.

The method, in general terms:

1. Set up a loopback so that the audio that macOS sends to the interface (the outputs RoomEQ plays on) also appears on two spare inputs of the interface.
2. In REW, select that loopback input for the measurement, select the matching output, and set the timing reference to **none**. Turn down the volume of your speakers; the sweep does not need to be heard.
3. Switch the RoomEQ **Correction** off and measure. Name it "OFF". This is the direct sound and should be flat.
4. Switch the correction on and measure again. Name it "ON".
5. In REW, open **All SPL**, then **Actions › Trace arithmetic**. Set A = "ON" and B = "OFF", choose **A / B** (not "A − B"), and click **Generate**.

The result is the response of RoomEQ alone. It should match the curve of the filters you imported. The author accepts a margin of 0.2 to 0.3 dB; their check on their own filters agreed within 0.1 dB. The same kind of measurement is how the author confirmed the Q definition mentioned in the previous section.

### Example: PreSonus Quantum with Universal Control

The author uses a PreSonus Quantum LT 16, whose internal loopback is on inputs 17–18. Setup, done once, in Universal Control:

1. **Gear** › **Appearance**, then turn on **Show All Loopback**.
2. On the channel that receives the Mac's audio (outputs 1–2), raise the **Loopback send** to 0 dB.
3. Turn the loopback send of all other channels all the way down.

Then in REW use input **channel 17** and output **channel 1**, with timing reference **none**, and follow the steps above. Other interfaces have their own loopback settings, so check your interface's manual.

### Measuring with a microphone (optional)

A microphone measurement shows the effect of the correction in the room; it is not a way to check RoomEQ itself.

- Keep the microphone fixed at the listening position.
- Measure once with the **Correction** off and once with it on.
- Use timing reference **acoustic** or **none**, never a loopback reference: REW would send that reference to the other speaker.

## Checking an EQ in your DAW

If you excluded a DAW from RoomEQ and rebuilt the same filters inside it, you can check that EQ the same way. The DAW is excluded, so it must play the test sweep itself.

1. In REW, open the **Generator**, choose **Measurement Sweep** at the sample rate you use, with a timing reference, and save it as a WAV file.
2. In the DAW, put the WAV on an audio track with warping off. Set the track and the master to 0 dB. On the master, keep only the EQ you are checking: switch off limiters and other effects.
3. In REW, measure with the file: load the same WAV, select the loopback input, and use the **acoustic** timing reference.
4. Start the measurement in REW. When "Waiting for timing reference…" appears, press play in the DAW.
5. Make one measurement with the EQ off and one with it on, then divide them (**A / B**) as above.

### Example: Ableton Live and EQ Eight

Ableton Live is a typical case of a DAW with its own correction: an EQ Eight on the master carries the same filters, and Ableton is added to **Excluded Apps** so it is not corrected twice. EQ Eight is Ableton Live's built-in EQ. Its bands cannot go below **−15 dB**, and it gives no warning when you type a lower value. If a filter is deeper than that, for example −15.9 dB, use two bands with the **same frequency and the same Q**: one at −15 dB and one with the remainder (−0.9 dB). The two cascaded bands add up exactly to the deeper cut only at the center frequency; elsewhere the sum is an approximation. Use the bell type for each band.

## Troubleshooting

| Problem | What to do |
|---|---|
| No sound with RoomEQ on | Turn off the **Correction** switch. If the sound comes back, open System Settings › Privacy & Security › **Screen & System Audio Recording** and make sure RoomEQ is allowed. |
| No sound even after quitting RoomEQ | Restart the Mac. |
| Crackling or dropouts | In **Output & Interface**, set **Buffer** to 128 or 256. |
| A red error message | Read it: it says what happened. If the audio cannot go through RoomEQ, RoomEQ lets it pass straight to the output without correction, and the switch stays on. RoomEQ makes its automatic attempts only in the window of up to about 30 seconds after launch, resuming or an output change (the three-dots icon); when the red error appears, those attempts are over. Click **Retry**, or change the macOS output, which makes RoomEQ start again by itself. A serious error while RoomEQ is running goes to the red error immediately, without attempts. |
| "The correction exceeds 0 dB" or the CLIP badge | The correction boosts the signal. Click the **Set Preamp to …** button shown under the meters, or use **Apply** in **Filters & Preamp**. If the message says the signal already arrives above 0 dB from the app, the cause is the app, not RoomEQ. |
| A DAW (or other excluded app) is being corrected | Check that it is in **Excluded Apps**. |
| The audio permission is requested again | This can happen after you rebuild or reinstall the app, because the build is signed ad-hoc and macOS ties the permission to the signature. Allow it again. |
| Latency seems higher than expected | Open **Diagnostics** to see the estimate and its breakdown. Remember that the figure includes the output device's own latency, which exists without RoomEQ too. Use a smaller buffer, or give the output **No correction** in **Output Rules** if you do not need the EQ there. |
| RoomEQ does not start on a device | The tap and device sample rates must match, because RoomEQ never converts them. Check the sample rate in **Output & Interface**. The error message names the exact reason. |
| Settings were reset | If saved settings cannot be read, RoomEQ keeps a backup copy, loads what it can, and shows a notice. |

## Updating and uninstalling

To update, pull the new sources and run, in the project folder:

```bash
./build.sh && ./run-tests.sh && ./install.sh
```

To uninstall:

1. In RoomEQ, open **Startup**, turn off **Open at login**, then quit RoomEQ.
2. Delete `/Applications/RoomEQ.app`.
3. To erase the saved settings as well: `defaults delete com.federicociapi.RoomEQ`. (If you changed the bundle identifier in `Resources/Info.plist` for your own fork, use your identifier in this and any other `defaults` command.)
