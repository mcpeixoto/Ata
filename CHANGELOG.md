# Changelog

## 2.2.0

- **Better local transcripts.** Measured on 425 runs of real European Portuguese and English
  speech, clean and over VoIP and phone-quality audio
  ([numbers](docs/plans/2026-10-v2.2-v2.3.md)):
  - the decoding settings that caused repetition loops and clipped the first words of short
    turns are fixed — VoIP meeting error rate down from 32% to 21%;
  - the new default model, **Large v3**, is the most accurate on Portuguese and noisy calls, and a
    smaller download than before (1.08 GB). **Turbo** and **Turbo compact** remain for speed or
    disk space. Existing installs keep working on their model until they switch;
  - "Automatic" language now detects each track separately and only accepts languages you
    actually use — no more English meetings transcribed as Welsh.
- **Transcribe again with any model.** Right-click a meeting → *Transcribe again with…* any
  downloaded local model or any OpenAI model. The previous transcript is kept in the meeting's
  `versions/` folder — nothing is overwritten.
- **Insights.** A new tab in the menu: hours recorded, meetings per week, words, who talks how
  much, which apps your meetings happen in, every transcription with its model and cost, and
  how much transcribing on your Mac saved. Charts and numbers animate in. Meetings from before
  2.2 are included, read from their transcripts.
- **Costs.** Every transcription records its engine, model, audio minutes and — for OpenAI — an
  estimated price, in `meeting.json`.
- **Fixed:** several Settings texts were never translated to Portuguese; a symlinked model
  counted as not downloaded; the transcript's date followed the system region instead of the
  transcript's language.
- For contributors: unit tests (`swift test`) run in CI, plus an opt-in end-to-end test that
  transcribes a Portuguese and English meeting with a real model (`ATA_AUDIO_TESTS=1`);
  `check-localization.sh` now also fails when code uses a string missing from
  the tables, and `scripts/lib/sync-strings.py` adds and prunes keys in every language at once.

## 2.1.0

First public release.

- **OpenAI transcription engine** alongside the local whisper.cpp one, picked in Settings or
  from the welcome window. The API key is stored in the login keychain.
- **AI summary** — overview, decisions, action items and open questions above the
  transcript, available with either engine.
- **Audio is kept by default** and compressed to m4a (roughly a tenth of the raw size), with
  an optional 7/30/90-day retention.
- **Automatic updates**: Ata checks this repository daily and installs a new release after
  verifying its signature, Apple notarization and Team ID.
- **English and Portuguese**, following the system language.
- Signed with a Developer ID and notarized, published as a DMG by CI on every `v*` tag.
- Transcripts are now `transcript.md`; existing `transcricao.md` files are still read.
- Open-source groundwork: README with light and dark screenshots rendered from the real UI
  (`scripts/snapshots.sh`, also run by CI on every pull request), contributing guide,
  architecture notes, code of conduct, security policy, PR and issue templates, and English
  comments throughout the code.

## 2.0

Internal release: menu bar app, two-track recording, meeting detection, local whisper.cpp
transcription, echo removal, crash recovery.
