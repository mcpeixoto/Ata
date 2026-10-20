<div align="center">

# Ata

**Record and transcribe any meeting on your Mac — Slack, Zoom, Meet, Teams, FaceTime, the browser, anything.**

A menu bar app for macOS 14+ on Apple Silicon. It records your microphone and your Mac's
system audio as two separate tracks, then transcribes them — locally with Whisper, or with
the OpenAI API if you'd rather not download a model.

[![CI](https://github.com/mcpeixoto/Ata/actions/workflows/ci.yml/badge.svg)](https://github.com/mcpeixoto/Ata/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/mcpeixoto/Ata?label=download)](https://github.com/mcpeixoto/Ata/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Buy me a coffee](https://img.shields.io/badge/buy%20me%20a%20coffee-ffdd00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/mcpeixoto)

</div>

---

## Install

Download the latest `.dmg` from [Releases](https://github.com/mcpeixoto/Ata/releases/latest),
drag **Ata** into Applications, and open it. The app is signed with a Developer ID and
notarized by Apple, so it opens without any Gatekeeper warnings — and it keeps itself up to
date after that.

<details>
<summary>Or build it yourself</summary>

```bash
git clone https://github.com/mcpeixoto/Ata.git
cd Ata
./install.sh
```

Needs the Xcode Command Line Tools. The script builds the app, installs it in
`/Applications` and opens it.

</details>

A welcome window appears the first time, where you grant the microphone and system-audio
permissions and pick a transcription engine.

## Two ways to transcribe

| | **On this Mac** (default) | **OpenAI API** |
|---|---|---|
| Where the audio goes | nowhere, it never leaves | uploaded to OpenAI |
| Cost | free | per minute of audio |
| Setup | `brew install whisper-cpp` + a 1.6 GB model, both done for you from the welcome window | paste an API key |
| Speed | fast on Apple Silicon (Metal) | depends on your connection |
| Timestamps | per line | per line with `whisper-1`, none with the `gpt-4o-transcribe` models |

Pick one in **Settings → Transcription**, switch whenever you like. With either engine you
can also turn on **an AI summary** — overview, decisions, action items and open questions,
written above the transcript. That one always goes through OpenAI, since it needs a language
model, and it sends only the finished text.

Your API key is stored in the login keychain, never in a file or in the meeting folders.

## Using it

- **Record by hand:** click the waveform icon, then the red button (or ⌘R with the menu open).
- **Automatic detection:** when an app starts using the microphone, Ata sends a notification
  with a **Record** button. In Settings you can have it start recording on its own instead.
- When you stop, the transcription runs in the background and you get a notification when
  it's done. Each meeting lands in `~/Documents/Meetings/<date> <app>/transcript.md`.

The menu shows the elapsed time, a live meter for **you** and one for **the others** so you
can see straight away that both sides are being captured, and your recent meetings. Click
one to open it, or right-click to copy the text, transcribe it again, show it in the Finder
or delete it.

**Your audio is kept by default**, next to the transcript, compressed to m4a (about a tenth
of the raw size). You can turn that off, or have Ata delete audio after 7, 30 or 90 days, in
**Settings → Audio**.

## What makes it reliable

- **You switch microphones mid-meeting** (plugging in AirPods): the recording continues in
  the same file.
- **The microphone stops responding:** it restarts on its own.
- **Your Mac goes to sleep,** or system capture drops: it reconnects.
- **Both tracks stay aligned in time,** even after a restart mid-recording.
- **The app crashes or the Mac loses power:** the audio is on disk (the file header is
  rewritten every 3 s) and it gets transcribed on the next launch.
- **You quit mid-recording:** the recording is closed properly and transcribed when you
  come back.
- **Transcription fails:** the audio is never deleted and there's a **Try again** button.
- **No headphones:** Ata drops the lines your microphone picked up as echo from the others.

## Updates

Ata checks this repository for new releases once a day and offers the update in the menu.
Before anything is swapped in, the download is verified with `codesign`, Gatekeeper is
asked for its verdict, and the Team ID is compared with the running app's — an unsigned, a
re-signed or a tampered download is refused. You can turn automatic checks off in Settings
and still check by hand.

## Privacy

With the local engine, nothing goes anywhere: no accounts, no telemetry, no servers. The
only network traffic Ata ever makes on its own is the model download the first time and the
once-a-day release check against the GitHub API.

With the OpenAI engine, the recorded audio is uploaded to OpenAI's transcription endpoint —
that's the trade for not downloading a model — and the UI says so wherever you choose it.

And the obvious one: **tell the other participants you're recording.** Laws about this
differ, and it's the decent thing to do either way.

## Settings

Your name in the transcript, the language (automatic, EN, PT, ES, FR, DE, IT), the engine
and model, the AI summary, automatic detection, stopping on its own when a meeting ends,
keeping and compressing the audio, retention, opening at login, and automatic updates.

## Contributing

Issues and pull requests are welcome. Two things to know:

- `./scripts/build-app.sh` assembles the app bundle; CI runs the same script, so if it works
  for you it works there.
- `./scripts/setup-release-secrets.sh` configures the five signing secrets a fork needs to
  publish its own notarized builds.
- UI strings live in `Resources/en.lproj` and `Resources/pt.lproj`, with the English text as
  the key. `./scripts/check-localization.sh` fails if the two drift apart — CI runs it.

Another language is a welcome PR: copy `en.lproj` to `<code>.lproj`, translate the right-hand
side, and add the code to `CFBundleLocalizations` in `Resources/Info.plist`.

## Notes

- Apple Silicon only, macOS 14 or later.
- "Others" is everyone remote together; it doesn't tell different people apart yet.
- If you rebuild the app yourself, macOS may ask for the system-audio permission again.
  That's normal for a locally signed build.

## License

[MIT](LICENSE) © Miguel Peixoto

If Ata saves you from taking notes, [buy me a coffee](https://buymeacoffee.com/mcpeixoto) ☕
