# Changelog

## Unreleased

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
  transcription stopped are removed the next time Ata starts.
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

- **"Allow" under Settings → Calendar now actually asks.** It did nothing at all in 2.11.0:
  macOS will not show the calendar dialog for a notarized app that does not ask for the
  calendar in its entitlements, and it refuses in silence — the button was dead and the
  footnote still said Ata needed permission. If macOS stays silent anyway, Ata now opens
  System Settings → Privacy & Security → Calendars and says so, instead of looking broken.
- `Ata --diagnose` reports the calendar permission.

## 2.11.0

Ata learns a meeting is happening from the microphone, four seconds after it starts — and
knows nothing about it. Your calendar knows all of it an hour ahead: when, what it is
called, and who was asked.

- **Ata offers to record before the meeting starts.** A notification with a Record button,
  as long before as you like. It reads the calendars already in Calendar.app, your Google
  account among them — no account to connect, nothing sent anywhere, and it never writes to
  a calendar. Off until you turn it on in Settings → Calendar.
- **Meetings are filed under their own name.** `~/Documents/Meetings/2026-10-26 10.00.00
  Weekly sync/`, and the window, the transcript and the share filename all say the same. A
  recording Ata started from the microphone is still filed under the app, as before.
- **Who was invited is kept with the recording**, and shown at the top of the meeting.
- **"Who's this?" offers the people who were there.** Instead of typing a name, tap one —
  with the reason beside it: the only other person invited, invited to all three meetings
  you heard this voice in, and so on. Ata never names a voice on its own; every suggestion
  waits for you.
- **One person can have more than one name.** Folding "Rita Alves" into "Rita" used to throw
  "Rita Alves" away, taking with it the one string that would have matched her on the next
  invitation — so the merge made Ata worse at knowing the person you had just identified.
  Both names are kept now, and only the one you chose is ever written in a transcript.
- A block on your own calendar with nobody else on it is not a meeting, and nor is an
  all-day event, one you declined, or one that was called off. None of them prompt.
- Insights still counts your time per app, not per meeting title.

Also in this release, after a report of transcripts coming out as nonsense and recordings
playing back sounding sped up:

- **Changing microphone mid-call no longer risks the recording.** Both the microphone and the
  system-audio tap were set up with a sample-rate format read a moment earlier and then held
  for the whole recording. Plug in AirPods, unplug a dock, let the output device switch, and
  that cached answer stops being true — but audio keeps arriving and gets labelled with it
  anyway, so every sample is converted by the wrong ratio. The result is a recording at the
  wrong speed: unlistenable, transcribed to nonsense, and with nothing anywhere to say so.
  The format now comes with each buffer from the engine itself, and the system tap follows
  its device's format for the life of the recording.
- **And it can no longer be silent.** At the end of every recording Ata compares the audio it
  wrote against the time that passed. Those numbers come from unrelated places and only
  disagree when something converted by the wrong ratio; past a tenth Ata writes what happened
  to the log, in plain words, naming the microphone formats it was handed.
- `Ata --diagnose` reports the system tap's format, so a Mac where this goes wrong can be
  asked directly.

Two things worth knowing. Calendar access on macOS has no read-only tier — reading events
requires full access, which also permits writing; Ata asks for it only when you turn the
feature on, and there is no write call anywhere in its code. And if your Mac and your iPhone
end up on different versions for a while, the older one will quietly drop the extra names a
voice has learned when it next touches that voice; they come back from the other device.
Nothing else is lost, and a voice's own name is never affected.

## 2.10.0

Ata was only ever as reachable as its menu bar icon, and macOS hides the icons that
don't fit. Three ways in that don't depend on finding it.

- **Ata opens like any other app.** Open it from Spotlight, the Finder or the Dock while
  it is already running and its window comes up. It used to do nothing at all, which left
  a hidden icon as the only way in — and no way to reach Settings to fix that.
- **Show Ata in the Dock.** A switch in Settings → Where Ata lives puts Ata in the Dock
  and in ⌘-Tab, like a normal application. With the Dock icon on you can put the menu bar
  icon away; with it off the menu bar icon stays, so Ata is never running with no way in.
  macOS gives an app no say in where its menu bar icon sits or whether it is shown at all
  — only you can move it, by ⌘-dragging it along the bar — so the fix is to be somewhere
  else as well.
