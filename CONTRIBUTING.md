# Contributing to RoomEQ

Thanks for your interest. RoomEQ is a small project, so this page is short.

## Build and test

You need macOS 15 or later to run the app, and Xcode 26 or later (Swift 6.2+ toolchain, macOS 26 SDK) to build it, because the code uses APIs from the macOS 26 SDK behind a runtime availability check (see the [README](README.md#requirements)).

```bash
./build.sh        # release build, translation check, assembles and signs build/RoomEQ.app
./run-tests.sh    # unit tests (same as `swift test`)
```

Please run both before opening a pull request. The unit tests cover `RoomEQCore`, the part of the code that does not touch audio hardware (render kernel, EQ filters, REW import, settings, presets, latency math). Anything in the app target that talks to Core Audio can only be checked by running the app, so say in the pull request what you tried and on which device.

## Project layout

- `Sources/RoomEQCore`: hardware-independent logic, unit-tested.
- `Sources/RoomEQ`: the app (Core Audio tap and engine, controller, SwiftUI panel).
- `Tests/RoomEQCoreTests`: unit tests.
- `Resources`: `Info.plist`, icon, and the localization tables.
- `tools`: `check-localizations.swift` is run by the build; `make-icon.swift` is not part of the build, it only regenerates the app icon when you run it by hand.
- `docs`: [user guide](docs/USER_GUIDE.md) and [architecture](docs/ARCHITECTURE.md).

## Style

- Code comments and documentation are in English. The exceptions are the app's visible texts, whose development language is Italian (see Translations below), and the messages printed by `install.sh`, which are in Italian.
- The real-time audio path (`RenderKernel` and what it calls) must not allocate, take locks, log or do file I/O. Read the notes at the top of `Sources/RoomEQCore/RenderKernel.swift` before changing it.
- Add a test for any non-trivial logic, especially parsing, calculations and edge cases.
- Keep changes focused: one topic per pull request.

## Translations

The code's visible texts are written in Italian, which is the development language, and the Italian text is itself the localization key. The English translation lives in `Resources/en.lproj/Localizable.strings`.

Every user-visible text (in `Text(...)`, `Button(...)`, `String(localized:)`, error messages and so on) must have an entry there, with the same format specifiers (`%@`, `%lld`, …) in the same order. `./build.sh` runs `tools/check-localizations.swift` and stops if a translation is missing or its specifiers do not match. Texts shown by macOS from `Info.plist` (permission requests) are translated in `Resources/en.lproj/InfoPlist.strings` and `Resources/it.lproj/InfoPlist.strings`.

Interface labels in documentation must match the English table exactly.

## Issues and pull requests

- Open an issue on GitHub ([github.com/fc79/RoomEQ](https://github.com/fc79/RoomEQ)) to report a bug or suggest a change. For bugs, include your macOS version, the output device, the sample rate and buffer size, what you expected and what happened. The **Diagnostics** section of the panel can help.
- For larger changes, open an issue first so we can agree on the approach before you write code.
- Open pull requests against `main`, with a short description of what changed and why, and the result of `./run-tests.sh`.
- By contributing you agree that your work is released under the project's license, the [GNU GPL 3.0](LICENSE).
