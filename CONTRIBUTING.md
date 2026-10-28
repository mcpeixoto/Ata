# Contributing to Ata

Thanks for wanting to help. Ata is small on purpose — about 3,000 lines of Swift and no
dependencies — so most changes are approachable in an afternoon.

## Five-minute setup

You need a Mac with Apple Silicon, macOS 14.2+, and Xcode 26 (for Swift 6.2 package tools).

```bash
git clone https://github.com/mcpeixoto/Ata.git
cd Ata
swift build --disable-keychain   # compile (see below for the flag)
./scripts/build-app.sh     # assemble build/Ata.app (ad-hoc signed)
open build/Ata.app         # run it
```

`--disable-keychain` matters: without it SwiftPM can wait forever on a hidden keychain prompt
while fetching FluidAudio. Use it with every `swift build` / `swift test`.

To work in Xcode instead, `open Package.swift`. The app needs to run from a bundle for the
permission prompts and localizations to work, so use `build-app.sh` when you want to try a change
end to end.

**Keep your real meetings out of it.** Point the app at a scratch folder while you develop:

```bash
ATA_MEETINGS_DIR=/tmp/ata-dev ATA_SUPPORT_DIR=/tmp/ata-dev-support open build/Ata.app
```

`ATA_SUPPORT_DIR` moves the models and the voice library too — you'll need to download a model
into it once.

macOS ties the microphone and system-audio permissions to the app's signature, and an ad-hoc
signature changes on every build — so expect to re-grant system audio now and then. That's normal.

## Before you open a pull request

```bash
swift build -c release --arch arm64 --disable-keychain   # must be warning-free
swift test --disable-keychain                            # unit tests
./scripts/check-localization.sh         # every string in English and Portuguese
./scripts/build-app.sh                  # the bundle assembles and verifies
```

CI runs exactly these. If your change touches recording or transcription, also record a few
seconds for real and check the transcript that comes out.

**Changed the UI?** Regenerate the screenshots and include them in the PR:

```bash
./scripts/snapshots.sh
```

It renders the real views offscreen with made-up meetings and settings, into `docs/images/`.
CI also attaches a fresh set to every pull request as a downloadable artifact.

## How the code is laid out

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) has the full picture. The short version:

| File | Does |
|---|---|
| `AppStore.swift` | the single source of truth: recording, detection, the transcription queue |
| `Recorder.swift`, `WavWriter.swift` | capture the mic and system audio into two aligned WAVs |
| `MeetingDetector.swift` | notices when another app starts using the microphone |
| `Transcriber.swift` | merges the two tracks, removes echo, writes the Markdown |
| `EchoCanceller.swift` | takes the others out of the microphone track when there are no headphones |
| `LocalEngine.swift`, `OpenAIEngine.swift` | the two transcription backends |
| `Updater.swift` | finds, verifies and installs new releases |
| `Diarization.swift`, `Voices.swift`, `People*.swift` | who spoke when, the voice library, the People tab |
| `MergedAudio.swift`, `AudioFiles.swift` | `meeting.mp3`, compression, decoding, splitting for upload |
| `MeetingView.swift`, `MeetingModel.swift` | a meeting's own window: player, notes, transcript, its voices |
| `MenuIcon.swift` | the menu bar icon while recording, as set in Settings → Menu bar |
| `PopoverView.swift`, `SettingsView.swift`, `OnboardingView.swift` | the UI |
| `Sources/CLame/` | the LAME MP3 encoder, vendored unchanged; see its README |

## House rules

- **Never lose audio.** No code path that handles a failure may delete a recording. Only a
  successful transcript may compress or remove audio, and only when the user asked for that.
- **Every user-facing string is localized.** Write it in English, through SwiftUI `Text` or the
  `L()` helper, and add it to both `Resources/en.lproj/Localizable.strings` and
  `Resources/pt.lproj/Localizable.strings`. The English text is the key.
- **The local engine stays local.** Nothing in the local path may make a network call. Anything
  that sends data off the Mac has to be opt-in and say so in the UI.
- **No new dependencies** without talking about it in an issue first. Ata has two, each for
  something the SDK can't do: [FluidAudio](https://github.com/FluidInference/FluidAudio), for
  on-device speaker recognition, and [LAME](https://lame.sourceforge.io), vendored in
  `Sources/CLame`, because macOS has no MP3 encoder. Keeping the list that short is a feature.
- **Match the code around you** — naming, comment density, the way errors are surfaced.

## Adding a string

Write it in English in the code (SwiftUI `Text("…")`, or `L("…")` anywhere else — and `L()` for
any string chosen with `? :`, which SwiftUI would otherwise show untranslated), then run:

```bash
python3 -I scripts/lib/sync-strings.py "$PWD"
```

It adds the new key to every table — English filled in, other languages marked
`/* TODO: translate */` — and removes keys nothing uses anymore.

## Translating Ata

The easiest way to contribute. Copy `Resources/en.lproj` to `Resources/<code>.lproj` (for
example `de.lproj`), translate the right-hand side of every line, and add `<code>` to
`CFBundleLocalizations` in `Resources/Info.plist`. `check-localization.sh` picks the new folder
up on its own and tells you if a line is missing.

## Commits and pull requests

- [Conventional commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`, `chore:`…
- One change per pull request. Say *why* in the description; the diff already says what.
- Screenshots for anything visual.

## Releasing (maintainers)

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
2. Add a section to `CHANGELOG.md`.
3. Merge, then tag: `git tag v2.2.0 && git push origin v2.2.0`.
4. Publish from a Mac that has the Developer ID certificate: `./scripts/release-local.sh v2.2.0`.

The script signs with the key where it already lives in the keychain, notarizes, and publishes
the DMG; every running copy of Ata offers the update within a day. The
[release workflow](.github/workflows/release.yml) can do the same from CI once signing secrets
are configured (`./scripts/setup-release-secrets.sh`).

## Questions

Open an [issue](https://github.com/mcpeixoto/Ata/issues). There are no silly ones.