- **Record from anywhere.** Set a key combination in Settings and it starts or stops
  recording from whatever app you are in, without going near the icon. It needs no
  Accessibility permission.
- **"Check for updates" can be asked twice.** Once Ata had told you that you were on the
  latest version, the answer replaced the button, so there was nothing left to click: a
  release published an hour later could not be found without quitting the app. The button
  stays now, and a check you ask for goes to the network rather than to a cached answer
  from the minute before.

## 2.9.0

Voice recognition, gone over end to end. It was on in the app and off in practice: a
meeting would come back with everyone under one name, or with no voices at all.

- **Tell Ata your voice by reading a paragraph.** In People, "Record my voice" takes twenty
  seconds and settles it: from the next meeting on, Ata knows you in a room full of people.
  Until now your own voice could only be learned from the microphone track of a call, which
  an iPhone never has — so on a phone it was never learned at all, and every in-person
  meeting fell back to "whoever talked longest is you". Your name sits beside it in the same
  place, so the two things only you can tell Ata are together.
- **Voice recognition is on by default.** It was off unless you found the switch, which is
  why a Mac that had never been told otherwise produced transcripts of "Me" and "Others".
  Fingerprints still never leave the device, or your own iCloud.
- **The speaker Ata guesses is you now has a row you can correct.** It used to be thrown
  away: the person Ata had mistaken for you could never be told apart, named, or marked, and
  the guess repeated itself every meeting. The meeting's People tab now shows that row, says
  it is a guess, and one tap puts it right. If the library recognises a *different* speaker
  as you, the library wins and the guess becomes an ordinary participant — before, both read
  as you.
- **One person is no longer learned twice over, and over.** When the diarizer heard someone
  as two voices, the library held a near-identical pair — and then refused to match either,
  because neither beat the other by enough, so it added a third copy. Every meeting added
  one more, names stopped sticking, and "Who's this?" stayed empty because no copy was ever
  heard twice. Two voices that sound like each other are now read as one person.
- **A quiet participant is a person.** The bar for learning a voice was ten seconds of
  speech across a whole meeting, so anyone who only answered a question — and everyone in a
  short meeting — got no fingerprint, no row and no name: the transcript said "Speaker 2"
  while the People tab said nobody else spoke. It is five seconds now, and every speaker the
  recording found is listed either way, with the truth about why some cannot be named.
- **Your microphone is only learned as you when it really is you.** Three seconds of
  anything playing is enough to make Ata treat a meeting held in the room as a call, and
  there the microphone is the whole room: its loudest speaker was learned as your voice. A
  named colleague could be marked as you and your fingerprint averaged into theirs, with no
  way back. Neither happens now.
- **Something playing in the room is no longer a call.** Three seconds of audible system
  audio was enough to make an hour in a meeting room count as a call — one video, one
  ringtone, one demo — and down that path the microphone is the whole room: everyone in it
  got your name. A call now has to be a share of the recording as well.
- **A system track Ata cannot read is treated as a call, not as silence.** It was the other
  way round, which sent real calls down the in-person path and diarized a microphone holding
  your voice with everyone else's echo over it.
- **Settings says what the OpenAI models cost you.** The model Ata defaults to, `whisper-1`,
  is the oldest of them; the accurate ones return no timestamps, and without timestamps
  voices are not told apart at all — which used to happen in silence. Both are now said
  plainly, next to the choice.
- Apple's speech recognition is offered only where the device can actually run its models,
  not merely where the OS is new enough. An iPhone that cannot is told so, instead of being
  pointed at whisper.cpp, which only the Mac has.
- **Two clusters that are both you are no longer an ambiguity.** When the diarizer split
  your own voice in two, neither half beat the other by the lead Ata asks for, so it gave up
  and fell back to "whoever talked most" — who could be someone else entirely, and then two
  people read as you in the same transcript. Two clusters that sound like each other are one
  person, and the longer one is you.
- A weaker transcription model you picked yourself is still mentioned once in Settings. The
  nudge used to appear only if you had never chosen, so a choice made when Turbo was the
  default was never revisited.

## 2.8.0

Ata on the iPhone catches up with the Mac, starting with the one thing it could never do:
know which voice is yours.

