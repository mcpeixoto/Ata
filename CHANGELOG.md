# Changelog

## 3.1.0

Ata for iPhone goes to the App Store. This release gets it ready, and fixes
what a full review of the Mac app and the iCloud sync turned up.

- **Work and personal meetings.** Every meeting can be filed as work or
  personal. On the Mac, map each calendar to one or the other in Settings,
  and calls from Zoom, Teams or Slack count as work and FaceTime or WhatsApp
  as personal unless you say otherwise. Change it from the meeting's header,
  and filter the list, the iPhone's meetings and Insights by either.
- **Ata Pro on iPhone.** Five new meetings a month recorded or imported on
  the iPhone are free; Ata Pro removes the limit for €2.99 a month. A
  recording in progress always finishes, imports are never refused, and
  meetings recorded on the Mac never count. The Mac app stays free.
- **iCloud sync is careful when iCloud goes away.** Signing out of iCloud, or
  turning iCloud Drive off, used to leave Ata writing into a folder that no
  longer synced while it still said "in iCloud". It now notices and switches
  to this device. Turning sync off copies every meeting back to the device
  first, so the list no longer comes back empty on an iPhone.
- **Two devices no longer undo each other's work.** A device that lost its
  claim on a meeting can't save over the other's transcript any more; the
  end of a run re-reads the meeting and only adds the transcript, so a title
  or category changed meanwhile survives. A meeting whose audio hadn't
  downloaded yet is retried instead of failing for good, and resolved iCloud
  conflict copies are deleted instead of using up storage.
- **Tracks an earlier repair slowed by mistake are restored.** 3.0.0 to 3.0.3
  could judge a healthy call recording corrupt and slow it down. When the
  original kept beside it is healthy, it is put back and the meeting is
  transcribed again. The check now runs in the background, so the first
  launch after updating no longer freezes, and it only looks at meetings
  recorded before this version.
- **The other side's words stay in the transcript.** In a room recording, a
  remote participant with steady background noise could lose every line.
- Cancelling a transcription now stops the engine at once; a failed write
  can no longer leave a meeting without its transcript; a calendar meeting
  that failed to start recording is retried.
- iPhone: privacy manifests, a privacy policy and help page, and Apple
  Intelligence messages that no longer mention a Mac.

## 3.0.5

- **One microphone is a meeting in the room.** A recording on the laptop's
  built-in microphone, or the only microphone there is, has everyone in the
  room on that one track. Ata tells those voices apart instead of labelling
  the whole track as you. When the Mac also played a real other side, those
  people stay on the system track. A chime or a video is not that other side,
  and it is no longer subtracted from the only recording of the room.

## 3.0.4

- **A stuck transcription can no longer jam the queue.** Transcription runs
  one meeting at a time, and the engine is a helper process: if it ever
  wedged, every later meeting waited behind it until the app was quit. The
  engine writes progress as it works, so ten minutes of silence from it now
  ends the run — that meeting is marked failed with the reason, and the
  queue moves on.
- **The damage check no longer mistakes quiet for corrupt.** Deciding that
  a pre-3.0 system track is the double-speed corruption used to rest on one
  signal, which also fits a healthy track that only carried a few short
  notification sounds. It must now also match the broken writer's signature
  — the tenth-of-a-second silences it left between sounds — before anything
  is rewritten.
- **TestFlight releases sign again.** The automated iOS release had started
  failing before it built anything: each run made Xcode create fresh
  signing certificates until the account reached its limit. The build now
  archives unsigned and lets the export step do all the signing, as it
  already did.

## 3.0.3

- **A repaired recording is not slowed a second time.** 3.0.1 kept the original
  beside the fixed file, then on the next launch looked for that original under
  the fixed file's extension. The original was often an m4a and the fixed file
  a wav, so the launch never saw it and slowed the wav again. This launch
  rebuilds from the original it kept, once. A folder it has already judged —
  healthy or repaired — is not decoded again every time Ata opens. A few stray
  samples a decoder leaves in a silent gap no longer hide the corruption, and
  a stretch that was already longer than a second is still left as recorded.

## 3.0.2

- **The launch crash is fixed, properly this time.** 3.0.0 crashed when it
  opened, and 3.0.1 — which rewrote the recording-repair scan — kept the same
  fault in the new code: the scan tested `abs(sample)` on 16-bit samples, and
  a sample at the very bottom of the range (one loud moment, clipped, in
  three ordinary meetings) has no absolute value, so the app trapped before
  its window opened, on every launch. The scan compares magnitudes now, and a
  regression test with a clipped sample stands guard. Those meetings were
  always healthy; nothing about them is repaired or renamed.

