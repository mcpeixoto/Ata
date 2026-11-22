# Ata 4.0 — UI/UX redesign, onboarding (Mac + iPhone), and paid conversion

## Context

Ata (meeting recorder: Mac menu bar app + iPhone app) is live on the App Store and the owner is
about to start advertising. Today it works but does not *sell*: the iPhone Record tab is one
button on an empty page, the Mac "main window" is the popover stretched, Mac onboarding is three
text paragraphs, Settings is one 11-section scroll, and the paywall is a single €2.99/month plan
with no trial, shown only when the limit is hit. The goal is an app that looks worth paying for
and uses the standard (honest) conversion mechanics.

Owner decisions (2026-11-22, this session):

| Topic | Decision |
|---|---|
| Free tier | 300 minutes/month (from the Cursor session), same limit on Mac and iPhone |
| Pro on Mac | iPhone subscription unlocks the Mac through iCloud **and** a licence key bought through the owner's **Stripe** for Mac-only users (no Lemon Squeezy). Agent sets up Stripe and App Store Connect itself |
| Plans | Monthly €6.99 + Yearly €44.99 (≈ €3.75/mo, save 46 %) with 7-day free trial on yearly, yearly pre-selected; optional Mac-only lifetime licence €99. Existing €2.99 subscribers keep their price (new-subscriber-only price change). Reason: at €24.99/yr paid ads cannot pay back (CAC per payer ≈ €40–150) |
| US pricing | Same numbers in dollars: **$6.99/mo, $44.99/yr, $99 lifetime (Mac licence)**. US is a main market. USD is the App Store Connect base price, and eurozone storefronts are pinned by hand to €6.99 / €44.99 so Apple's auto-equalisation doesn't drift them to odd amounts. US prices are before sales tax and EU prices include VAT, so a US sale nets ~20 % more. Test $7.99/mo / $49.99/yr in the US after 1–2 months only if revenue per install data supports it |
| Paywall placement | Last onboarding step, skippable, plus contextual prompts (80 % used, after first transcript, at limit) |
| iPhone Record tab | "Living home": greeting, hero button, live transcription status, recents, quota meter |
| Pro value | Pro is more than "no limit": **new** Pro-only features (Track 10). Nothing free today becomes paid |
| Measurement | Opt-in funnel counters in the existing daily ping + Apple Search Ads attribution (Track 1 §5, Track 11) |
| Rejected (owner, 2026-11-22) | Grandfathering existing Mac users; shipping iPhone first before ads; any scope cut (5-step onboarding, licence later, audio-less sample) — the plan ships in full |

Hard limits for every track: no dark patterns (close button always visible, price and renewal
terms on screen, Restore Purchases present, "Continue free" is a real button). Audio is sacred
(never delete on a failure path). Every string in **both** `en.lproj` and `pt.lproj`
(plus `Resources/iOS/*` when iPhone-only). Colours/type/spacing only from `Theme`, `ataFont`
modifiers, `Radius`, `Space`, `Components.swift`.

## Audit of the Cursor session "ATA app meeting limit"

What the owner asked: (1) 5 meetings/month feels low → (2) switch to a minute cap, "5 hours, shown
as a round number of minutes" → (3) build "300 minutos grátis no iPhone" → (4) "e sobre o Mac vamos
pôr o mesmo limite". Also asked how to get a free subscription for himself (answer given: 1-year
offer code in App Store Connect; no code change — still to do by hand).

State: **nothing shipped.** All work is uncommitted in
`.claude/worktrees/free-quota-minutes` (branch `feat/free-quota-minutes`, 18 files, +328/−176,
`Sources/AtaiOS/QuotaLedger.swift` moved to `Sources/Ata/QuotaLedger.swift`). Docs edited
uncommitted in `~/Documents/Coding/AtaSite` (`MODEL.md`, `DECISIONS.md`, `LAUNCH.md`).
App Store still has the 5-meeting limit.

| Planned | Done? | Problem to fix in Track 0 |
|---|---|---|
| 300 min/month iPhone, rounded up on the total | yes | comment says "no audio does not count" but code counts any `duration > 0` |
| Ledger in seconds, old lines still read, delete never refunds | yes | — |
| Running recording never cut; next start blocked | yes | — |
| Import blocked at limit | yes | `drainShareInbox` runs on every `becameActive` → paywall reopens every foreground (nag loop) |
| EN + PT strings | yes | Mac "Free minutes" label needs checking in both tables |
| Tests | counting only (14) | no test for the gate itself on either platform; snapshots not regenerated |
| Same limit on Mac | yes, but **broken product-wise** | Mac has no purchase and no Pro check → iPhone subscribers are blocked on Mac, Mac-only users hit a wall with nothing to buy. Contradicts `DECISIONS.md` "one Ata Pro for Mac and iPhone" |
| — | — | Mac reads the keychain ledger on every reload/start/import → risk of keychain prompts (`Keychain.swift` warns about this) |
| — | — | At the limit the Mac "meeting detected" notification still offers Record, which then fails |
| — | — | `chooseAudio` doc comment landed on the new `freeMinutes` view in `PopoverView.swift` |

Verdict: iPhone part matches the plan. Mac part does what was said literally but cannot ship
until the Mac can unlock Pro (Track 2). Track 0 lands the work with the Mac wall switched off.

## Handoff notes for the implementing model

- **Step 0:** copy this file to the repo as `docs/plans/2026-11-22-ata-4-redesign-onboarding-pro.md`
  (in its own `docs/` PR, or as the first commit of Track 1) so every worktree has it.