- **Tell Ata which voice is you.** In People, or on a meeting's speaker, mark a voice as
  yourself — and take it back if you tapped the wrong one. From then on Ata knows you in a room
  full of people: your lines are yours, and everyone else is told apart around you. A meeting
  already transcribed keeps the names it was written with; "Transcribe again" redoes it now
  that Ata knows your voice.

  This was the gap behind "it doesn't recognise the voices" on the iPhone. The Mac learns your
  voice from the microphone track of a call; an iPhone records one track, so it has no call to
  learn from, and the in-person recognition deliberately refuses to learn a guess. With no
  fingerprint of you it fell back to "whoever talked longest is you" — in a two-person meeting
  where the other person talked more, that is the wrong person, and nothing could ever correct
  it. Marking a voice once breaks the loop.
- **Voices from a single meeting are listed.** Ata still waits until it has heard a voice in two
  meetings before asking for a name, but a voice heard once is no longer invisible: it has its
  own section, where you can name it — or say it's you. Before, one recording's voices showed up
  in no section at all while the tab counted them, which read as "Ata recognised nobody".
- **Transcribe again in another language** on the iPhone, from a meeting's menu. A transcript
  that came out in the wrong language was unfixable on the phone before.
- **Settings on the iPhone: AI summaries.** The toggle was missing, while summaries were on by
  default — so with Apple Intelligence off, no summary ever appeared and nothing said why. The
  switch is there now, and the reason underneath it when the model can't be used.
- **First run asks your name.** A Mac reads it from your account; an iPhone can't, so every
  transcript said "Me" until you found Settings. It also says, in one line, that Ata tells the
  other people in the room apart.
- Renaming, merging, forgetting and "this is me" are reachable on the iPhone: they were behind
  a right-click, which a phone doesn't have. Each voice row now has a visible menu button, and
  the buttons that only had a Mac tooltip have names VoiceOver can read.
- Fixed: deleting a meeting on the iPhone offered to "Move to Trash" and promised you could get
  it back. An iPhone has no Trash you can open. It now says what actually happens, as the
  meetings list already did.
- Fixed: the People tab could say "Needs macOS 15 or later" on an iPhone.
- Fixed: the meeting screen on the iPhone left a gap below the navigation bar — room for a Mac
  window's title bar, which a phone hasn't got.

## 2.7.1

Fixes for iCloud sync. It is off unless you turned it on in **Settings → iCloud**, and only matters
once a second device shares the meetings.

- Fixed: turning iCloud back on no longer overwrites notes or a transcript the other device changed
  while it was off. If both changed, the newer one keeps its name and the other is saved beside it,
  as `notes (other device).md` for notes.
- Fixed: an open meeting now shows notes edited on the other device. If you were typing at the same
  time, your text is saved and theirs is kept as `notes (other device).md`. Notes still
  downloading from iCloud show as downloading and can't be edited until they arrive.
- Fixed: transcribing a meeting again on the iPhone while its earlier transcript was still in
  iCloud could replace it without keeping it in the meeting's earlier versions. Ata now fetches it
  first; if it can't, it stops and says so, with the audio untouched for another try.
- Fixed: if a device slept mid-transcript and the other took the meeting over, both could finish
  it, and a late failure could replace the finished transcript. Now the device that took over
  finishes alone.
- Fixed: on the iPhone, meetings recorded on the Mac before Ata 2.6 counted as the iPhone's own,
  so its audio settings could compress or delete the Mac's recordings. Copying a library into
  iCloud now records which device made each older meeting.
- Fixed: opening a meeting or the People tab could hang while a file was still downloading from
  iCloud, especially offline.
- Fixed: naming a voice on one device while the other learned more of it no longer loses the name.

### Ata for iPhone and Apple Watch (in development, not released yet)

- **Import audio on the iPhone.** Share a recording to Ata from Voice Memos, Files, Mail or a
  chat, open it in Ata, or tap the import button in Meetings. Each file becomes a meeting and is
  transcribed like a recording. The original is only read; a shared file waits in Ata's inbox
  until its meeting exists, and stays there if the import fails.
- **Ata on the Apple Watch.** Start, stop and bookmark a recording on your iPhone from your wrist,
  with the time running on the Watch. If iOS won't let Ata turn the iPhone's microphone on while
  it's in the background, the Watch says so and offers to record by itself; opening Ata on the
  iPhone first always works.