## 3.0.1

- **A corrupted recording is marked, and only its short pieces are slowed.** A
  healthy system track keeps nearly all of its sound in stretches longer than a
  second. One that Ata 2.11 sped up has almost none. Under 5% in those long
  stretches, the meeting is flagged in the window and at the top of the
  transcript. The short pieces are slowed back to the speed they were spoken;
  a stretch that was already longer than a second is left as recorded.

## 3.0.0

Two calls came back wrong — one with only your side in it, one with the other
side garbled — and nothing anywhere said so. This release is about that, plus
three things borrowed from Granola.

- **The other side of a call no longer comes out at double speed.** Since 2.11
  the system-audio track could play at about 2× while the file stayed the right
  length: each buffer held about half as many frames as the time since the last
  one, and the silence used to keep the two tracks in step filled the rest. The
  length check compared that padded file with the clock, so it never noticed.
  A buffer is now read in the layout it actually has — one the tap's format
  doesn't describe used to be dropped, which left a stretch of the track empty —
  and when the frames in an ordinary callback don't fill the time that just
  passed they are written at the rate they really arrived. The check looks at
  that, before any silence is added.   `Ata --diagnose` no longer quits the copy
  of Ata you already have open. Language-detection pieces left behind when a
  transcription stopped are removed the next time Ata starts. Recordings
  already on disk from 2.11 are repaired the next time Ata opens: the padding
  comes out, the speech is put back to the speed it was spoken, and the
  original file is kept as `system.corrupted`. Those meetings are transcribed
  again. The half of each buffer 2.11 never wrote is still gone.
- **One working microphone is a meeting in the room.** When the system-audio
  track is silent, Ata already tells the voices on your microphone apart. It
  now does the same when that track is loud but almost none of it comes back
  as words — the other side was never really captured, so the conversation is
  the one the microphone heard, and it is split into its speakers instead of
  all being filed as you. The lines that track did produce are left out: they
  are not the other participants.

- **A side of a call can no longer go missing in silence.** A system-audio tap
  pointed at an output the call is not using delivers perfect digital silence
  forever: buffers arrive, the file is the right length, every check Ata had
  passed. Now, half a minute into a recording where you have clearly been
  heard and their side has never risen above silence, Ata says so in the menu
  while the call can still be saved. And after transcription, if a track was
  present but held no sound, the transcript says so at the top and the meeting
  window shows it, with where to check. The echo canceller is also skipped
  against a silent reference — there is no echo to find, and it is the most
  expensive pass in the run.
- **Note templates.** Settings → Transcription: Standard (the shape Ata has
  always written), One-to-one, Sales call, Team standup, Interview. Templates
  apply when notes are written or rewritten.
- **Names and words to spell right.** A dictionary in Settings, with everyone
  you have named in People included automatically. With OpenAI the words go
  with the audio as spelling hints — "Copilot", not "copado" — and both
  summary writers are told to spell them as written.
- **Copy follow-up draft.** A button under a meeting's summary copies a
  follow-up email — subject, the overview, the action items as next steps —
  ready to paste into any mail app.

## 2.11.1

Ata as it stands:

- Records any meeting from the menu bar — your microphone and everything your
  Mac plays, two tracks, no bot joining the call — and notices meetings on its
  own when another app takes the microphone.
- Transcribes on this Mac with whisper.cpp or Apple speech recognition, or
  through the OpenAI API if you give it a key. Per-track languages, mixed
  languages in one call, re-transcription with a different model, and the old
  transcript kept beside the new one.
- Summaries with an overview, decisions, action items and open questions,
  written on this Mac by Apple Intelligence or by OpenAI.
- Knows who said what: voices are learned on this Mac, named once, and used in
  every transcript — including ones already written.
- Calendar-aware: offers to record before a meeting starts, files the
  recording under the meeting's own title, and suggests the invited people
  when it asks whose voice it heard.
- Every meeting is a plain folder of Markdown and audio, kept in iCloud if you
  turn that on, with an Insights view over all of them.
- iPhone and Apple Watch companions record in person and sync through iCloud.
- Recordings survive microphone switches, sleep, crashes and power loss;
  audio that comes out the wrong length is caught and reported, in plain
  words, instead of transcribing into nonsense quietly.