- Run the waves in order; inside a wave, tracks run in parallel (max 3 Grok jobs at once, per the
  owner's global rules; the rest go to the Opus fallback or wait).
- Track 0 runs inside `.claude/worktrees/free-quota-minutes`, not a fresh worktree — the Cursor
  diff only exists there, uncommitted. Do not lose it: commit it there first.
- Four items say "verify against current docs" (Stripe Checkout/webhooks, App Store Connect API
  pricing endpoints, AdServices attribution API, FoundationModels API): check the docs before
  coding, do not trust the shapes written here.
- Money-touching scripts (`asc-pricing.py`, Stripe setup) run `--dry-run` first and the agent
  reads the output before `--apply`; no real card is charged.
- Track 11's Worker source location is unknown; finding it is step 1 of that track. If it can't
  be found, the app side (Track 1 §5, `Attribution.swift`) still ships — old servers ignore the
  optional fields.
- **Copy:** the mock text is direction, not final. Each track lists every new EN+PT string in its
  PR body. PRs still merge on green (repo rule); the owner reviews the collected copy list once,
  before Wave D's 4.0.0 tag — that is the single approval gate for wording.
- No owner-only setup: Stripe (key on this Mac/VPS) and App Store Connect (API key on this Mac)
  are done by the agent. Every track still builds and passes with `AtaLicenceURL` empty.

## Architecture decisions (read before any track)

1. **One entitlement model, shared.** New `Sources/Ata/ProAccess.swift` (compiled on both
   platforms): `@MainActor final class ProAccess: ObservableObject` with
   `@Published private(set) var isPro: Bool` and `sources: Set<Source>` where
   `enum Source { storeKit, iCloudMirror, licence }`. Everything that gates asks
   `ProAccess.shared.isPro` — `PhoneStore.needsPro`, Mac `AppStore.atFreeLimit`, UI.
   - iPhone: `ProStore` (existing, `Sources/AtaiOS/ProStore.swift`) stays the StoreKit owner and
     pushes into `ProAccess` (`setStoreKit(active:expires:)`).
   - Mirror: on every `ProStore.refresh()` the iPhone writes
     `NSUbiquitousKeyValueStore.default` key `proUntil` (Double, epoch seconds of the entitlement's
     `expirationDate`; `0` when not Pro). The Mac reads it at launch and on
     `didChangeExternallyNotification` and treats Pro as active while `now < proUntil + 3 days`
     (grace, because the phone only rewrites it when opened). KVS is already used by both apps
     (`Sources/Ata/CloudLibrary.swift:1150`) and the Mac entitlement
     `com.apple.developer.ubiquity-kvstore-identifier` is already in `Resources/Ata-iCloud.entitlements`.
     Ad-hoc Mac builds have no KVS: mirror reads as not-Pro, never crashes.
   - Licence (Mac only, `#if os(macOS)`): `Sources/Ata/Licence.swift`, paid through the
     owner's **Stripe** (owner decision 2026-11-22 — no Lemon Squeezy). Stripe has no licence
     keys, so a small Cloudflare Worker `ata-licence` (Track 2b) issues and checks them; the
     Stripe secret key lives only in that Worker, never in the app. App ↔ Worker API
     (JSON over HTTPS, base URL in Info.plist `AtaLicenceURL`):
     `POST /v1/activate {key, instance_name}` → `{ok, instance_id, status, plan, expires_at|null}`,
     `POST /v1/validate {key, instance_id}` → same shape, `POST /v1/deactivate {key, instance_id}`.
     `status ∈ active|past_due|canceled|refunded`; `active` and `past_due` unlock. Max 3 instances
     per key. Persist `{key, instanceID, lastValidated, status, expiresAt}` as JSON in
     `Paths` support dir (`licence.json`, 0600) — not the keychain (prompt risk). Revalidate at
     most once per 7 days; offline grace 30 days from `lastValidated`. Checkout: the app opens
     `AtaLicenceURL/buy?plan=monthly|yearly|lifetime` which redirects to a Stripe Checkout
     Session. After payment the success page shows the key and an **Activate in Ata** button
     (`ata://licence?key=…` URL scheme registered in `Resources/Info.plist`, handled in
     `App.swift` → `LicenceStore.activate`), so the buyer never types it. Lost key: "Email me my
     key" on the Mac paywall → `POST /v1/recover {email}` → Worker emails the key(s) for that
     Stripe customer (Cloudflare Email Sending), always answering 200 so it can't be used to
     probe emails.
   - A web licence unlocks the Mac only. The iPhone never mentions or links to web purchase
     (App Review 3.1.1). All licence UI is behind `#if os(macOS)`.
   - Honest note: the Mac app is open source; the gate is a nudge, not DRM. No obfuscation work.
2. **Quota off on Mac until it can be unlocked.** `FreeQuota.appliesOnMac` is a
   `static let`; Track 0 sets it `false`, Track 2 flips it to `true` in the same PR that ships the
   mirror + licence + Mac paywall.
3. **Quota reads are cached.** `QuotaLedger` gets an in-memory cache loaded once per launch and
   updated on write; no keychain read on reload/start/import paths.
4. **Onboarding step is persisted** (`Pref.onboardingStep`, Int) on both platforms so the Mac's
   automatic relaunch after the system-audio grant returns to the same step. `Pref.onboarded`
   stays the single "finished" flag; existing users (already `onboarded`) never see the new flow.
5. **Strings file is the merge hotspot.** Each track appends its keys in one block at the end of
   each `.strings` file under a `/* Track N */` comment; on conflict keep both blocks.
   `scripts/check-localization.sh` fails on unused keys, so add keys only with the code using them.

## Tracks and order

```
Wave A (serial, first):   Track 0  land quota work        → release 3.10.0
                          Track 1  shared foundations     (no user-visible change)
Wave B (parallel, 5 worktrees, after Track 1 merges):
   Track 2  Pro on Mac (mirror + licence + Mac paywall + flip appliesOnMac)
   Track 2b Stripe products + ata-licence Worker (server/licence/)
   Track 3  iPhone plans + paywall + contextual prompts
   Track 4  iPhone onboarding
   Track 5  iPhone Record home
   Track 6  Mac onboarding
   Track 11 metrics Worker + attribution (other repo/Worker; can start right after Track 1)
Wave C (parallel, after Wave B merges):
   Track 7  Mac popover + library window
   Track 8  Mac Settings split
   Track 9  empty states, sample meeting, review prompt, polish sweep
Wave C2 (after Track 8 merges):
   Track 10 Pro-only features (custom templates, Ask your meetings, PDF/DOCX export)
Wave D:  release 4.0.0 (Mac release-local.sh + iPhone release-ios.sh), live checks,
         App Store listing/screenshots (owner approves text before submit)
```

File ownership (no two tracks in a wave edit the same file, except `.strings` and
`Snapshots.swift`/`PhoneSnapshots.swift`, where each track only appends):

| Track | Owns |
|---|---|
| 2 | `ProAccess.swift` (extends), `Licence.swift` (new), `MacPaywall.swift` (new), `AppStore.swift` gate lines, `FreeQuota.swift` flag, `Notifier.swift` limit text |
| 2b | `server/licence/**`, the Worker's CI job in `.github/workflows/` (new file) |
| 3 | `scripts/asc-pricing.py` (new), `ProStore.swift`, `Paywall.swift`, `ios/Ata.storekit`, `PhoneDecisions.swift` (prompt rules), `PaywallUITests.swift` |
| 4 | `PhoneOnboarding.swift`, `OnboardingFlowUITests.swift`, `OnboardingPermissionUITests.swift` |
| 5 | `RecordView.swift`, new `RecordHome*.swift` |
| 6 | `OnboardingView.swift`, `FirstRun.swift` |
| 7 | `PopoverView.swift`, new `LibraryWindow.swift`, `App.swift` (`showMain`) |
| 8 | `SettingsView.swift` → `Settings/*.swift` |
| 9 | `MeetingsList.swift`, `InsightsView.swift`, `PeopleView.swift` empty states, `SampleMeeting.swift` (new) |
| 10 | `Summarizer.swift`, new `CustomTemplates.swift`, `AskMeetings.swift`, `DocumentExport.swift`, `MeetingView.swift` menus, the Settings Transcription pane from Track 8 |
| 11 | the metrics Worker source (find it first, see Track 11), `Sources/AtaiOS/Attribution.swift` (new), `docs/privacy.md` |

Every track emits its funnel counters through `Funnel.count(_:)` (Track 1 §5); adding a call
is allowed in any file a track owns.

Each track = one worktree off `origin/main` (`.claude/worktrees/<slug>`, branch `feat/<slug>`),
one PR, CI green, squash-merge (repo §5). Implementation is delegated per the owner's global
rule (Grok via `agent -p`, max 3 at once, one brief ≈ 20 min; each numbered step below is sized
to be one brief). The orchestrator reviews the test diff first, runs the gates, commits, merges.
Pre-existing tests and existing user-facing strings are changed only where a track says so
below, and each such change is listed in the PR body.

---

## Track 0 — land the quota work (release 3.10.0)

Work happens **inside** `.claude/worktrees/free-quota-minutes` (open the session there; a hook
blocks edits in sibling worktrees). The diff is already there, uncommitted.

1. `Sources/Ata/FreeQuota.swift`: add `static let appliesOnMac = false`. In
   `Sources/Ata/AppStore.swift`, `atFreeLimit` returns `false` when `!FreeQuota.appliesOnMac`;
   the popover `freeMinutes` counter and the Settings row are hidden under the same flag.
   Fix the "no audio does not count" comment to match the code. Move the stray `chooseAudio`
   doc comment back in `PopoverView.swift`.
2. `Sources/Ata/QuotaLedger.swift`: add the in-memory cache (decision 3).
   Test: `QuotaLedgerCacheTests` — second `entries()` call does not hit the store (inject a
   counting store).
3. `Sources/AtaiOS/PhoneStore.swift` `drainShareInbox`: at the limit, present the paywall at
   most once per app launch (`private var offeredProForInbox = false`); files stay in the inbox;
   Meetings shows a `Banner(kind: .info)` "N shared recordings are waiting — Ata Pro or next
   month" with action → paywall. Test in `ios/Tests/PhoneDecisionsTests.swift`
   (`InboxOffer.shouldPresent(alreadyOffered:atLimit:pending:)` as a pure function in
   `PhoneDecisions.swift`).
4. Gate tests: `PhoneDecisionsTests` — `RecordingStart.begin` throws at 300 min and not at 299;
   `FreeQuotaTests` — Mac never at limit while `appliesOnMac == false`.
5. Update `ios/UITests/PaywallUITests.swift` expectations (already "0 of 300 free minutes left
   this month" in the diff; confirm). Run the full Verify block + `./scripts/snapshots.sh`, look
   at the PNGs, commit them.
6. Commit, PR, merge. Bump `Resources/Info.plist` to 3.10.0, CHANGELOG, tag, run
   `./scripts/release-local.sh v3.10.0` and `./scripts/release-ios.sh v3.10.0`, Live check.
7. AtaSite repo: separate worktree off its `origin` default branch, re-apply the three doc edits
   there (do not commit on its stale `main`), PR, merge. Update the App Store Connect description
   line about the free tier (show the owner the exact text first).
8. Owner's own free Pro: 1-year offer code, created by the agent with `scripts/asc-pricing.py`
   (Track 3 step 1; if Track 3 hasn't started, do just this part in Track 0). Give the owner
   the redemption link; redeeming with his Apple ID is his tap.

## Track 1 — shared foundations (no visible change)

New/extended shared pieces, each with a unit or snapshot test, so Wave B tracks only compose:

1. `Sources/Ata/ProAccess.swift` — the class from decision 1 with `storeKit` and `iCloudMirror`
   sources (licence comes in Track 2). `ProStore` pushes into it; `PhoneStore.needsPro` reads it.
   `ProMirror` (same file): `write(proUntil:)`, `read() -> Date?`, `isActive(now:)` with the
   3-day grace. Tests `ProAccessTests`: grace boundary, `0` means not Pro, any source ⇒ Pro.
2. `Sources/Ata/Components.swift` additions (all tokens from `Theme`):
   - `PrimaryButtonStyle` — full-width capsule, `Theme.brand` gradient fill, `Theme.accentInk`
     text, 50 pt tall on iOS / 32 pt on Mac, pressed = 0.97 scale. `SecondaryButtonStyle` —
     same shape, 6 % fill, accent text.
   - `StepDots(count:current:)` — capsule dots, current one is 18 pt wide in `Theme.accent`.
   - `QuotaMeter(usedMinutes:limitMinutes:)` — 6 pt capsule bar; fill `Theme.accent` below 80 %,
     `Theme.warning` from 80 %, with the label "212 of 300 free minutes" (existing key style).
   - `PlanCard(title:price:detail:badge:selected:action:)` — radius `Radius.large`, 2 pt
     `Theme.accent` stroke when selected, optional badge capsule ("Save 46 %", text computed by the caller from product prices).
   - `HeroRecordButton(size:state:action:)` where `state` is `.idle/.busy/.recording`; idle shows
     a breathing ring (`Theme.recordingSolid` at 25 % opacity, 1.0→1.15 scale, 2.4 s, off under
     Reduce Motion and when `Snapshots.rendering`). Replaces the hand-rolled 120 pt circle in
     `RecordView` and (size 64) the Mac `RecordButton` body.
   - `OnboardingScaffold(step:count:back:content:footer:)` — header (Back, `StepDots`), scrolling
     content, pinned footer; used by both onboardings.
   - Use the shared `Card` in `RecordView.idleCard` and `PermissionCard` instead of copies.
3. `Tests/AtaTests/DesignSystemTests.swift`: add `Sources/AtaiOS/RecordView.swift`,
   `PhoneOnboarding.swift`, `Paywall.swift`, `Sources/Ata/OnboardingView.swift` to the ratchet
   with their current counts as ceilings (new entries only; existing ceilings untouched).
4. `Pref.onboardingStep`, `Pref.proPromptLastShown`, `Pref.proPromptCount`,
   `Pref.firstTranscriptCelebrated`, `Pref.useCase` in `Sources/Ata/Paths.swift`.
5. Funnel counters, in `Sources/Ata/Metrics.swift` (149 lines). Keep its model: one anonymous
   daily ping of **aggregate counters**, opt-in (`Pref.shareUsage`), own random id, and nothing
   sent before `Pref.onboarded` (the user has not been told yet; `Metrics.due` line 48). No
   event stream, no meeting content, no timestamps finer than the day.
   - `enum Funnel { case onboardingStep(Int), paywallShown(Trigger), trialStarted,
     purchased(Plan), limitHit, featureLocked(ProFeature), firstTranscript }` with
     `Trigger { onboarding, eightyPercent, firstTranscript, limit, settings, feature, recordHome }`.
   - `Funnel.count(_:)` increments `Pref.d` integer keys `funnel.<name>` (only when
     `Metrics.isOn`); `onboardingStep` stores the **highest** step reached, not a count.
   - `Payload` gains `funnel: [String: Int]?` (optional so old servers ignore it, and keys
     capped to the known set) and `campaign: String?` (Track 11). `Metrics.sent` subtracts what
     was sent, the same way it already does for `meetings`/`minutes`; `forget` clears them.
   - Known gap, stated in the code comment: people who quit onboarding before finishing never
     send anything. That drop-off is read from App Store Connect App Analytics (installs vs.
     sessions) instead — no pre-consent ping.
   - Tests in `Tests/AtaTests/MetricsTests.swift` (new cases only): off ⇒ nothing counted;
     highest step kept; subtraction after `sent`; unknown keys dropped; `forget` clears funnel.

## Track 2 — Pro on the Mac

1. `Sources/Ata/Licence.swift` (`#if os(macOS)`): `LicenceStore` (activate / validate /
   deactivate / persisted state per decision 1) with the HTTP call behind a protocol
   `LicenceAPI` so tests inject a fake. Feeds `ProAccess` source `.licence`.
   Tests `LicenceTests`: `canceled`/`refunded` ⇒ not Pro, `past_due` ⇒ Pro; `ata://licence?key=`
   URL parsed and activated; malformed key rejected before any network call; offline within
   30 days ⇒ still Pro, after ⇒ not; revalidation not more than once per 7 days; a failed network
   call never clears a valid licence.
2. `ProAccess` on Mac: start the KVS observer; `isPro = mirror.isActive || licence.isActive`.
3. `Sources/Ata/MacPaywall.swift` — a sheet/window (440×560) opened by
   `WindowManager.showPro()`:

```
┌──────────────────────────────────────────────┐
│                [Ata glyph 56]                │
│                  Ata Pro                     │
│     Unlimited meetings on Mac and iPhone     │
│  ┌────────────────────────────────────────┐  │
│  │ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░  300 of 300 min   │  │  QuotaMeter
│  └────────────────────────────────────────┘  │
│  ✓ No monthly limit                          │  Feature rows
│  ✓ Still transcribed on your Mac, private    │
│  ✓ One subscription, both devices            │
│                                              │
│  ┌─ Have Ata on iPhone? ──────────────────┐  │
│  │ Subscribe there; this Mac unlocks by   │  │
│  │ itself through iCloud.   [How it works]│  │
│  └────────────────────────────────────────┘  │
│  [  Get Ata Pro for Mac — $3.75/mo   ]       │  PrimaryButtonStyle → AtaProCheckoutURL; price string from Info.plist per currency, never computed
│  [  I have a licence key              ]      │  expands a field + Activate + "Email me my key"
│        Resets on 1 December · Not now        │
└──────────────────────────────────────────────┘
```
   States: activating (spinner in the button), invalid key (`Banner .danger` with the server's
   reason mapped to 3 localized messages: not found / expired / used on too many Macs), active
   ("Ata Pro is active on this Mac" + Deactivate).
4. Gate: flip `FreeQuota.appliesOnMac = true`. `AppStore.atFreeLimit = !ProAccess.isPro && used ≥ 300`.
   Blocked start/import calls `WindowManager.showPro()` instead of only the error banner.
   `Notifier` meeting-detected notification at the limit: body "You've used this month's free
   minutes" and the action opens the paywall (no Record action).
5. Settings gets an "Ata Pro" section (Track 8 moves it into its own pane): status line
   (Free · 212 of 300 min / Active via iPhone / Active via licence until …), Upgrade, Enter
   licence key, Deactivate.
6. Snapshots: register `pro-limit` and `pro-active` in `Sources/Ata/Snapshots.swift`.
7. Until `AtaLicenceURL` is set in Info.plist the "Get Ata Pro for Mac" button and the licence
   field are hidden and only the iPhone route shows — the build must work that way, so Track 2
   does not wait for Track 2b.
8. Update AtaSite `DECISIONS.md`/`MODEL.md`: web licence = Mac only; iPhone subscription = both;
   payments through Stripe.

## Track 2b — Stripe products + `ata-licence` Worker (agent does all of it)

Runs in parallel with Track 2. The Worker lives in this repo at `server/licence/` (TypeScript, `wrangler.toml`, own `package.json`, tests with
`vitest` + `@cloudflare/vitest-pool-workers`). Add a CI job for it on GitHub-hosted runners
(Ata is public, §4). `wrangler` is installed on this Mac.

1. **Find the Stripe key.** The only key on this Mac is a **test** key in
   `~/Documents/Coding/ReceiptTracker/.env` (`STRIPE_SECRET_KEY`, `sk_test_…`) — use it for
   development. The live key is on the VPS (owner said "this computer or VPS"): check the
   servers listed in `~/.ssh/config` for `.env` files and
   Worker secrets, grepping **names only**, never printing values. Before using it, confirm via
   `GET /v1/account` that it is the owner's business account (Peixoto Labs / Miguel Peixoto) and
   not a client's; if two accounts exist, ask the owner which one. Never commit or echo a key.
2. **Create in Stripe** (API, live and test, idempotent by `lookup_key`): product "Ata Pro for
   Mac"; prices `ata_mac_monthly` USD 6.99 recurring month with `currency_options.eur = 6.99`,
   `ata_mac_yearly` USD 44.99/year with `eur = 44.99`, `ata_mac_lifetime` USD 99 one-time with
   `eur = 99`. Stripe Tax on (`automatic_tax`) if the account has it enabled; otherwise prices
   are tax-inclusive in EUR and say so. Customer portal configuration enabled (cancel, update
   card). Store the price ids as Worker vars, not in the app.
3. **Worker endpoints:** `GET /buy?plan=` → creates a Checkout Session (`mode` subscription or
   payment, `success_url=/thanks?session_id={CHECKOUT_SESSION_ID}`, `allow_promotion_codes`,
   `customer_creation=always`) and 303-redirects. `GET /thanks` → fetches the session, shows the
   key + Activate in Ata button + portal link (plain HTML, Ata brand colours). `POST /webhook`
   (verify `Stripe-Signature` with `whsec_`): `checkout.session.completed` → create key
   (`ATA-XXXX-XXXX-XXXX-XXXX`, Crockford base32 from `crypto.getRandomValues`);
   `customer.subscription.updated|deleted`, `invoice.payment_failed`, `charge.refunded` → update
   status/expiry. `/v1/activate|validate|deactivate|recover` as in decision 1. Storage: D1
   tables `licences(key, customer, email_hash, plan, status, expires_at)` and
   `instances(id, key, name, created_at)`. Rate-limit `/v1/*` per IP (10/min).
4. Tests: webhook signature rejected/accepted; each event maps to the right status; 4th
   activation refused; validate after cancel past period end ⇒ `canceled`; lifetime never
   expires; recover always 200.
5. Deploy: `wrangler d1 create ata-licence`, `wrangler secret put STRIPE_SECRET_KEY` /
   `STRIPE_WEBHOOK_SECRET`, `wrangler deploy`; register the webhook endpoint in Stripe via API.
   Route: `licence.ata.…` on the owner's existing domain if one is set up for Ata in Cloudflare,
   else the `workers.dev` URL (same account as `ata-metrics`). Then set `AtaLicenceURL` in
   `Resources/Info.plist` (Track 2's PR or a follow-up).
6. Live check: a real test-mode purchase end to end (Checkout with card `4242…`, webhook lands,
   `/thanks` shows a key, `ata://licence` activates a dev Mac build, cancel in the portal ⇒
   validate says `canceled`). Then one live-mode Checkout Session created and **not** paid, to
   prove live config; no real charge without the owner.

## Track 3 — iPhone plans, paywall, contextual prompts

1. `ios/Ata.storekit`: add `ai.interactive.ata.pro.yearly` (€44.99, P1Y, same group "Ata Pro",
   introductory offer free trial P1W). Monthly goes to €6.99 in the `.storekit` file; in App
   Store Connect raise it for **new subscribers only** (existing €2.99 subscribers keep their
   price — choose "keep current price for existing subscribers").
   App Store Connect: base country **United States** ($6.99 / $44.99), then override Portugal and
   the other euro storefronts manually to €6.99 / €44.99. In `ios/Ata.storekit` add a USA
   storefront alongside PRT, so the simulator can show both. The paywall only ever shows
   `Product.displayPrice` and the computed savings, never a hard-coded currency. That includes
   the snapshot fixture price at `Sources/AtaiOS/PhoneSnapshots.swift:42`, which becomes
   per-locale: `$6.99 / month` for en_US and `6,99 € / mês` for pt_PT.
   `PaywallUITests` asserts the price read from the product, not a literal. Create the same product in App Store
   Connect with en-US and pt-PT names; submit it with the 4.0 build.
   **The agent makes every App Store Connect change itself through the App Store Connect API**
   (key already on this Mac: `~/.appstoreconnect/private_keys/AuthKey_*.p8`, issuer in
   `~/.appstoreconnect/issuer_id`, same JWT code as `scripts/distribute-build.py` /
   `scripts/mac-profile.py`). New script `scripts/asc-pricing.py` (idempotent, `--dry-run`
   default, `--apply` to write): creates subscription `ai.interactive.ata.pro.yearly` in the
   existing "Ata Pro" group with en-US/pt-PT localizations; sets prices via
   `subscriptionPrices` — USA base $6.99 / $44.99 using the matching `subscriptionPricePoints`,
   eurozone territories pinned to the €6.99 / €44.99 points, monthly change with
   `preserveCurrentPrice: true` so existing subscribers keep €2.99; creates the P1W free-trial
   `subscriptionIntroductoryOffers` on yearly for all territories; creates the owner's 1-year
   offer code (Track 0 step 8) as `subscriptionOfferCodes` with one one-time code. Run
   `--dry-run`, read the diff it prints, then `--apply`, then re-read through the API and quote
   the prices per territory as the check. **Verify each endpoint against Apple's current ASC
   API docs before writing.** Anything the API can't do (e.g. review screenshot for the new
   subscription) is done in ASC through the owner's Chrome per the global rules, not handed back.
2. `Sources/AtaiOS/ProStore.swift`: load both ids; expose `monthly`, `yearly`,
   `trialEligible` (`yearly.subscription?.isEligibleForIntroOffer`), `savingsPercent` computed
   from the two prices (never hard-coded), `purchase(_ product:)`. Entitlement check accepts
   either id. Mirror write to `ProMirror` after each refresh.
3. `Sources/AtaiOS/Paywall.swift` redesign:

```
┌─────────────────────────────┐
│                          ✕  │  always visible, 44 pt target
│        [Ata glyph 64]       │
│          Ata Pro            │
│  Every meeting, written up. │
│ ┌─────────────────────────┐ │
│ │ ▓▓▓▓▓▓▓▓▓▓▓▓▓░░ 212/300 │ │  QuotaMeter (context line changes by trigger)
│ └─────────────────────────┘ │
│ ✓ Unlimited minutes         │
│ ✓ Ask all your meetings     │  Track 10 features; lines hidden until that
│ ✓ Your own summary formats  │  track has merged (feature flag per line)
│ ✓ Unlocks your Mac too      │
│ ✓ Private: stays on device  │
│ ┌─────────────────────────┐ │
│ │ ● Yearly      SAVE 46 % │ │  PlanCard selected by default
│ │   €44.99/yr · €3.75/mo  │ │
│ │   7 days free           │ │  only if trialEligible
│ └─────────────────────────┘ │
│ ┌─────────────────────────┐ │
│ │ ○ Monthly   €6.99/month │ │
│ └─────────────────────────┘ │
│ [   Try 7 days free      ]  │  label = "Subscribe" when no trial / monthly
│ Then €44.99/year. Cancel    │  exact renewal sentence, from Product
│ anytime in Settings.        │
│ Restore · Terms · Privacy   │
└─────────────────────────────┘
```
   Trial timeline shown only when eligible and yearly selected: "Today: full access · Day 5:
   reminder · Day 7: €44.99". Schedule the day-5 local notification on trial purchase
   (`Notifier`), only if notifications are authorised.
4. Contextual prompts — pure rules in `Sources/AtaiOS/PhoneDecisions.swift`
   `enum ProPrompt { case eightyPercent, firstTranscript, limit }` and
   `ProPrompt.due(used:limit:isPro:lastShown:count:event:) -> ProPrompt?`:
   - `limit`: always (existing behaviour).
   - `eightyPercent`: once per calendar month, as an inline `Banner(kind: .warning)` on the
     Record home ("60 free minutes left this month") with action → paywall. Never a modal.
   - `firstTranscript`: once ever, 2 s after the first transcript finishes while the app is
     foreground: a sheet "Your first meeting is written up" with Open meeting (primary) and a
     small Pro card below. Never during a recording.
   - `feature(ProFeature)`: when a free user taps a locked Pro feature (Track 10) — always,
     it is user-initiated; paywall opens with that feature's line on top.
   - Global cap: at most one modal Pro prompt per 3 days except `limit` and `feature`.
     The `firstTranscript` sheet and the App Store review prompt (Track 9) never fire on the
     same day.
   - Each presentation calls `Funnel.count(.paywallShown(trigger))`; purchase success calls
     `.trialStarted` / `.purchased(plan)`.
   Tests in `ios/Tests/PhoneDecisionsTests.swift` for each rule and the cap.
5. `ios/UITests/PaywallUITests.swift` — intentionally changed (the paywall changed): assert both
   plans, close button, trial label, renewal sentence, Restore, Terms, Privacy. List in PR body.
6. Snapshots: `paywall` (trial eligible), add `paywall-limit`, `paywall-monthly`.

## Track 4 — iPhone onboarding (`Sources/AtaiOS/PhoneOnboarding.swift`)

Six steps on `OnboardingScaffold`; `enum Step: Int { welcome, useCase, permissions, you, tryIt, pro }`,
persisted in `Pref.onboardingStep`. Sheet stays `.interactiveDismissDisabled()`.

```
1 welcome            2 useCase              3 permissions
┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
│     ● ○ ○ ○ ○ ○  │ │ ‹   ○ ● ○ ○ ○ ○  │ │ ‹   ○ ○ ● ○ ○ ○  │
│  [animated mock: │ │ What will you    │ │ Let Ata hear the │
│   waveform →     │ │ record most?     │ │ room             │
│   transcript     │ │ ┌──────────────┐ │ │ ┌──────────────┐ │
│   lines → 3-line │ │ │💼 Work meetings│ │ │ │🎙 Microphone │ │
│   summary]       │ │ ├──────────────┤ │ │ │ [Allow]      │ │
│ Record it.       │ │ │🎓 Classes     │ │ │ ├──────────────┤ │
│ Ata writes it up.│ │ ├──────────────┤ │ │ │🔔 Notify when│ │
│ ✓ On this iPhone │ │ │🎤 Interviews  │ │ │ │ ready (opt.) │ │
│ ✓ Knows who spoke│ │ ├──────────────┤ │ │ └──────────────┘ │
│ ✓ No account     │ │ │🏠 Personal    │ │ │ Why: audio never │
│ [   Continue   ] │ │ └──────────────┘ │ │ leaves the phone │
└──────────────────┘ └──────────────────┘ └──────────────────┘
4 you                5 tryIt                6 pro (skippable)
┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
│ Two questions    │ │ Try it: say a    │ │ You're set.      │
│ Your name [    ] │ │ sentence         │ │ 300 free minutes │
│ Language [Auto▾] │ │   ( ● 0:07 )     │ │ every month.     │
│ ☐ Share anonymous│ │  ▁▃▅▃▂ meter     │ │ ┌ Ata Pro ─────┐ │
│   usage stats    │ │ "…your words     │ │ │ Unlimited +   │ │
│                  │ │  appear here"    │ │ │ your Mac      │ │
│                  │ │ ✓ Ata heard you  │ │ │ 7 days free   │ │
│ [   Continue   ] │ │ [Continue] Skip  │ │ └───────────────┘ │
└──────────────────┘ └──────────────────┘ │ [Try 7 days free]│
                                          │ [ Continue free ]│
                                          └──────────────────┘
```
- Step 1 animation: three stacked `Card`s cross-fading on a 3 s loop, built from SwiftUI shapes
  and fixture text (no video asset); static last frame under Reduce Motion / snapshots.
- Step 2 writes `Pref.useCase`; mapping: work/interviews → `Pref.defaultCategory = work` and
  mode `.call` stays default-off; classes/personal → `personal`, mode `.inPerson`. Tapping a row
  advances. Mapping is a pure function `UseCase.defaults` with a test.
- Step 3: existing mic/notification logic unchanged (App Review 5.1.1(iv) comment stays: the
  button says "Continue", not "Allow", before the system prompt — keep that wording).
  "Not now" still allowed.
- Step 5: only if mic granted (else skipped). Records ≤10 s with the existing `PhoneRecorder`
  into a temp file, shows `LevelMeter`, transcribes with the existing engine if the model is
  already available, otherwise only confirms "Ata heard you" from the level. The clip is
  discarded, never added to the library, never counted in the quota. Reuse the Mac
  `TrialRecording` logic shape (`OnboardingView.swift:337`) — extract its pure part
  (`TrialResult` from peak levels) into `Sources/Ata/FirstRun.swift` for both.
- Step 6: embeds the same `PlanCard` + purchase call from Track 3 (yearly only, compact) and a
  full-width `SecondaryButtonStyle` "Continue free" of equal size. Both end onboarding
  (`Pref.onboarded = true`). If the product fails to load, the step shows only the free line and
  "Start using Ata".
- Re-entry at `.permissions` after a mic denial keeps today's behaviour (dismiss on leave when
  already onboarded).
- Tests: update `OnboardingFlowUITests` (intentional: flow has 6 steps) and keep
  `OnboardingPermissionUITests` passing unchanged; unit tests for step order/skip rules
  (`OnboardingFlow.next(from:micGranted:productLoaded:)` pure function in `PhoneDecisions.swift`).
- Snapshots: `onboarding`, `onboarding-usecase`, `onboarding-permissions`, `onboarding-you`,
  `onboarding-try`, `onboarding-pro`.

## Track 5 — iPhone Record home (`Sources/AtaiOS/RecordView.swift`)

Idle layout, top to bottom in one `ScrollView` (padding `Space.xl` horizontal):

```
┌───────────────────────────────┐
│ Good morning, Miguel          │  ataLargeTitle; no name → "Good morning"
│ 3 meetings this week · 2 h 10 │  ataCallout secondary; first run → "Ready when you are"
│                               │
│  [Banner: 60 free min left ›] │  only when ProPrompt.eightyPercent / errors / warnings
│                               │
│          ╭─────────╮          │
│          │   🎙    │          │  HeroRecordButton(size: 132, state: .idle)
│          ╰─────────╯          │
│        Tap to record          │  ataHeadline
│   [ In person |  Call  ]      │  existing modePicker + its one-line footnote
│                               │
│ ┌ Transcribing · 62 % ──────┐ │  only while store.transcribingID != nil
│ │ Slack sync   ▓▓▓▓░░  2 min│ │  tap → that meeting
│ └───────────────────────────┘ │
│ RECENT                See all │  SectionLabel; "See all" → Meetings tab
│ ▸ Zoom · yesterday · 42 min   │  MeetingRowContent, max 3, tap → meeting
│ ▸ Standup · Mon · 15 min      │
│ ┌───────────────────────────┐ │
│ │ ▓▓▓▓▓▓▓░░ 212 of 300 min  │ │  QuotaMeter card, hidden for Pro
│ │ Try Ata Pro             › │ │
│ └───────────────────────────┘ │
│ 💡 Tip: add the Record button │  one rotating tip (Lock Screen control, Action
│    to your Lock Screen      › │  button, Siri "Record with Ata", widget); dismissable
└───────────────────────────────┘
```
First run (no meetings): recents replaced by a `Card` "Your meetings will appear here — record
30 seconds to see how it works" (or the sample meeting row from Track 9 when present).

Recording layout: keep today's structure (timer 56 pt, status capsule, `LevelMeter`,
stop button via `HeroRecordButton(state: .recording)`, "Mark this moment", paused/Resume), and add:
`.starting`/`.stopping` show `state: .busy` (spinner ring) with the labels "Starting…" /
"Saving…"; after Stop, a 1-line toast "Saved. Transcribing now." and the transcribing card
appears. No recents, no quota card while recording.

Implementation notes:
- Split into `RecordView.swift` (switch on phase), `RecordHomeIdle.swift`, `RecordHomeRecording.swift`,
  `RecordHomeModel.swift` (pure: greeting by hour, week summary from `store.meetings` via
  existing `Insights`, tip rotation by day index, which cards show). All logic tested in
  `ios/Tests/RecordHomeModelTests.swift` (greeting boundaries 5/12/18 h, empty library, Pro hides
  the meter, 80 % banner rule delegated to `ProPrompt`).
- Data already available: `store.meetings`, `store.transcribingID`, `transcribeProgress`,
  `transcribeStage`, `store.freeUsed`, `ProAccess.isPro`, `PhoneNavigation` for tab/meeting jumps.
- The earlier decision to remove the idle 00:00 timer stays (comment at `RecordView.swift:3-5`).
- Snapshots: `record-idle` (with recents), add `record-first-run`, `record-transcribing`,
  `record-recording` (existing).

## Track 6 — Mac onboarding (`Sources/Ata/OnboardingView.swift`, `FirstRun.swift`)

Window grows to 560×620. `OnboardingScaffold` with `StepDots`. Steps:
`welcome → permissions → summaries (only when Apple Intelligence is off/preparing) → you → test → done`.
`SetupStep` keeps computing *what is still missing*; the shown step is
`max(Pref.onboardingStep, first step whose requirement is unmet)` so the automatic relaunch after
the system-audio grant (`Setup.swift:185-202`, unchanged) lands back on `permissions` with ticks.

```
welcome                               permissions
┌────────────────────────────────────┐ ┌────────────────────────────────────┐
│          ● ○ ○ ○ ○ ○               │ │ ‹        ○ ● ○ ○ ○ ○               │
│ [mock: menu bar strip + popover    │ │ Let Ata record your meetings       │
│  card + transcript, cross-fading]  │ │ ┌────────────────────────────────┐ │
│ Meet Ata                           │ │ │ ✓ Microphone         Allowed   │ │  CheckRow
│ Records your calls and writes      │ │ │ ○ Mac audio (others) [Allow]   │ │
│ them up, on this Mac.              │ │ │ ○ Notifications      [Allow]   │ │  optional
│ ✓ Zoom, Meet, Teams, anything      │ │ └────────────────────────────────┘ │
│ ✓ Knows who said what              │ │ Ata restarts once after you allow  │
│ ✓ Nothing leaves your Mac          │ │ Mac audio. That is expected.       │
│              [ Get started ]       │ │ ↓ Whisper Large 42 %   [Continue]  │
└────────────────────────────────────┘ └────────────────────────────────────┘
you                                    test                                 done
│ Your name [Miguel   ]              │ │ Try a 10-second test    │ │ You're set               │
│ Language  [Automatic ▾]            │ │   ( ● Record 10 s )     │ │ [MenuBarCallout]         │
│ ☑ Offer to record calendar         │ │ You    ▁▃▅▃▂            │ │ ⌘⇧R records anywhere     │
│   meetings  [Allow calendar]       │ │ Others ▁▁▂▁▁            │ │ ☑ Open at login          │
│ ☑ Open Ata at login                │ │ ✓ Heard you ✓ Heard Mac │ │ ┌ 300 free min/month ──┐ │
│ ☐ Share anonymous usage stats      │ │ [Continue]   Skip       │ │ │ Ata Pro: unlimited › │ │
│                        [Continue]  │ │                         │ │ └──────────────────────┘ │
                                                                   │            [ Start ]     │
```
- Permissions: one row and one button **per** permission using the existing `CheckRow`
  (`Components.swift:131`), calling the existing `SetupModel` methods separately
  (mic → `AVCaptureDevice.requestAccess`; system audio → `requestSystemAudio()`; notifications).
  Order and the ask-first rule for system audio must not change (repo rule: a tap started before
  the answer delivers nothing). After a denial the button becomes "Open Settings" (existing).
  Continue enabled when mic + system audio are granted; "Continue without Mac audio" link
  otherwise (records only the mic; today's behaviour).
- `you`: calendar access asked here (reuses `CalendarAccess`, today only in Settings); login item
  toggle moves here from the silent auto-enable — keep it default-on.
- `test`: existing `TrialRecording` promoted to the hero of its own step.
- `done`: Pro card opens `WindowManager.showPro()` only if Track 2 has merged
  (`FreeQuota.appliesOnMac`); otherwise hidden.
- Closing the window still sets `onboarded` (existing behaviour); "Finish setting up" banner
  still reopens at the first unmet step.
- Tests: `OnboardingStepTests` for the `max(persisted, firstUnmet)` rule and the skip of
  `summaries`. Snapshots: one per step, light and dark (`onboarding-welcome`, `-permissions`,
  `-you`, `-test`, `-done`); `onboarding` stays as the `done` alias so README links hold.
- Retest the real first run on a Developer-ID build: `tccutil reset AudioCapture ai.interactive.ata`
  then launch (never chained after a build with `;`).

## Track 7 — Mac popover and library window

Popover (`Sources/Ata/PopoverView.swift`, stays 350 wide):

```
┌──────────────────────────────────────┐
│ [A] Ata                     ⤢   ⚙   │
│     Ready to record                  │
│ ┌──────────────────────────────────┐ │
│ │  (●)  Record a meeting      ⌘R  │ │  full-width card, HeroRecordButton 56
│ │       Zoom detected · tap to rec │ │  or "Next: Standup in 12 min" (CalendarStore)
│ └──────────────────────────────────┘ │
│ [ 2 voices to name › ] [ Update › ]  │  compact chips, not full banners
│ RECENT            All ▾     See all  │
│ ▸ Zoom · 42 min · Work               │  5 rows
│ ▸ Slack · 62 % ▓▓▓░                  │
│ ▓▓▓▓▓▓░░ 212 of 300 min · Ata Pro ›  │  footer meter (free users only)
│ Folder   Import audio…        Quit   │
└──────────────────────────────────────┘
```
- Tabs (Record / Insights / People) leave the popover; "See all" and ⤢ open the library window.
  Recording state keeps `RecordingContent` but hides the recents list under it.
- Only the setup and error banners stay full `Banner`s; voices/update/Apple Intelligence become
  chips (`BannerChip`, new small component in `Components.swift`).
- No meetings: a `Card` with three numbered lines (1 Start a call · 2 Ata offers to record ·
  3 Notes appear here) instead of hiding the section.

Library window (new `Sources/Ata/LibraryWindow.swift`, replaces `PopoverView(inWindow: true)` in
`WindowManager.showMain()`; 900×620, min 720×480):

```
┌───────────┬───────────────────────────────────────────────┐
│ ● Record  │ 🔍 Search meetings            [All|Work|Pers.]│
│           │ TODAY                                         │
│ Meetings  │ ▸ Slack sync       62 % ▓▓▓░           10:02  │
│ Insights  │ YESTERDAY                                     │
│ People    │ ▸ Zoom · Client X   42 min · 4 people  16:30  │
│           │ ▸ Standup           15 min             09:00  │
│ ───────── │ EARLIER THIS MONTH                            │
│ 212/300   │ ▸ …                                           │
│ Ata Pro › │                                               │
└───────────┴───────────────────────────────────────────────┘
```
- `NavigationSplitView` sidebar: Record button, Meetings / Insights / People, quota + Pro at the
  bottom. Meetings list: search over title/subtitle/transcript (reuse the iPhone
  `PhoneStore.searchText` matching by moving the pure matcher into shared
  `Sources/Ata/Meeting.swift` as `Meeting.matches(_:)`), date-grouped sections (pure
  `LibrarySections.group(_:now:)`, tested), same row + context menu as `MeetingRow`.
  Double-click/Return opens the existing meeting window (`showMeeting`). Insights and People panes
  host the existing `InsightsView` / `PeopleView` at full width (max content width 720).
- Tests: `LibrarySectionsTests`, `MeetingSearchTests`. Snapshots: `menu-idle`, `menu-empty`,
  `menu-recording`, `library-meetings`, `library-insights`, `library-people`
  (replace `window-people`, update README image links).

## Track 8 — Mac Settings split

`SettingsView.swift` (668 lines) → `Sources/Ata/Settings/` with a sidebar (700×520 window):
`General` (Where Ata lives, login item, updates, status + "Review setup", usage stats) ·
`Recording` (auto-detect, shortcut, calendar, work/personal) · `Transcription` (model, name,
language, dictionary, echo, summary) · `Storage` (audio, retention, iCloud, folder) ·
`Ata Pro` (Track 2's section) · `Agent` (MCP) · `Advanced` · `About`.
Pure move: every control, binding, footnote string and confirmation dialog is preserved (no
string edits → no localization changes except the 8 pane titles). Footnotes longer than two
lines collapse behind an ⓘ popover. Add `Sources/Ata/Settings/*.swift` to `ios/project.yml`
excludes (the old file was excluded). Snapshots: one per pane; `settings` stays as the General alias.

## Track 9 — first-run content and polish

1. Sample meeting: on first launch with an empty library, add one bundled example
   ("Example: weekly sync", 60–90 s, PT+EN variants by locale) — transcript, summary, two
   speakers, one bookmark, small MP3 generated by `scripts/lib/make-fixtures.py` at build time
   (no third-party voices). Tagged `isSample`, badge "Example", never counts toward quota, never
   syncs to iCloud, one-tap delete, not re-added after deletion (`Pref.sampleDismissed`).
   `SampleMeeting.swift` shared; tests for quota exclusion and no re-add.
2. Empty states with an action each: Meetings ("Record your first meeting" → Record tab),
   Insights (ghost preview of the charts at 30 % opacity + text), People (existing, add the
   primary button style).
3. App Store review prompt (`SKStoreReviewController` / `requestReview`) — iPhone: after the 3rd
   successful transcript, never during recording, at most once per version. Pure rule + test.
4. Sweep: replace remaining literal fonts/radii in `PopoverView`, `OnboardingView`, `Paywall`,
   `PhoneOnboarding` with tokens and lower the ratchet ceilings added in Track 1.
5. VoiceOver labels and Dynamic Type check on every new screen (XXL size in one snapshot each).

## Track 10 — Pro-only features (new; nothing free today becomes paid)

Already free and staying free (checked in the code): the 5 built-in summary templates
(`SummaryTemplate` in `Sources/Ata/Summarizer.swift:40`: standard, one-to-one, sales, standup,
interview), search across meetings on iPhone (`PhoneStore.searchText`, line 468) and on the Mac
library (Track 7), copy/share of transcript and notes, MP3 export, the MCP agent (shipped free in
3.7.0). So Pro gets **new** things only:

`enum ProFeature: String { askMeetings, customTemplates, documentExport }` in
`Sources/Ata/ProAccess.swift`, plus `ProAccess.allows(_:) -> Bool` (`isPro`). Every lock goes
through it, and a locked control shows a small `lock.fill` badge + opens the paywall with
`ProPrompt.feature(f)` and `Funnel.count(.featureLocked(f))`.

1. **Custom summary templates** (`Sources/Ata/CustomTemplates.swift`, shared):
   `struct CustomTemplate: Codable, Identifiable { id, name, instructions (≤ 1 000 chars),
   sections: [String] }`, stored as `templates.json` in the support dir, synced with the
   settings in iCloud KVS when iCloud sync is on (same mechanism as `CloudLibrary.swift:1150`,
   keep under the KVS 1 MB total). `Summarizer` takes either a `SummaryTemplate` or a
   `CustomTemplate` (new enum `TemplateChoice`), building the Apple Intelligence prompt from
   `instructions` + section headings. Editor: a sheet with name, a multiline instructions field,
   and a reorderable sections list; entry points: Settings → Transcription "Your templates" (row
   added to Track 8's pane) and the meeting window "Rewrite summary with ▸" menu.
   Free users see the editor list with a lock and one read-only example template.
   Tests: prompt building, JSON round-trip, 1 000-char cap, free user cannot select a custom
   template (falls back to `.standard`).
2. **Ask your meetings** (`Sources/Ata/AskMeetings.swift`, shared; macOS 26 / iOS 26,
   Apple Intelligence only — hidden when `AppleModel.unavailableReason != nil`):
   question field → retrieve the top 8 transcript chunks by keyword overlap (pure
   `AskIndex.rank(question:meetings:)`, no embeddings, tested) across all meetings, within the
   on-device model's context budget → `LanguageModelSession` (same `@available`/
   `@_weakLinked import FoundationModels` pattern as `AppleSummarizer.swift`) answers with
   citations `[Meeting title · mm:ss]` that open the meeting at that time (existing seek in
   `MeetingModel`). UI: Mac library window sidebar item "Ask"; iPhone a search-bar button in the
   Meetings tab. Free users see the field and 3 example questions; submitting opens the paywall.
   Tests: ranking, chunking across 2 meetings, citation parsing; no model call in unit tests.
3. **PDF and Word export** (`Sources/Ata/DocumentExport.swift`, shared): notes + summary +
   transcript (speakers coloured, timestamps) to PDF via `ImageRenderer`/Core Graphics page
   layout, and `.docx` written as a minimal Office Open XML zip (no new dependency; one
   `document.xml` with paragraph styles). Added to the existing Share/Copy menus in
   `MeetingView.swift` as "Export PDF…" / "Export Word…". Tests: docx zip contains
   `[Content_Types].xml`, `word/document.xml`, opens with `unzip -t`; PDF page count > 0 for
   a fixture meeting; long transcript paginates.
4. Strings EN+PT for all three; snapshots `ask-meetings`, `template-editor`, locked variants.
5. Paywall feature lines from Track 3 turn on here (`ProFeature.allCases` drives them).

## Track 11 — metrics server + ad attribution

1. Find the Worker behind `https://ata-metrics.miguelpeixoto457.workers.dev/v1/ping`
   (`AtaMetricsURL` in both Info.plists). It is **not** in `Ata` or `AtaSite` locally; check
   `cloudflare-os`, `AdminPanel`, then `wrangler` against the account (the Cloudflare MCP needs
   the owner to authorise it via /mcp). Extend it to accept the optional `funnel` and `campaign`
   fields (reject unknown keys, cap values), store per day, and add a daily view:
   installs → onboarded → paywall shown (by trigger) → trial → paid, by version and campaign.
2. iPhone attribution, `Sources/AtaiOS/Attribution.swift`: once, after onboarding and only if
   `Metrics.isOn`, call `AAAttribution.attributionToken()` (AdServices framework, no ATT prompt
   needed), POST it to Apple's AdServices attribution API, keep only `campaignId` (or
   `"organic"`) in `Pref.attributionCampaign`, send it as `campaign` in the next ping, then never
   again. **Verify the AdServices endpoint and response fields against Apple's current docs.**
   Test the parsing with fixture JSON (attributed, not attributed, error).
3. `docs/privacy.md` and the App Store privacy label: add "Usage data — not linked to you" for
   the funnel counters and the campaign id. Show the owner the changed text before it ships.
4. Ads: use Apple Search Ads campaign names that map 1:1 to ad sets, so `campaignId` is
   readable in the daily view.

## Wave D — release 4.0.0

1. `Resources/Info.plist` → 4.0.0; CHANGELOG section written in plain user language.
2. Tag; `./scripts/release-local.sh v4.0.0`; `./scripts/release-ios.sh v4.0.0`; Live check
   block from AGENT_INSTRUCTIONS; `spctl` on the unpacked zip (use `ditto`, not `unzip`).
3. App Store: new screenshots from `ios/snapshots.sh` (Record home, meeting notes, transcript,
   people, onboarding), updated description/what's-new/privacy label checked against the build
   (ASC listing drifts — memory note). **Show the owner the exact listing text and get approval
   before submitting for review**; the yearly product is attached to this submission.
4. README images and site copy updated from the new snapshots.

## Verification (every track, before PR)

```bash
swift build -c release --arch arm64 --disable-keychain
swift test --disable-keychain
./scripts/check-localization.sh
./scripts/build-app.sh
./ios/generate.sh
xcodebuild -project ios/Ata.xcodeproj -scheme Ata -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO build test
./scripts/snapshots.sh        # then Read every changed docs/images/*.png, commit them
./ios/snapshots.sh            # then Read ios/build/screenshots/*.png (or download the CI artifact)
```
Track-specific end-to-end checks:
- Tracks 0/2/3 (money): StoreKit config in the simulator — buy yearly with trial, buy monthly,
  restore, expire; iPhone at 300 min blocks start and shows the paywall once; Mac dev build with
  a fake `LicenceAPI` activates/deactivates; mirror: set `proUntil` in KVS on a signed build and
  see the Mac unlock, then lapse after the grace.
- Tracks 4/6 (onboarding): fresh state (`defaults delete` / new simulator), walk every step, deny
  the mic once, relaunch mid-flow and confirm the step is restored; Mac: `tccutil reset
  AudioCapture ai.interactive.ata` on a Developer-ID build and confirm the single automatic restart.
- Tracks 5/7: record 10 s against scratch folders
  (`ATA_MEETINGS_DIR=/tmp/ata-dev ATA_SUPPORT_DIR=/tmp/ata-dev-support open build/Ata.app`),
  confirm transcript appears and the home/popover cards update live.
- Anything touching transcription paths: `ATA_AUDIO_TESTS=1 swift test --disable-keychain`.
- Track 1 §5 / Track 11: run with `ATA_METRICS_URL` pointed at a local catcher
  (`python3 -m http.server` won't take POST — use `nc -l 8787` or a tiny Worker dev server via
  `wrangler dev`), finish onboarding, open the paywall twice, and read the posted JSON: funnel
  counts present, no meeting data, nothing sent with usage stats off.
- Track 10: Apple Intelligence Mac — custom template rewrites a fixture summary; Ask answers
  "what did we decide about pricing?" over 2 fixture meetings with a working citation; exported
  .docx opens in Pages/Word and the PDF in Preview.

## Needs the owner (cannot be done by an agent)

- Approve App Store listing text and the final EN/PT wording of paywall and onboarding copy
  (the mock copy above is placeholder direction; shipped copy must be approved, per repo §10).
- Tap to redeem his own 1-year offer code (the agent creates it).
- Answer only if the agent finds more than one Stripe account: which one Ata uses.

Done by the agent, not the owner: ASC prices ($6.99 / $44.99 US base, euro pinned, existing
subscribers keep €2.99), yearly product + trial, offer code (`scripts/asc-pricing.py`); Stripe
products/prices in USD with EUR options ($6.99 / $44.99 / $99), webhook, Worker (Track 2b).

Later, by data: ad copy and App Store screenshots en-US first. After 1–2 months of data, revisit the 300-min free tier
  (drop to 180 if almost nobody reaches it). Price tests compare revenue per install, not
  conversion rate.