- **Record on the Watch alone.** With the iPhone out of reach, the Watch records, with the wrist
  down too, and keeps your bookmarks. When the iPhone is back, the recording goes to it and
  becomes a meeting named "Apple Watch", queued for a transcript. The Watch deletes its copy only
  after the iPhone confirms the meeting is saved.
- **Fixed: recordings made on the iPhone never reached your meetings.** Each one stayed in Ata's
  recording folder with "could not be moved" showing, so it lost its bookmarks, got no MP3 and
  never went to iCloud. They move now, and one left behind moves the next time Ata opens.
- **Fixed: an import cut off halfway came back as a short duplicate.** If Ata is closed while it
  decodes a file, the half-made meeting is removed and the file is imported again from where it
  waits (the share sheet's or the Watch's inbox). A finished meeting found in the recording
  folder keeps its transcript instead of being queued again.
- **Fixed: a Watch recording could arrive cut short.** A file whose length the Watch never got to
  write in full is now read to its end before it becomes a meeting, so the Watch never deletes
  audio the iPhone didn't keep.
- **Fixed: Resume on the Watch.** It now resumes a recording on the iPhone too, after a call that
  ended without handing the microphone back. A Watch recording that can't carry on after an
  interruption stays paused with Resume showing, and one stopped by the audio system restarting
  is finished and sent, with everything recorded until then.
- **Fixed: the library could switch to or from iCloud during a Watch import**, and the Watch's
  confirmation that a recording had arrived could be lost if it came while the connection to
  the Watch was still starting.

## 2.7.0

- **Keep meetings in iCloud.** A new switch in **Settings → iCloud**, on the Mac and the iPhone,
  puts your meetings and voices in iCloud Drive, so a meeting recorded on one shows up on the
  other, notes and names included. It's off until you turn it on.
- **Nothing is moved until it's checked.** Turning it on copies every meeting into iCloud and
  compares each file, byte for byte, before Ata switches to the copy. If the copy is cut short,
  it carries on the next time Ata opens. On the Mac the originals stay in
  `~/Documents/Meetings` until you remove them; Settings shows where. On the iPhone each one is
  removed only once its copy has been uploaded.
- **Only what you open is downloaded.** Transcripts and notes come down as soon as they appear;
  a meeting's audio is downloaded when you play it or it's transcribed. A meeting still on its
  way shows as "Downloading from iCloud…" instead of missing from the list.
- **Two devices, one meeting.** Only one device transcribes a meeting, and only the device that
  recorded it compresses or deletes its audio. Notes edited on both at once are both kept: the
  newest as `notes.md`, the other as `notes (other device).md`.
- Your name, language, summary engine and voice recognition follow you between devices too,
  where iCloud's settings sync is available to Ata.
- On the Mac, iCloud needs Ata on your iPhone to have turned it on first: the Mac then uses the
  same iCloud Drive folder.

## 2.6.0

- **Transcribe with Apple's speech recognition.** On macOS 26, **Settings → Transcription** has a
  third engine, **On this Mac (Apple)**: free, nothing leaves the Mac, and no whisper.cpp to
  install. macOS downloads the speech model for each language the first time, or when you click
  **Download speech model**. Every word keeps its time, so following along, the speaker split and
  echo removal work as with whisper.cpp.
- **Portuguese and English in one call, with Apple's engine too.** With the language on
  **Automatic**, Ata transcribes the track in each of your languages and keeps, for every stretch
  between pauses, the one it was spoken in.
- A language Apple's recognizer doesn't offer yet fails with a clear message and keeps the audio,
  so you can transcribe it again with whisper.cpp.
- **Conversations in the room.** With voice recognition on, a meeting recorded on the microphone
  alone, with nothing coming through the speakers, now tells the people in the room apart. Ata
  finds you by the voice it learned from your calls; until it knows your voice, whoever spoke
  most is you. Everyone else gets a voice to name, as on a call.
- **Voices stored one file per voice.** Your voice library moves from one file to a file per
  voice, so a change to one voice never touches the others, ready for syncing between devices.
  The move happens once, by itself, and the old file is kept.
- **Mark a moment.** While recording, press the bookmark button in the menu, or ⌘B, to mark
  what was just said. Marks show as flags on the meeting's waveform and as a list in the Notes
  tab, where clicking one plays from there. The transcript gets a **Moments you marked**
  section with the time and the words being said.
- **Import audio.** Choose **Import audio…** in the menu, or drop audio files on it, to
  transcribe a voice memo or any recording made elsewhere. Each file becomes a meeting, named
  after the file and dated when it was made, and goes through the same queue. The file itself
  is only read, never moved or changed.
- **Ready for more than one device.** Each meeting now records which device made it, and a
  device says when it's transcribing one, so two devices sharing the meetings folder never
  transcribe the same meeting twice or touch each other's audio. A recording is written
  outside the meetings folder and moved in whole when it stops, so a synced folder never holds a
  half-written file. If the move fails, the meeting stays listed and the move is tried again at
  the next launch.
- **Ata for iPhone is in development**, built from the same code as the Mac app: recording with
  the screen locked, starting from the Action button, Control Center, Siri or a widget, and the
  recording on the lock screen with Stop and Bookmark. Not released yet.

## 2.5.0

- **Follow the meeting word by word.** While a meeting plays, the word being said is highlighted
  in the transcript, the words still to come are dimmed, and the view scrolls along. Click any
  word, or a timestamp, to jump the audio there. Meetings transcribed earlier work too, with
  estimated word times.
- **See who spoke when.** The player's bar becomes a waveform: the others above the line, you
  below, each in their colour. Click or drag to jump; hover to see the time. Your lane comes from
  the microphone with the others taken out, so only your voice shows there.
- **Summaries on this Mac.** With Apple Intelligence (macOS 26), the summary and **Write notes**
  are written by Apple's on-device model: free, and nothing leaves the Mac. Long meetings are
  summarized in parts and then combined. Older Macs, or languages Apple's model doesn't write
  yet, keep using OpenAI. Choose the engine in **Settings → Transcription**.
- **Voices you don't want.**
  - **Don't ask about this voice** stops Ata asking for a name.
  - **Leave out of transcripts** drops a voice's lines from every transcript, past ones
    included, for a TV in the background, a meeting bot, or someone who asked not to be
    transcribed. The recording itself is untouched, and both can be undone from **Hidden
    voices** in the People tab.
- OpenAI's whisper-1 now returns word times too.

## 2.4.2

- **Fixed: switching between Portuguese and English in the same call.** Ata picked one language
  per track, so once you switched, whatever you said in the other language came out garbled or
  even translated.
- **How it works now:** each stretch of speech gets its own language. Ata cuts the track at
  pauses, detects the language of each piece in a single pass, and transcribes every run in the
  language it was spoken. It never translates.
  - A language only counts when Whisper is sure, it's one of your Mac's languages, and it lasts
    at least 3 seconds, so a short "okay" doesn't switch.
  - A call in one language is transcribed exactly as before.
- This is for the local engine with the language set to Automatic. With OpenAI, Automatic
  already lets OpenAI detect the language.

## 2.4.1

- **Fixed: without headphones, the others' words showed up as yours.** Your microphone hears
  the other participants through the Mac's speakers, and Ata transcribed them a second time
  under your name. The old fix compared words after transcribing, and missed the echo whenever
  it was misheard or came out in another language.
- **How it's fixed:** Ata now takes the others out of a copy of your microphone track before
  transcribing, using what your Mac played as the reference.
  - It finds the delay and the room's echo, and corrects drift between the microphone's clock
    and external speakers.
  - With headphones it finds no echo and leaves your microphone exactly as recorded.
  - The recording itself is never changed.
  - In tests with real speech, the echo dropped 31–36 dB while only the others spoke, and your
    own speech was left intact, even when you spoke over them.
- **Transcribe again** applies the fix to older meetings too. It can be turned off in
  **Settings → Transcription**.

## 2.4.0

- **Every meeting in its own window.** Click a meeting in the menu to listen to it, read its
  notes and transcript, and name the people in it:
  - a player with ±15 s skips and 1×–2× speed; click any line of the transcript to play from
    there, and the line being heard is highlighted as you listen;
  - **Notes**: the AI summary, or **Write notes** to create one for a meeting transcribed without
    it (sends the transcript text to OpenAI, never the audio), plus your own notes, saved as
    `notes.md` in the meeting folder;
  - a searchable transcript;
  - **People**: every voice in the meeting, with a play button and a name field, so a voice heard
    only once can be named too;
  - **Share** the audio, the transcript, the notes, or audio and transcript together, through
    AirDrop, Mail, Messages or any app's share extension; the files are named after the meeting.
    Drag the MP3 out of the player straight into another app;
  - copy the transcript or notes, **Save as MP3…**, transcribe again, or delete.
- **The whole meeting as one MP3.** Ata mixes your microphone and the others into
  `meeting.mp3` next to the transcript (48 kbps, about 21 MB an hour) as soon as a recording
  stops, so you can listen before the transcript is ready. The separate tracks are kept for
  transcribing again. **Meetings recorded before 2.4 get theirs too**: after updating, Ata works
  through your history in the background, newest first, one meeting at a time — and any meeting
  whose audio is still there can be heard, shared and saved as MP3 from its window right away.
  Off in **Settings → Audio** if you'd rather not.
- **Choose how the menu bar icon looks while recording**, in **Settings → Menu bar**: a record
  dot, a waveform, a microphone or Ata's glyph; in the menu bar's colour, red, or your accent
  colour; with or without the timer; pulsing or still. Transcription progress can be hidden too.
- The "Transcript ready" notification opens the meeting window.
- MP3 encoding uses [LAME](https://lame.sourceforge.io) 3.100, built in from source.

## 2.3.1

- **Fixed: Ata kept asking for system-audio permission you had already given.** It recorded
  system audio through screen capture, which needs *Screen Recording* and is only reported as
  granted after a relaunch. Ata now records system audio with Core Audio under the audio-only
  **System Audio Recording Only** permission — never your screen — asks once, and restarts
  itself once right after you allow it. Requires macOS 14.2.
- **Fixed: a keychain password prompt could block Ata at launch.** Checking whether an OpenAI
  key was stored read the key itself, which macOS can answer with a keychain prompt; Ata now
  only reads the key when it calls OpenAI.
- A damaged audio file now fails with an error instead of giving a shorter transcript.
- Summaries are written in your language and region: European Portuguese in Portugal.
- From a full review:
  - discarding a recording could make the next one stop itself after 10 seconds;
  - meetings stayed queued after a model download until the next recording;
  - with OpenAI, one silent stretch erased every timestamp, and models without timestamps
    could attribute ten minutes of speech to one named person; long chunks for the
    gpt-4o models could be cut short;
  - OpenAI rate limits and server errors are retried instead of failing the meeting;
  - quitting mid-transcription no longer leaves whisper-cli running, and the meeting is
    transcribed on next launch;
  - the updater no longer freezes the menu, won't restart during a recording, and won't
    install a release your macOS can't run;
  - audio retention and update checks run every few hours, not only at launch;
  - deleting a meeting removes it from the voice library; an unreadable library is never
    overwritten; an empty name shows as "Me"; update errors appear in the menu.
- `Ata --diagnose` prints what Ata can access and records five seconds of each track, for bug
  reports.

## 2.3.0

- **Know who said what.** Turn on voice recognition in the new **People** tab and Ata tells the
  other participants apart, learns their voices across meetings, and asks about a voice once it
  has heard it twice: play a short sample, type a name, and every transcript — past ones
  included — uses it. Unnamed voices keep a stable number ("Voice 3") everywhere.
- Lines are split where the speaker changes, word by word, rather than following Whisper's
  segments, which run across turns.
- Merge two voices that are the same person, rename, forget one or all.
- All on this Mac: voice fingerprints and samples never leave it, even when OpenAI transcribes.
  The first time it runs, Ata downloads 21 MB of on-device models
  ([FluidAudio](https://github.com/FluidInference/FluidAudio), Core ML). Off by default; needs
  macOS 15, since an Apple bug in macOS 14 crashes the pipeline.
- **Fixed: updating left the old copy running.** It hung while quitting, so two Ata icons sat in
  the menu bar after an update. Ata now quits cleanly, and on launch it ends any stale copy left
  behind by an update from 2.1 or 2.2. Updates also wait until a recording has finished.
- `Ata.app/Contents/MacOS/Ata --update-now` checks for and installs an update without the UI.
- Transcripts are now also saved as `transcript.json` (segments with speaker labels), so names
  can change without transcribing again.
- For contributors: FluidAudio is the project's first dependency; Package.swift now uses tools
  6.2 (Xcode 26), and every `swift` command takes `--disable-keychain`.

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
