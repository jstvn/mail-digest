# Mac TODO

Things the cloud agent could not verify; check on the Mac.

## Checkpoint after T09 (core ready for a first Mac build)

**Original Core-only checkpoint:** T01 to T09, then T17 and T20 were completed in the Linux session. The Core implementation lives in `Packages/MailDigestCore`, which is Foundation only and tested on Linux with Swift 6.0.3. This checkpoint predates the Mac app work; current Mac-only task status is recorded below.

**What exists:**

- Models and protocols (`Models/`, `Protocols/`), with interim choices listed in `docs/QUESTIONS.md`
- Fakes for tests and SwiftUI previews (`Testing/`): `FixtureMailSource` (including a generated 3,000-message inbox), `StubLLMClient`, `InMemoryDigestStore`, `FixedClock`, `RecordingReminderWriter`, `RecordingMailActions`
- `MailJSONDecoder`, `MailFilter`, `EmailCleaner`, `OllamaClient` (+ `Prompts`, `ExtractionSchema`), `DateResolver`, `SuggestionValidator`, `DigestPipeline`, `JobRunner`, `ReviewActions`, `RetentionPolicy`, `ProcessedEmailSelector`, `MailCleanup` / `UndoLedger`, `JobPreviewBuilder`, `ActivityFeed`
- 18 fixture emails with canned model answers (`Tests/MailDigestCoreTests/Fixtures/`)

## First Mac build: please check

1. **Verified on macOS (Xcode 26.6 SDK):** `cd Packages/MailDigestCore && swift build && swift test --parallel` passes on macOS, after the `Category` fix below. The tests mix XCTest (2 files) and Swift Testing (the rest); both run under `swift test` with Xcode 16+.
2. `OllamaClient` uses `dataTask` wrapped in a continuation (not `URLSession.data(for:)`) so it behaves the same on Linux. Check it against a real Ollama: `healthCheck()` with `qwen3:4b` pulled, then one `extract` on a real email. Confirm `think: false` is accepted by your Ollama version and that `format` with the JSON schema returns valid JSON.
3. **`Clock` name clash.** Core defines `public protocol Clock`, which shadows Swift's `Clock` inside the package. In the app target, where both are visible, an unqualified `Clock` may be ambiguous. Don't write `MailDigestCore.Clock`: core declares `public enum MailDigestCore` as a namespace marker, so `MailDigestCore.Clock` resolves inside that enum, not the module. If the app hits the ambiguity, qualify the stdlib side instead (`Swift.Clock`, `ContinuousClock`).
4. **`Category` name clash.** On macOS `import Foundation` re-exports `ObjectiveC.Category` (`typedef struct objc_category *Category`), so an unqualified `Category` in any target importing both Foundation and MailDigestCore is ambiguous ('Category' is ambiguous for type lookup). The test target fixes it with a module-level `typealias Category = EmailCategory` in `Tests/MailDigestCoreTests/CategoryAlias.swift` (it routes via the core alias because module qualification `MailDigestCore.Category` fails — core's `enum MailDigestCore` namespace marker captures the name). The app target (T10 to T16) should do the same once in the app module, or use `EmailCategory` directly.
5. Swift 6.0.3 crashed the compiler on `await #expect { … } throws: { … }` with a pattern-matching closure, so two OllamaClient tests use `do`/`catch` instead. A newer Xcode toolchain shouldn't care.
6. `Package.swift` declares `platforms: [.macOS(.v15)]` and Swift 6 language mode. Check the app target's local package dependency resolves with the same settings (T10). **Verified:** the app target resolves `MailDigestCore` (local) and GRDB 7.9.0 and builds under Swift 6 strict concurrency.

## Notes for the Mac-only tasks

- **T11 JXA fallback contract.** `FetchMail.js` is the compatibility fallback in the hybrid SQLite/`.emlx` design in `docs/SPEC.md`. Its decoder expects `{"messages": [...], "missing": [...]}` (a bare array also works). `rawHeaders` should be the raw header block (e.g. `message.allHeaders()`); `receivedAt` from `toISOString()` is fine (milliseconds are accepted). Nested custom folder names (e.g. "Projects/Uni") must be verified against what `ListMailboxes.js` reports.
- **T11 timeout.** Each `osascript` call has a 120-second hard timeout (Q6). The 60-second target is the performance benchmark for listing 3,000 messages, not the process timeout.
- **T12 `GRDBDigestStore`** (done, see T12 status) implements every `DigestStore` method. Beyond the spec's list: `digest(id:)`, `recentSuggestions(since:)`, `updateJob`, `items(job:)`, `isQueued`, `recordItemOutcome(_:outcome:seconds:finishedAt:)`, `requeueFailed(job:)`. `InMemoryDigestStore` is the reference behaviour; consider running the same tests against both.
- **T13/T14 review panel.** Use `ReviewActions` for selection, edits, approve and dismiss; `ReviewActions.reminderNotes` and `messageURL` build the EventKit notes and `message://` link. Category edits are persisted on `Suggestion.category` (QUESTIONS 19).
- **T14 tags.** EventKit has no public API for Reminders tags, so the category is written as `#category` at the end of the notes. Check how this shows in Reminders on macOS 26 and iOS (does it become a real tag or stay searchable text?).
- **T15 scheduler** (done, see T15 status): `DigestRunModel.runIfDue()` asks `MorningSchedule.isDue` and runs the Daily job; `recoverOnLaunch()` runs when the first runner is built.
- **T19 job setup** (code done, see T19 status): `JobSetupModel` passes a plan with a fixed `to` date to `JobRunner.preview(_:)`, then the same plan plus unticked ids in `excludedMessageIDs` to `start(_:)`; `JobPreviewBuilder.startTitle` and `ActivityFeed` produce the strings in the spec.

## T10 status

T10 is done pending a visual check: build `MailDigestApp/MailDigest.xcodeproj`, launch, and confirm the envelope icon appears in the menu bar with a working "Quit Mail Digest" (⌘Q). The app launched without crashing in a headless check, but the icon was not seen.

- **Signing team.** A `DEVELOPMENT_TEAM` is now set in `project.pbxproj`, but `CODE_SIGN_IDENTITY = "-"` still explicitly requests ad-hoc signing. Before permission validation, switch to a valid Apple Development identity for that team, confirm the resulting app is no longer ad-hoc signed, and keep the Bundle ID/signing identity stable across rebuilds.

## T11 status

**T11-A done; result CONDITIONAL GO.** Report: `docs/T11-A-FEASIBILITY.md` (2026-11-06, macOS 26.7.2, Mail 16.0, i7-9750H, 32 GB RAM). The five design decisions from report §10.1 are approved and recorded as Q29–Q33 in `docs/QUESTIONS.md`; the real-app permission check is deferred to T11-C under Q34. T11-B is ready to begin.

- **Measured:** read-only SQLite listing takes 24–39 ms for the iCloud inbox (2,555 messages) and 21–31 ms for the EWS inbox (1,075). Batched JXA takes about 2.5 s for the same 4 properties plus 13–19 s to read the real `Message-ID` header. That gives about 37 s estimated for "All Inboxes" (3,630), summed from separate runs.
- **Mapping:** the hash-directory rule resolved all 5,581 active-account rows to `.emlx` or `.partial.emlx`, and every Message-ID in the files matched the database. EWS has local `.emlx` files on this Mac.
- **Machine-specific limits:** no Gmail account. The EWS account's newest mail is 2026-07-31 (check it still syncs). `AccountsMap.plist` is absent. One removed account (`OrphanedAccount - 6EC32CC9…`) leaves 46 rows in SQLite. Nested folders exist only in EWS and are empty.
- **Approved implementation decisions:** use the real `Message-ID` header (not `messageId()`); read whole-mailbox JXA property arrays and filter dates in-script (no `whose` date windows); accept structurally valid `.partial.emlx` files with a usable decoded text body; deduplicate per mailbox by canonical ID, newest date, then highest ROWID (JXA keeps first in newest-first order); and filter active UUID accounts using `Mail.accounts()` when available or the documented best-effort directory heuristic otherwise. Preserve `local://` / On My Mac mailboxes. See Q29–Q33 and the updated T11 sections in `SPEC.md`.
- **Still required at the start of T11-C:** use a real Apple Development signing identity (the project now has a Development Team value, but `CODE_SIGN_IDENTITY = "-"` still produces an ad-hoc signature), then verify Full Disk Access and Automation through the signed `dev.pages.justinwang.maildigest` app. Also verify how Xcode-launched execution is attributed. Terminal results do not count: the terminal could read Mail's data while its FDA row showed "off".
- **Not tested / follow-up validation:** Gmail, Outlook.com specifically, empty-body partials, missing `.emlx` files, nested folders with messages, mailbox names containing a literal `/`, a busy or locked database, FDA denial, Automation denial, index-based JXA paging for very large mailboxes. (The `FetchMail.js` Resent-Message-ID lookup question was resolved in T11-B, below.)

**T11-B implemented (2026-11-06), not committed.** Core: typed `MailMessageReference`, mailbox identity on `MailboxRef`/`MessageHeader`, `JobItem.storeRowID`, `MailSource.fetchMessages(references:in:)`, `MessageID`, `MailboxURL`/`MailStoreLayout`, `ActiveAccountPolicy`, `MailListingDeduplicator`, Foundation-only `EmlxParser` (with an injectable charset decoder). App (`Adapters/Mail/`): `MailStoreLocator`, read-only GRDB `EnvelopeIndexReader`, `MailboxResolver`, `EmlxStoreReader`, `CoreFoundationCharsetDecoder`, `OsascriptRunner` (120 s hard timeout), `AppleScriptMailSource`, composite `AppleMailSource`; JXA scripts in `Resources/`. Not yet wired into the UI (T11-D).

Verified on this Mac from Terminal (a harness that compiles the real adapter sources; not the signed app, so permissions are still unverified):

- **JXA lookup (Q29):** Mail's JXA `message.id()` equals the SQLite ROWID (2,555/2,555 iCloud, 1,075/1,075 EWS). `whose({messageId: canonicalID})` returned no match for 8/8 sampled messages carrying `Resent-Message-ID`, and one verified match for 4/4 plain ones. `FetchMail.js` therefore looks up by `byId(storeRowID)` first, then the `whose` lookup, and accepts a message only when its raw `Message-ID` header equals the requested ID. Tested cases: Resent with ROWID → found; Resent without ROWID → reported missing, never a wrong message; wrong ROWID (same or other mailbox) → rejected by the header check; unknown ID → missing. The `whose` path costs about 6 s per message.
- **T18 follow-up:** `MailActions.js` must use the same `byId` + raw `Message-ID` verification; `whose({messageId:})` alone cannot find Resent messages.
- **Mailboxes:** hybrid and JXA-only listings agree: 27 mailboxes (6 nested, 3 On My Mac) with identical paths, counts and kinds; the removed account is excluded.
- **Listing:** SQLite vs JXA for both inboxes, full range and a 72 h window: identical unique Message-ID sets, ROWIDs and order. Times: iCloud inbox 0.22 s vs 27.4 s; EWS inbox 0.10 s vs 16.2 s. The JXA-only "All Inboxes" listing (3,584 unique) is therefore about 44 s, inside the 60 s target but with little margin.
- **Bodies:** fetching all 3,584 inbox messages in batches of 10 returned every message with matching IDs: 2,492 from `.emlx`, 1,090 from `.partial.emlx`, 2 via JXA fallback (`noUsableTextPart`). Logged provenance contained counts and reason codes only. `EmlxParser` alone parsed 5,504 of 5,580 local files (100 % Message-ID match); most of the rest used GBK/GB2312/GB18030/windows-1256, which the app's CoreFoundation decoder now handles.
- **Empty bodies:** one of the 3,584 fetched messages came back from JXA with an empty body. The runner now skips an empty or whitespace-only body as `skipped: no readable body` before the pipeline. It does not consume a retry attempt, is not marked processed (so a later job can retry it) and never reaches Ollama. `DigestPipeline` also skips a body that is empty after cleaning, without a model call. Both have regression tests.
- **Timeout and cancellation (Q6):** checked with a real `osascript` delay script. A 2 s hard timeout terminated the child at 2.0 s (`timedOut`). A cancelled call is not killed: the script finishes and the call then throws `CancellationError`.
- **Not verified in T11-B:** signed-app FDA/Automation behaviour (T11-C), the busy/locked-database path, FDA-denied and Automation-denied fallbacks, a missing `.emlx` file, Gmail, nested folders containing mail, and the Core suite on Linux.

**T11-C and T11-D done (2026-11-06).** Full results are in `docs/T11-C-VALIDATION.md`.

- **Verified through the signed app:**
  - Apple Development signing, Team `HF69BFXF2W`, Hardened Runtime.
  - Automation granted and denied, both detected in-app.
  - Xcode ⌘R attribution: the parent is `debugserver`, Xcode has no grants of its own, so the app's own grants apply.
  - Run Now reached filter → Ollama → validator over real inbox mail: 14 emails → 14 info items and 6 suggestions, with canonical IDs.
  - The `message://` link opened the right message in Mail.
- **Not verifiable here:** Full Disk Access denial. SIP is disabled on this Mac, so TCC file protection is not enforced and the store stays readable with FDA off. Recheck on a SIP-enabled Mac: switch FDA off, relaunch, expect `fda=denied mode=automationFallback`.
- **Not tested:**
  - The "Allow Mail Access…" prompt from a not-determined state; the grant already existed.
  - Gmail.
  - EWS messages without local files.
  - Nested folders containing mail.
  - UI responsiveness under Instruments.
- **Open:**
  - Q35 resolved: `extract()` now times out after 1,000 s (headline 180 s, health check 10 s), and a timed-out email fails once without automatic retry. Recheck the 12,800-character email (875 s) with the real app.
  - Run Now took 49 min for 14 emails; the 30-emails-in-15-minutes target is not met on this Intel Mac.
  - Q25 implemented. `JobRunner` health-checks Ollama before `start`, `startDaily` and `resume`, and throws `providerUnavailable` with the fix text.
    - **Mid-job outage:** after any model error other than a malformed answer, the runner re-checks health. If Ollama is down, the job stops as `.failed` with `lastError`, the email returns to `queued` and no attempt is used. The menu shows the reason and a Retry item that resumes the same job.
    - **Attempt counting:** now follows Q22. Only genuine item failures count; starts, pauses, cancellations and crash recovery do not.
    - **Not yet tried:** stopping Ollama during a run of the real app.
  - T12 replaced the interim in-memory store (see T12 status).

## T12 status

**T12 done (2026-11-06).**

- **Where the store lives:** `GRDBDigestStore` is in a new local package, `Packages/MailDigestPersistence` (GRDB + MailDigestCore), linked into the app like `MailDigestCore`. The spec's layout puts it under `Adapters/`. I moved it so the GRDB store has a `swift test` suite without hand-adding an Xcode test target. Core stays Foundation-only and GRDB stays on the app side. Confirm or ask to move it.
- **Schema (migration `v1`):** `processed_email`, `digest`, `digest_email_result` (one row per email, unique by digest and email), `decision`, `job` (with `last_error`), `job_item` (full `MailboxRef` JSON plus nullable `mail_store_row_id`) and `setting`. Foreign keys cascade from digest to results and from job to items. WAL mode.
- **Core changes:**
  - Q17: `EmailResult`, `appendEmailResult` and `deleteEmailResults`, with digests rebuilt from results. The runner writes one result per email.
  - Q16: the runner no longer truncates Daily suggestions.
  - Q19: `Suggestion.category` is persisted.
  - Retention: `apply(RetentionPlan)`. The plan now keeps a pinned digest's job and the digest of a resumable job together (Q21).
  - Q28: `requeueFailed` clears outcome, seconds and finish time.
- **Verified:**
  - Core 232 tests and Persistence 16 tests.
  - Persistence restart test: pause plus a simulated crash mid-backlog, reopen the file, `recoverOnLaunch`, `resume` → no reprocessing, the digest matches an uninterrupted run, `mail_store_row_id` reaches `fetchMessages`, and a later Daily run reprocesses nothing.
  - Atomicity under a mid-transaction error.
  - Retention keeps processed ids, decisions, pinned digests with their job context, and paused jobs.
  - Real app: the signed app created `~/Library/Application Support/MailDigest/digest.sqlite` in WAL mode with migration `v1`.
- **Not verified in the real app:** quitting mid-job and resuming after relaunch (covered only by the package restart test), and retention cleanup scheduling (nothing calls `apply` yet; the daily cleanup belongs to T15).
- **Open:** Q19's removal of `ReviewState.categoryOverrides` is done in T13. The in-memory store accepts `enqueue` for an unknown job, but GRDB rejects it (foreign key).

## T13 status

**T13 code done (2026-11-06); nothing below has been checked by hand yet.** Build: `xcodebuild ... build` succeeds. Core and Persistence tests pass.

**Manual checks (Mac, signed app):**

1. **Layout** against the wireframe in the spec: header ("Today · Wed 4 Nov · 23 emails", headline, Run Now, gear), progress strip, SUGGESTED REMINDERS, INFO groups, Skipped. Window opens at about 720 x 640 and resizes cleanly. Open the Xcode previews (Panel states, Suggestion rows, Progress strip, Menu bar, Settings) and compare.
2. **Keyboard:** Up/Down move between suggestion rows; Space ticks the focused row; Command-Return runs Add Selected (only when Reminders is available, see deferred); Delete dismisses the focused row and moves focus on. Check that typing, Space and Delete inside a title field do not trigger row actions.
3. **Responsiveness during a job:** start Run Now with a large inbox; the panel and menu stay responsive; finished suggestions and info cards appear while the job runs (refresh happens when `done` changes).
4. **Each state:** Running; Paused (Pause then Resume; Stop then Resume); Ollama down or model missing (quit Ollama, Run Now: banner with the fix and Retry); Full Disk Access unavailable (banner with button); Mail Automation denied (banner with button); Reminders unavailable (Add Selected disabled plus banner, expected until T14); No new mail ("Inbox zero for today" and last run time); Partial failure (failed email under Skipped with its reason).
5. **Editing:** change title (a 2-character or link title reverts and shows an error), due date / "Due" checkbox / "Time" checkbox, priority and category. Quit and relaunch: edits (including category) are still there.
6. **Menu bar:** the pending-suggestion count shows next to the icon; the window-style menu opens, the strip fits, Open Review Panel, Run Now, Mail Access, Settings (Command-,) and Quit (Command-Q) work. Settings opening from an agent (no Dock icon) app can need the activate workaround; confirm it comes to the front.
7. **Settings persistence:** change each value, quit, relaunch. Change the Ollama URL/model and confirm the next run uses them. Daily mailboxes: untick "All inboxes", pick a subset, run.
8. **VoiceOver:** checkboxes ("Select <title>"), pickers (Priority, Category), the warning badge (hint has the reason), the open-email buttons, the progress bar (label and value), the banners and the gear button are all read sensibly.

**Deferred (not part of T13):**

- Reminders writer (T14). The panel's approve path is wired to `ReviewActions.approve`; T14 only calls `ReviewViewModel.setReminderWriter(_:)`. Until then Add Selected is disabled and the Reminders banner shows.
- Settings that are stored but not used yet: run time (scheduler, T15), Reminders list name (T14), retention (cleanup, T15), Trusted Newsletter senders (the validator and extraction do not read them yet). Launch at login and auto-file (T18) are in Settings; power and quiet-hours rules and Past Jobs are in Settings too (T19).
- Pin and Save to Notes on info cards, learned rules (T16; done). Mail Cleanup (formerly the Processed tab) and mail actions (T18; code done, see T18 status).
- Job setup window, full progress view, backlog batches of 50, power and thermal auto-pause, menu bar ring and pause badge, Past Jobs: done in T19 (see T19 status).
- Q16 Trusted Newsletter senders (8 suggestions instead of 3) are not read by `SuggestionValidator` or the runner yet; the setting is only stored. This gap predates T13.
- The paused strip now shows the auto-pause reason (`JobProgress.pauseReason`, T19).
- A job left paused by a previous session now gets its strip back after relaunch (`JobProgressSnapshot`, T19).

## T14 status

Built: `EventKitReminderWriter` (actor), `ReminderDraft` (core, tested on Linux), `RemindersAccessModel`, a banner button to request access, and list rename on commit in Settings. `xcodebuild` build passes; nothing below has been run against real Reminders.

Please check on the Mac:

- First approval with access granted creates the "Mail Digest" list in iCloud (not "On My Mac") and writes the reminder there.
- Changing the list name in Settings (press Return or leave the field) renames the existing list in Reminders.
- Delete the list in Reminders, then approve again: the list is recreated and the stored id replaced.
- A written reminder shows the due date (and time for timed items), an alarm (9:00 on the day for date-only, 1 hour before for timed), the right priority, notes (`From`, `Subject`, quoted evidence, `#category`), and the link. Check on macOS 26 and on iOS whether `#category` becomes a tag.
- The `message://` link opens the email in Mail.
- Permission denied (System Settings > Privacy & Security > Reminders): Add Selected is disabled and the banner shows; granting access and returning to the app enables it without a relaunch.
- Permission not yet asked: the banner's "Allow Reminders Access…" shows the system prompt.
- The writer uses Australia/Brisbane for due dates (no time zone setting exists yet).

## Open items

- The core package builds and its tests pass on macOS (Xcode 26.6 SDK), after the `Category` fix. The app target also builds with `CODE_SIGNING_ALLOWED=NO`; its visual menu-bar check is still pending. Ollama 0.40.14 with `qwen3:4b` answered a raw `/api/chat` call (`think: false`, JSON-schema `format`) with valid JSON; still unverified: `OllamaClient.healthCheck()` and one `extract` through the Swift code (item 2), plus the feature-level app-target work in T11–T16, T18 and T19.

## T15 status

**T15 code done; none of the following has been checked by hand.** Build succeeds; the schedule rule is unit tested in core (`MorningScheduleTests`).

**Manual checks (Mac, signed app):**

1. **Onboarding on first launch** (reset with `defaults delete dev.pages.justinwang.maildigest didCompleteOnboarding`): the "Welcome to Mail Digest" window opens once. Check each step: Ollama check (stopped, model missing, ready, Check Again); Allow Mail Access shows the Automation prompt with the Info.plist text; Mail Access Options opens the existing window; Allow Reminders Access and Allow Notifications show their system prompts; list name and run time save; Done and Run Now (Run Now opens the review panel and starts a run). Closing the window by any route means it does not return. Existing users who already saw Mail Access also see onboarding once.
2. **Notification:** after a run with suggestions, a banner shows "N suggestions ready" (also while the app is frontmost); clicking it opens the review panel. No email text appears in it. If notifications were skipped in onboarding, the first post asks for permission.
3. **Morning run fires once:** set the run time a few minutes ahead, wait (up to about 15 to 20 minutes with the scheduler tolerance); the Daily job starts by itself.
4. **No repeat the same day,** including an empty run (no new mail, no digest): leave the app running past two more checks and confirm no second job (Past jobs are not in the UI yet; watch Console, subsystem `dev.pages.justinwang.maildigest`, "daily run starting").
5. **Retry after Ollama down:** quit Ollama before the run time; the banner shows the fix and no notification appears; start Ollama; the next check (within about 15 minutes) runs. A job stopped as failed (outage mid-run) also retries at the next check.
6. **Catch up after sleep:** close the lid past the run time, open it; the run starts shortly after wake.
7. **Launch at login:** Settings > General > Startup toggle (and the onboarding copy). Turn on, check System Settings > Login Items, log out and in. Test the "requires approval" path (remove approval in Login Items): the footer text and "Open Login Items Settings…" button appear. A debug build outside /Applications may fail to register; the error shows inline.
8. **Optional wake for an early run** (not automated; may be mentioned in the README, none exists yet): `sudo pmset repeat wakeorpoweron MTWRFSU 06:25:00` wakes the Mac a few minutes before a 6:30 run.

**Notes:**

- The run time is interpreted in Australia/Brisbane (the runner's default zone), as in core.
- Retention cleanup was not scheduled in T15; T16 wires it (see T16 status).
- Sandbox is off, so `NSBackgroundActivityScheduler` is not throttled by App Nap rules beyond its normal tolerance; confirm in practice that the 15-minute checks fire while the app is idle.

## T16 status

Built: persistent pin/unpin (`DigestStore.setPinned` / `pinnedInfo`, tested on `InMemoryDigestStore` and `GRDBDigestStore` incl. reopen), a "Pinned" group at the top of Info for pins from earlier digests, Save to Notes (`NotesWriter` protocol, `NotesEntry` formatter, `AppleScriptNotesWriter` + `Resources/SaveToNotes.js`), learned ignore-rule suggestions (`IgnoreRuleSuggester`, `declinedIgnoreSuggestions` setting), and the daily retention cleanup. `xcodebuild` build passes and `SaveToNotes.js` is in the built app's Resources; the script compiles with `osacompile` but has never been run against real Notes.

Please check on the Mac:

1. **Save to Notes:** click the note button on an info card. The first time, macOS asks to let Mail Digest control Notes. Note: `NSAppleEventsUsageDescription` in Info.plist mentions only Mail; check the Notes prompt wording reads acceptably (not changed). A note named "Mail Digest" is created in the default account's default folder with the entry (bold date, sender and subject line, summary, key-fact bullets); a second click appends below it instead of creating another note. The button shows progress, then a checkmark for about 3 seconds.
2. **Escaping:** use an email whose summary or facts contain `<b>`, `&`, quotes and line breaks (or edit a stored summary); Notes must show them as literal text, not formatting.
3. **Notes denied:** turn Notes off for Mail Digest in Privacy & Security > Automation, click Save to Notes: the inline red message points to Privacy & Security > Automation. Turn it on again and retry.
4. **Deleted note:** move the "Mail Digest" note to Recently Deleted and save again: a new note is created (the script skips Recently Deleted).
5. **Pin:** pin an info card (filled pin, VoiceOver says "Unpin"). Quit and relaunch: still pinned. Run a later digest (or open the panel after one): the item shows under "Pinned" at the top of Info with its sender, subject and working open-in-Mail arrow. Unpin it there: it disappears from the panel and stays gone after relaunch.
6. **Retention keeps pins:** set "Keep history for" to 30 days with a pinned item from a digest older than that and an unpinned old digest; after the cleanup runs, the pinned item is still there and the unpinned digest is gone.
7. **Daily cleanup runs:** it runs at launch, at each 15-minute scheduler check and after wake, but at most once per 24 hours (key `lastRetentionCleanup` in the app's defaults; `defaults delete dev.pages.justinwang.maildigest lastRetentionCleanup` to force it) and never while a run is active. Console, subsystem `dev.pages.justinwang.maildigest`, message "history cleanup: digests=N jobs=N".
8. **Ignore suggestion:** dismiss five suggestions from one sender (across any number of digests). After the fifth dismissal an inline notice appears: "You've dismissed 5 suggestions from <sender>. Ignore this sender in future digests?" Ignore Sender adds the address to Settings > Senders > Ignored senders and hides the notice. Not Now hides it until relaunch. Don't Ask Again hides it and it does not return for that sender, including after relaunch. No sender is ever ignored without the click. VIP, Blocked and already Ignored senders never trigger it.

**Notes:**

- "Delete all history now" was later added to Settings > General > History (2026-11-06).
- Only dismissals since the sender's most recent approval count toward the suggestion (Q36).

## UI fixes after T16 (menu bar highlight, Mail Access size)

- **Menu bar highlight.** *Superseded (2026-11-06):* the `StatusItemHighlight` workaround was removed. Tested on macOS 26.7.2 without it: the system highlights the status item while the window-style panel is open and clears it when the panel closes (clicking the icon again, clicking outside, opening a window from the panel).
- **Mail Access window.** No longer sized to the full mailbox list: default 480 × 560, minimum 440 × 360, resizable, and the grouped form scrolls. Check with many mailboxes that every section (permissions, mailboxes, Refresh, Check Again) is reachable by scrolling and the window opens at the default size.

## T18 status

**T18 code done (2026-11-06); no mutation (move, trash, undo) has been run against real Mail.** Built: `AppleScriptMailActions` (actor) + `Resources/MailActions.js`, `ProcessedMailModel`, `ProcessedListView` (tab in the review panel, action bar, Undo toast) and the auto-file setting (Settings > General > Mail cleanup, off by default). Core and Persistence tests pass; `xcodebuild` build passes; `MailActions.js` is in the app bundle and compiles with `osacompile`.

Run on this Mac, read-only (the script's `verify` action, no mutation): `byId` + header verification found a real iCloud inbox message; a wrong row id with the right Message-ID was still found (via the `whose` fallback, about 6 s); a Resent-Message-ID message without a row id was reported `not found`, and with its row id was found; an unknown id and an unknown mailbox were reported failed. Mail's `trashMailbox.mailboxes()` returned one Trash per account (`Deleted Messages`, `Deleted Items`) and no local Trash.

**Manual checks (Mac, signed app; use a few throwaway emails first):**

1. **Trash:** tick one or two rows in Mail Cleanup, Move to Trash (also with ⌘⌫). They land in that account's Trash (the toast says "Moved N emails to Trash."), not another account's. Nothing is deleted permanently, and Trash is never emptied.
2. **Undo:** click Undo in the toast. The emails return to the mailbox they came from (the app keeps the original mailbox in memory, so Undo works until quit; after relaunch there is no Undo). Check it also works when Mail was slow to sync a move on IMAP (Undo reports "not found" if the message has not appeared in Trash yet; click Undo again).
3. **Move to Mail Digest Folder:** a "Mail Digest" mailbox is created in the email's own account the first time, and reused after. Check it with two accounts (each email goes to its own account's folder, never across) and that Mail shows the new mailbox in the sidebar. Creating the mailbox with `Mail.make({new: 'mailbox', at: account})` has not been run against real Mail.
4. **Resent-Message-ID message:** process one (the spike found 8 in the iCloud inbox) and move it; it must be found through its stored row id (Q29), and must never move the wrong message.
5. **Ambiguous and missing:** an email already moved or deleted in Mail reports "Not found in Mail" inline and nothing else is touched; two copies of one Message-ID in the same mailbox report "ambiguous" and neither moves. Failures show inline in Mail Cleanup, and the rest of the batch still moves.
6. **On My Mac:** a local-account email can be moved to a local "Mail Digest" folder. Trash for local mail has no clear target on this Mac (no local Trash was reported), so it fails with "no Trash mailbox for this account" by design.
7. **Keep:** hides the ticked rows and leaves the mail alone (no toast). Rows return after a relaunch (Keep is not stored).
8. **Select All Newsletters** ticks only newsletter rows (it unticks the others); Select All / Select None reset the ticks. Actions only touch ticked rows.
9. **Auto-file on/off** (Settings > General > Mail cleanup): with it off, no email moves by itself. With it on, after a run finishes and after approving or dismissing suggestions, newly processed emails (including blocked-sender ones) move to "Mail Digest" in their own account, never to Trash, with an Undo toast. Undo them and confirm they are not filed again until relaunch. Pending or failed-suggestion emails never move.
10. **Automation denied / Mail not running:** turn Mail off for Mail Digest in Privacy & Security > Automation, then try Move to Trash. Mail Cleanup lists the failure with an "Open Automation Settings…" button. Quit Mail and repeat ("Mail isn't running").
11. **Accessibility:** Tab and VoiceOver reach the Mail Cleanup sidebar item, each row's checkbox ("Select <subject>"), the three buttons and the toast's Undo. ⌘⌫ is active only while Mail Cleanup is showing.

**Known limits:**

- Undo history, Keep and "already moved" are kept in memory only. After a relaunch, emails moved earlier by this app still appear in the Mail Cleanup list (they are no longer where the job item says), and moving them reports "not found".
- If `osascript` hits the 120 s hard timeout mid-batch, moves already made are not reported and cannot be undone from the app; the script stops starting new messages after 100 s to make that unlikely.
- Mailbox names containing a literal "/" are split on it when addressing a mailbox (same as `FetchMail.js`).

## T19 status

**Code done (verified here: `swift test` in both packages, `xcodebuild` Debug build; nothing run against real Mail or Ollama):**

- Core: `ResourcePolicy`/`QuietHours` (Brisbane time, windows may cross midnight), `PauseReason` persisted on `Job` (new migration `v2`, column `pause_reason`), `JobState.stopped` (Q15; Stop now persists `.stopped`), `JobRunner.autoPause/autoResume/applyResourceRules`, `BacklogBatching` (50 per batch), `JobProgressSnapshot` (strip for a job paused in an earlier session), `MailboxTree`, `JobSummaryText`.
- App: `JobSetupView` (window "New Processing Job", from the review panel and the menu bar), `JobProgressView` (strip, Recent, Mailboxes, Activity log, Retry Failed), Settings > Jobs, Settings > General > Backlog jobs, `ResourceMonitor` (IOKit power source, Low Power Mode, thermal state, quiet-hour timer), menu bar progress ring and pause badge (template image).

**Manual checks (Mac; use a throwaway mailbox or a small date range first. Never start a big job by accident):**

1. **Setup window:** open it from the review panel ("New Backlog Job…") and the menu bar. The tree lists each account with message counts matching Mail's sidebar, nested folders indented, On My Mac included. All inboxes are ticked by default; "All Inboxes" ticks and unticks every inbox. Sent, Drafts, Junk and Trash appear only with "Show all mailboxes".
2. **Date range:** Last 30 days, Last 90 days, Everything and a custom range. After changing anything the preview is cleared and must be listed again.
3. **Preview numbers:** per-mailbox totals, date range found, already processed or queued, tier estimate (labelled an estimate) and time estimate. Untick a few emails (and use "Untick All from sender" in the context menu): the Start button text changes ("Process N emails from ... (about X)"). Start, then compare the strip total and the Activity log with the preview: unticked emails must not appear.
4. **Nothing queued before Start:** open the setup, go through Preview, then Cancel or close the window. Settings > Jobs must show no new job and Mail Digest must not have processed anything.
5. **Live per-email results and batches:** with a Backlog job running, suggestions and info for finished emails appear in the panel while it runs. After 50 results "Batch 1 of 2" appears with Previous/Next Batch; "Select All", "Add Selected" and "Dismiss Unselected" only touch the batch on screen. Clicking a Recent row jumps to that email's batch and scrolls to it.
6. **Pause and resume:** Pause (after this email) and Pause Now (menu on the Pause button) show "Paused after #N ... Next: #N+1 ...". Resume continues from #N+1 with no email repeated. Stop moves the job to Settings > Jobs as "Stopped" with Resume (never resumed automatically).
7. **3,000-email backlog across sessions:** quit mid-job, relaunch: the paused strip returns with Resume (and Settings > Jobs lists it). Resume finishes the queue over several sessions with no repeats.
8. **Unplug and replug (MacBook):** unplug during a Backlog job: it pauses after the current email with "battery power"; replug: it resumes by itself. A job you paused or stopped yourself does not resume on replug. Turn off "Pause on battery power": unplugging does nothing.
9. **Low Power Mode:** turn it on (System Settings > Battery): both Backlog and Daily jobs pause with "Low Power Mode"; turn it off: they resume.
10. **Thermal:** hard to trigger on purpose. Run a heavy workload (for example `yes > /dev/null` on all cores) until `pmset -g therm` or Activity Monitor reports a serious thermal state, and watch for "Mac is hot". Without that, treat it as unverified; the policy is covered by unit tests.
11. **Run window across midnight:** Settings > General > Backlog jobs: tick "Only run during this time window" (renamed from "quiet hours", Q45) and set a window that crosses midnight and excludes the current time (for example From 10:00 pm Until 7:00 am when it is daytime). A running Backlog job pauses with "outside the run window"; moving the start time to a few minutes ahead makes it resume at that time. Times are Brisbane time.
12. **Daily preempts Backlog:** set the run time a few minutes ahead while a Backlog job runs: the Backlog pauses ("Daily job running"), Daily runs, then the Backlog resumes by itself. A Backlog job you paused yourself is not resumed after Daily.
13. **Retry Failed:** after a job with failed emails, "Retry Failed" (Activity log and Settings > Jobs) requeues them and resumes; it is disabled while any job runs.
14. **Past Jobs after relaunch:** Settings > Jobs lists mailboxes, scope, totals, processing time and state; Resume works on a job paused in a previous session.
15. **Menu bar icon:** while a job runs the icon shows a small progress ring that fills; paused shows a pause badge; the pending count still shows; the icon stays highlighted while the menu window is open (system behaviour) and follows light/dark appearance (it is a template image). VoiceOver reads "Mail Digest, processing, N percent" or "job paused".
16. **HIG/accessibility pass:** Tab order and VoiceOver through the setup window (step labels, checkboxes, Start), the progress view and Settings > Jobs; Return starts the default action, Escape cancels the setup window.

**Known limits:** the runner is rebuilt when runner-relevant settings (now including Trusted Newsletter senders) change while idle; an auto-pause made earlier in the session is then not auto-resumed (resume by hand). The earlier limit "a manual Resume on battery keeps running" is fixed by Q43 below.

## Menu row hover, Trusted Newsletter, resume refresh, Delete All History, Q39–Q49 (2026-11-06)

**Code done (verified here: `swift test` in `MailDigestCore` and `MailDigestPersistence`, `xcodebuild` Debug build; nothing run against real Mail or Ollama):**

- Menu bar rows use `MenuRowButtonStyle`: a rounded `selectedContentBackgroundColor` highlight with `selectedMenuItemTextColor` text while the pointer is over an enabled row. A window-style `MenuBarExtra` never gives SwiftUI buttons a native menu highlight, and `.buttonStyle(.plain)` draws none.
- Trusted Newsletter senders reach `MailFilter` (Q9 order: Blocked → VIP → Ignored → Trusted → bulk → normal; Blocked now beats VIP). The prompt says whether the sender is trusted; the schema allows 8 tasks; the validator keeps 8 for trusted senders and 3 otherwise.
- *(Superseded by Q53, see the last section.)* Resuming a Daily job re-lists its mailboxes over the original scope first. Deleted or moved-out emails are skipped as "no longer in mailbox" (no model call, no attempt, not marked processed). Emails moved between selected mailboxes follow the move. A listing error aborts the resume and keeps the queue.
- Q43: Start and Resume check the resource rules first. A blocked new Backlog job is stored paused before any email; a blocked Resume leaves a paused job paused with the reason (a stopped job stays stopped) and shows why in the banner.
- Q39/Q42: new `mail_disposition` table (migration `v3`) records moved, kept and auto-file-attempted emails per digest, deleted with its digest by retention. Auto-file runs after each persisted result while a job runs, only for results finished after the switch was turned on.
- Settings > General > History: "Delete All History Now…" with a confirmation dialog.

**Manual checks (Mac):**

1. **Menu row hover:** open the menu bar menu and move the pointer over each row. The hovered row gets a blue rounded highlight with white text and icon, like the Ollama menu; disabled rows (Run Now and New Backlog Job while a job runs) don't highlight and look dimmed. Check light and dark mode, and an accent colour other than blue (System Settings > Appearance). ⌘, and ⌘Q still work while the menu is open; VoiceOver reads each row's title as a button. The status item icon stays highlighted while the menu is open. *Hover verified by the user (2026-11-06).*
2. **Trusted Newsletter:** add a newsletter sender you receive (one with `List-Unsubscribe`) to Settings > Senders > Trusted newsletter senders, then Run Now. Its email shows a summary and can show reminder suggestions; another newsletter still shows summary only. Adding the same address to Blocked skips it.
3. **Resume refresh (Daily):** *(now also covers Backlog and new mail; see Q53 checks below)* start a Daily run with a few new emails, pause after the first, then in Mail delete one queued email and move another to a mailbox outside the Daily mailboxes. Resume: both show "skipped: no longer in mailbox" in the Activity log, nothing is counted as failed, and the rest are processed. Quit Mail before resuming: Resume shows "Could not read Mail…" and the job stays paused with its queue intact.
4. **Blocked Start/Resume (Q43):** on battery with "Pause on battery power" on, start a Backlog job: it appears paused with "battery power" and no email is read; plug in and it starts by itself. Pause a job, unplug, click Resume: the banner explains why and the job stays paused. Repeat with Low Power Mode (also blocks Daily) and the run window.
5. **Moved/Kept after relaunch (Q39):** in Mail Cleanup, move a few emails to the Mail Digest folder and Keep a few others; quit and relaunch: they stay hidden. Undo a move before quitting: the restored emails reappear in Mail Cleanup and are not auto-filed again.
6. **Incremental auto-file (Q42):** turn on "File processed emails automatically", then run a job with info-only emails: each one moves to "Mail Digest" in its own account shortly after it finishes, while the job is still running. Emails with pending suggestions stay until you decide them. Emails processed before the switch was turned on are not moved. Relaunch: nothing is moved twice. Make a move fail (for example On My Mac mail): it is reported once and not retried.
7. **Delete All History Now:** pin an info item and leave a Backlog job paused, then Settings > General > History > Delete All History Now… > Delete All History. The pinned item and the paused job (with its results) remain, other digests and finished jobs disappear from the window, Mail Cleanup and Settings > Jobs, and nothing changes in Mail or Reminders. Previously processed mail is still not reprocessed on the next run.

## Menu alignment, status item highlight, Settings hang (2026-11-06)

**Fixed and checked on the running app (macOS 26.7.2):**

- **Settings hang (root cause).** `SettingsStore.settings` mutated itself inside its own `didSet` (the Q42 auto-file stamp). Under `@Observable` that re-enters the generated setter, so the first settings write (made as the Settings window loads) recursed without end on the main thread. A process sample showed `SettingsStore._settings.didset → settings.modify → _settings.setter → …`. The stamp now happens in an explicit setter over a private stored property. Checked: Settings opened three times in a row from the menu panel, the app became the active app with Settings as the key window, and no `SettingsStore` frames appeared in samples.
- **Panel state.** Choosing Settings, Open Review Panel, New Backlog Job or Mail Access now closes the menu panel first (`dismiss`), as a native menu does; before, the panel stayed open over the new window.
- **Row alignment.** Each row has a 24 pt icon column with the symbol centred and the title in its own column, so every title starts at the same x (checked in a screenshot).
- **Status item highlight.** Native; the workaround is gone (see above).

**Still to check by hand:**

1. **Escape in the menu panel:** with the panel opened by a real click, press Escape. My synthetic Escape did not close the panel, so it is unconfirmed whether the window-style panel closes on Escape. In every state I saw, the status item highlight matched whether the panel was visible.
2. **Settings from the keyboard:** with the panel open, ⌘, opens Settings in front and closes the panel; type in a field straight away (the keyboard goes to Settings, not the previous app).
3. **Settings reopen after closing:** close Settings with the red button or ⌘W, reopen from the panel several times; it comes to the front each time.

## Daily lifecycle and the state-aware menu action, Q52 (2026-11-06)

- Core: `DailyLifecycle` (the one unresolved Daily job, from persisted jobs plus live progress) and `DailyMenuAction`; `MorningSchedule.decision` (`notDue` / `start` / `deferred`); `JobRunnerError.dailyJobUnresolved` from `startDaily`, Daily `start` and Daily `retryFailed`; `resume(jobID:)` of a Daily job pre-empts a running Backlog job; `stopPaused(jobID:)`.
- App: the menu's Run Now row is driven by `DigestRunModel.dailyAction`; `resumeDailyJob(_:expecting:)` re-reads the job before resuming; `runIfDue` uses the schedule decision; Settings opens on the Jobs tab from "Review Daily Job…". Previews: "Menu · …" for each label.
- Built with `xcodebuild`; the checks below need the running app.

**Still to check by hand:**

1. **Paused Daily:** Run Now, pause after the first email. The lower row reads Resume and the card shows only Stop (no second Resume). Click Resume: the same job continues (Settings > Jobs still lists one Daily job; no email repeats in the Activity log). When it finishes the row is Run Now again. The review window's job status popover still has its own Resume while paused.
2. **Relaunch:** pause a Daily job, quit, relaunch: the row reads Resume straight away and the card is the paused Daily job.
3. **Stop on a paused card:** pause, then Stop in the card: the job shows as Stopped in Settings > Jobs and the row reads "Review Daily Job…", which opens Settings on the Jobs tab. Resume it there; the row returns to Run Now when it finishes.
4. **Failed Daily:** quit Ollama during a Daily run. The banner shows the error without its own Retry; the row reads "Retry Daily Job". Start Ollama and click it: the same job finishes.
5. **Backlog:** with a Backlog job paused, the card keeps its Resume and the row stays Run Now. With a Backlog job running, Run Now is enabled and pauses it ("Daily job running"); it continues after the Daily job.
6. **Scheduler:** leave a Daily job paused overnight (or set the run time a few minutes ahead with one paused). At the run time no new job appears and the menu says the scheduled digest is waiting. Resume and let it finish: a new Daily job starts within a moment, scoped from the previous Daily job's end.
7. **VoiceOver:** the Resume row reads "Resume Daily Digest"; disabled rows read as dimmed.

## Resume: reconcile, then discover new Daily mail, Q53 (2026-11-06)

- Core: `JobRunner.resume(jobID:)` now prepares a `QueueRefresh` (all listings and dedupe first) and applies it with the new `DigestStore.applyResumeRefresh` in one transaction (GRDB `writer.write`); `updateItemLocation` and `refreshQueue` are gone. Reconciliation runs for Daily and Backlog over the job's scope widened to every open item. Daily discovery lists `[max(Q23 cursor, now - lookbackCap), now)` in the job's own mailboxes, appends within the Q26 allowance (`maxEmailsPerRun - open items`) and moves `scopeTo` to that `now`; it is skipped while another Daily job is unresolved (Q52). The Q23 cursor is one shared helper (`dailyWindowStart`) for `startDaily` and resume.
- Not covered: the same-session hand-off back to a Backlog job after a Daily job does not reconcile (Q53); a GRDB rollback mid-transaction is not forced in a test.
- Verified with `swift test` (core and persistence) and an `xcodebuild` Debug build; nothing run against real Mail.

**Still to check by hand:**

1. **Daily Resume finds new mail:** Run Now, pause after the first email, send yourself two new emails and wait until they arrive, then Resume. The Activity log shows the remaining queued emails first, then the two new ones, all in the same job (Settings > Jobs lists one Daily job whose scope now ends at the resume time) and one digest.
2. **Long pause:** leave a Daily job paused for more than the look-back (or set Settings' look-back to 12 hours and pause overnight). Resume: queued emails from the original window are still processed (not skipped as gone), and no new mail older than the look-back is added.
3. **Cap:** set "Max emails per run" to a small number (e.g. 3), Run Now with more new mail than that, pause after one, then Resume: open plus newly added emails never exceed 3 in that run.
4. **Backlog Resume:** pause a Backlog job, delete one queued email in Mail and move another to a different selected mailbox, send yourself a new email into a selected mailbox. Resume: the deleted one is "skipped: no longer in mailbox", the moved one is processed from its new mailbox, the new email is not added, and the job's scope in Settings > Jobs is unchanged. Large Backlog scopes are re-listed on every Resume, so expect a short listing pause first.
5. **Failure:** quit Mail (or deny Automation) with a Daily job paused and new mail waiting, then Resume: "Could not read Mail…", the job stays paused, its item count and scope don't change. Fix it and Resume again: no email appears twice.

## Two-column review window, T21–T25 (2026-11-07)

**Not yet verified on the Mac.** The two-column window (`NavigationSplitView`) replaces the single-column review panel. Check each item below by hand, with a signed app and a real database.

1. **Window size:** the window opens at about 980×680 and cannot shrink below 760×520. The sidebar is 200–260 pt wide and uses the system sidebar material with no custom tint. The window title follows the selection.
2. **Toolbar:** Run Now is disabled while a Daily job is unresolved, Mail is unavailable or a Daily run is in progress. The Settings button opens Settings.
3. **Badges:** the Today and Review Queue badges hide at 0. With one failed and some pending suggestions across a Daily day and a Backlog job, the Review Queue badge equals the menu bar badge, and the Today, day and Backlog badges count pending + failed for their scope.
4. **Recent Digests:** the current month is expanded and the other months are collapsed. Rows read like "Thu 5 Nov" with the email count and an actionable badge. Several runs on one day show as one row. Dates follow the locale and the settings time zone.
5. **Backlog Jobs:** each job shows its title and pending badge. New Backlog Job… is disabled while a job runs or when Mail is unavailable. Check that the plain button row looks right in the sidebar.
6. **Job status pill:** shown only while a job is listing, running, pausing, paused or stopping. Its popover has the progress strip (Pause / Pause Now / Resume / Stop), Recent, mailboxes and the Activity log. A Recent row closes the popover and jumps to the email (Today, Day or Backlog batch). The popover closes when the job ends. Its 440×480 size is acceptable.
7. **Live updates:** with a job running, the sidebar counts and the shown canvas update live. A large Backlog canvas refreshes fast enough on every progress tick.
8. **Today:** "Unreviewed from Earlier" shows only for Daily digests and links to Review Queue when there are more. Today's suggestions show the 25-limit and Show All / Show Top 25. Info cards are pinned first, with newsletters collapsed. Skipped mail appears. Check the empty states: never run and inbox zero. The Backlog canvas has the batch bar.
9. **Review Queue and Logbook:** check grouping, Load More and the empty states. Logbook lists the newest decision first.
10. **Midnight rollover:** leave the app open across midnight in the settings time zone. Today rolls over to the new day, and earlier unreviewed Daily suggestions stay under "Unreviewed from Earlier".
11. **Floating triage bar:** a bottom-centred capsule that does not cover the last row. It shows the selected count. Dismiss Unselected is disabled when nothing would be dismissed. ⌘↩ adds. Help text appears when Reminders access is missing. Reduce Motion and Reduce Transparency are respected.
12. **Selection:** Select All / Select None affect only their own section. Ticks survive switching views. Approve and dismiss work across digests. Afterwards Mail Cleanup and auto-file see the new statuses.
13. **Mail Cleanup:** check the list, the action bar, ⌘⌫ and the floating Undo capsule toast (no layout shift). Check the layout at the minimum width (760 pt).
14. **Suggestion row:** the date, priority and category pills open their popovers or menus. Add Date appears on hover or focus. The evidence quote block shows the accent bar, and ↗ is emphasised on hover. Every control is reachable by keyboard and VoiceOver. ↑/↓, space, ⌫ and ⌘↩ work, and are ignored while editing a title.
15. **VoiceOver:** check the section headers, sidebar day rows, the job pill's label and value, the triage group and the pill labels.
16. **Entry points:** "Open Review Panel" in the menu bar and a clicked notification both open the window on Today.
17. **Previews:** the Xcode previews for `ReviewWindow`, `SuggestionRow` and `InfoCard` render.
18. **Migration (v4):** on the real database, all existing digests and suggestions are kept, and the sidebar counts match what the digests show.
19. **Window opening:** "Open Review Panel" shows the window promptly. Target well under a second; measured in Debug via a temporary harness on the 1-digest database: 0.26–0.28 s at a33ab29, 0.60–0.75 s after the Q58 scope indicators (cause not yet isolated). Recheck with a large database (many digests, 25+ suggestions, many info cards) and in Release. Repeated clicks don't create a second window.
20. **Navigation:** click each of Today, Review Queue, Logbook, Mail Cleanup, every Recent Digests day and every Backlog job with the mouse, and move with ↑/↓ in the sidebar. The highlight and window title follow, and Today is selected on open. Switching to Today, Review Queue or a day has no visible freeze. Section headers, month rows and New Backlog Job… are not selectable. Verified by AX on 2026-11-07 for Today, Review Queue, Logbook, Mail Cleanup and a day row; Backlog rows are untested because no Backlog job existed.
21. **Batch scope:** with more than 25 Daily suggestions, the section header shows "25 of N" and the triage bar names the shown count. Add to Reminders and Dismiss Unselected leave hidden suggestions untouched. After Show All, they act on all. Carry-over and Review Queue show "Showing X of Y" when partial.
22. **Reviewed section:** approved and dismissed suggestions in a past day and in a Backlog job are read-only: no checkbox, editing, menus or focus. They are excluded from the triage bar. Failed suggestions stay actionable and show their failure note.
23. **Today empty state:** with no digest today but earlier unreviewed suggestions, carry-over shows above a compact "No digest yet today".
24. **Lazy rows:** ↑/↓ through a long list reaches rows that were off screen. A reveal from the job popover scrolls to a lazy row or info card. The two-line row layout truncates sensibly at the minimum width (760 pt).

## Hybrid privacy routing and Activity Center (T26–T32)

**Not yet verified on the Mac.** Check each item by hand with the signed app. Routing checks need a real Gemini key and Ollama, and use synthetic emails only.

**Keychain (T31)**

- Save a key: Keychain Access shows service `dev.pages.justinwang.maildigest.gemini`, account `api-key`, not synchronizable, "After first unlock, this device only".
- Saving a key shows no Keychain access prompt.
- Save a different key: the button reads "Update Key" and there is still exactly one item.
- Quit and relaunch: status still reads "API key saved in Keychain".
- A scheduled run can read the saved key.
- After rebuilding or updating the app with the same bundle id and signing, the key is still readable without a prompt.
- Remove Key shows a confirmation.
- Remove Key: the item is gone and status reads "No API key". (Superseded by Q93: the Cloud Digest toggle now stays on; see "Cloud providers" below.)
- Cancel on Remove Key changes nothing.
- Delete the item in Keychain Access, then reopen Settings: "No API key" and the toggle is off.
- A pasted key with a trailing newline is stored trimmed.
- An empty or whitespace-only field keeps Save disabled.
- The key never appears in Console (subsystem `dev.pages.justinwang.maildigest`) during save, Test Connection or a cloud run.

**Cloud settings and acknowledgement (T31)**

- First enable shows the acknowledgement sheet with all Q63 points.
- The terms link in the acknowledgement sheet works.
- Cancel or Esc on the sheet leaves the toggle off and stores no revision.
- Accepting the sheet turns the toggle on and it persists across relaunch.
- Turning cloud off and on again does not ask again.
- Raising `CloudPrivacyPolicy.currentRevision` asks again.
- The toggle is disabled without a saved key.
- Saving a key does not enable cloud.
- The disclosure footer is readable.
- The sheet and footer read well in VoiceOver.
- The sheet buttons are keyboard-reachable.
- In the 520×520 Settings window, the longer Model tab scrolls and reads well.
- Test Connection shows Connected for a valid setup.
- Test Connection shows Invalid API key for a bad key.
- Test Connection shows Model unavailable for a bogus model.
- Test Connection shows Rate limited.
- Test Connection shows Network error when offline.
- Test Connection shows Server error.
- Test Connection shows Unexpected response.
- Test Connection shows a progress indicator while running.
- Test Connection uses the field value when non-empty, otherwise the saved key.
- VoiceOver announces the Test Connection result.
- Live check with a real key: `gemini-3.5-flash-lite` reports Connected (models.get lists generateContent).
- The triage model picker shows installed or missing hints for each model.
- The triage model picker shows "Couldn't check" when Ollama is stopped.
- The threshold slider steps 1% from 80% to 99%.
- VoiceOver reads the threshold value.

**Incomplete-inspection reasons (Activity)**

- An email with an attachment shows "Local only · Attachment not inspected"; one with an image or calendar part shows "Local only · Non-text content not inspected"; a JXA-fallback email shows "Local only · Message structure unavailable".
- Older Activity rows without a recorded reason still show "Local only · Content not fully inspected".
- Hovering the privacy badge of an inspection row shows the explanation tooltip.
- The info popover shows the wrapped explanation paragraph above the grid, with separate "Privacy: Not classified" and "Inspection" rows, and stays 340 pt wide.
- An expanded job with local items shows the caption summary line, for example "Local: 4 not fully inspected · 2 private rule", without clipping.
- VoiceOver reads the badge, the popover paragraph and the summary line sensibly.

**Routing (T26–T30, needs a real key and Ollama; synthetic emails only)**

- Gemini accepts the adapted `responseJsonSchema` (first real generateContent call).
- Gemini returns valid extraction JSON for a synthetic newsletter.
- With cloud on, a synthetic allowlisted newsletter with complete inspection is processed by Gemini.
- That newsletter's Activity row shows "Public · Trusted Sender" and "Cloud · Gemini 3.5 Flash-Lite".
- That newsletter's info card shows the cloud glyph.
- A message with an attachment stays local: "Local only · Content not fully inspected".
- A message with an inline image stays local: "Local only · Content not fully inspected".
- A message fetched through the JXA fallback stays local.
- A synthetic OTP message stays local with "Private · Rule".
- A synthetic bank message stays local with "Private · Rule".
- A synthetic medical message stays local with "Private · Rule".
- An ambiguous message runs System One once.
- The info popover shows scores, threshold and triage model for an ambiguous message.
- An ambiguous message below threshold stays local.
- Stopping Ollama's triage model makes ambiguous mail stay local with "The privacy check was unavailable".
- A missing triage model makes ambiguous mail stay local with "The privacy check was unavailable".
- An invalid key during a run falls back to local once.
- Offline during a run falls back to local once.
- Fallback shows "Gemini failed → Local Qwen3 4B" and the reason in Activity.
- Fallback produces no duplicate results in the digest.
- Turning Cloud Digest off mid-job makes the next email local ("Cloud Digest is off").
- Pause Now during a Gemini call, then Resume: no fallback is recorded.
- Pause Now during a Gemini call, then Resume: no re-triage.
- Pause Now during a Gemini call, then Resume: the email gives one result.
- With cloud off, a Daily run gives the same results as before.
- With cloud off, a Daily run makes no System One or network calls.
- With cloud off, `ollama ps` shows only qwen3:4b.
- With cloud off, Little Snitch or nettop shows no Google traffic.

**Activity Center (T32)**

- The sidebar "Activity" row selects and deselects.
- The Activity sidebar row shows its icon.
- VoiceOver reads the Activity sidebar row.
- The Activity view opens quickly with many jobs (Q59).
- The newest day is expanded and older days are collapsed.
- Sections toggle by click.
- Sections toggle by keyboard.
- Two Daily runs on the same day appear as two separate jobs.
- Daily and Backlog jobs both appear, newest first.
- The All/Daily/Backlog filter resets and reloads.
- The All/Local/Cloud filter resets and reloads.
- An empty filter combination shows "No jobs match these filters".
- Scrolling to the end auto-loads the next page once.
- Collapsing all sections auto-loads the next page once.
- "Load Earlier Activity" loads more jobs.
- A running job updates live without losing scroll position.
- A running job updates live without losing its expansion state.
- Elapsed time ticks for a running job.
- A paused job shows its pause reason.
- Expanding a job shows lifecycle events (Created, Started, Paused, Resumed, Completed…).
- A job from before this update shows "Lifecycle history not recorded".
- Item rows show both badges in light mode.
- Item rows show both badges in dark mode.
- Item rows show both badges with VoiceOver.
- Item rows show both badges with Increase Contrast.
- Items from before this update show "Not recorded" for both badges.
- The routing info popover shows the right lines for Private rule.
- The routing info popover shows the right lines for System One public.
- The routing info popover shows the right lines for uncertain results.
- The routing info popover shows the right lines for Gemini fallback.
- The routing info popover shows the right lines for uninspected examples.
- The routing info popover shows the score disclaimer.
- Day headers read "Today" and "Yesterday" following the Brisbane time zone around local midnight.
- Activity history survives an app restart.

**Job status popover (T32)**

- The popover shows the job name, progress, Pause/Resume and Stop.
- The popover shows 3 recent rows.
- The popover shows Retry Failed when failures exist.
- The popover shows "View All Activity".
- The popover has no blank space.
- The popover does not cover the review canvas.
- "View All Activity" opens the review window on Activity when the window is open.
- "View All Activity" opens the review window on Activity when the window was closed (menu bar flow).

**Gemini settings copy**

- Cloud Digest Model row shows the display name and, in small monospaced text, the raw id; editing Model ID updates it live.
- The success block reads "Connection successful" with the model display name and the no-email-content note, and disappears after editing the key or Model ID.
- The caption under the Cloud Digest toggle changes between disabled, active and inactive-without-key states.

**System One model benchmark (Q68; synthetic emails only)**

- `kev:4b-q4_K_M` is now the default (Q69): run a Daily job on a 16 GB Mac with Kev 4B and Qwen3 4B and watch `ollama ps` and memory pressure for swapping or model reloads; if it swaps, switch to Tev1 0.8B in Settings.
- Rerun `EvalCLI systemone run` for each model and `eval/systemone/latency.py` on a quiet machine after any Ollama upgrade or model re-pull, and compare digests with Q68.
- Selecting "Tev1 0.8B" in Settings shows the triage model as installed (tag `tev1:0.8b-q8_0`); the status updates when the picker changes.

**Selective privacy routing (Q69; use synthetic or your own test emails only)**

- Settings shows Privacy Triage Model as "Kev 4B (Q4, default)" after upgrade, with the memory caption; choosing "Tev1 0.8B (Q8, low memory)" persists across relaunch and shows its caption; Kev 0.8B is no longer listed.
- Activity on a clean Substack/Medium newsletter: "Public · Trusted Sender", Route row and tooltip "Trusted public sender · System One not required", no scores.
- Trusted newsletter with a reader's diagnosis and home address: Route shows selective System One assessment, Risk signal row shows, real scores shown, stays local unless both thresholds pass.
- Ambiguous sender: Route "Ambiguous sender · System One assessment".
- A reply with sensitive text only below the signature or in the quoted part stays local, while its digest still omits the quoted text.
- A long test email (over 1,500 characters, sensitive detail near the end): Activity shows "Text assessed" sections and it stays local; an over-long one shows "Too long to assess completely".
- "Sensitive · System One" and "Uncertain · System One" badges and the local-reason summary read correctly.
- Measure a real Daily job's duration with Kev 4B against the Q69 model (20 s per call; 0 for trusted direct) and check `ollama ps` shows Kev 4B and Qwen3 4B both resident.
- VoiceOver reads the new Route, Risk signal and Text assessed rows and the picker caption.

**Settings and Dock (Q70)**

- Cloud AI shows **Gemini 3.5 Flash-Lite** with no model ID underneath, and the separate Model ID row is unchanged.
- Opening the review window adds Mail Digest to the Dock; clicking the Dock icon from another app brings it forward; minimising keeps the Dock icon; closing the window removes it; the menu bar icon keeps working throughout, including reopening the window.
- Repeat open → close → reopen at least four times in one session, opening from both the menu bar and a notification, and closing with the red button and Cmd-W: the Dock icon appears on every open and disappears on every close. Minimise and restore from the Dock, and move between sidebar views: neither removes the icon. (The cycle logic was checked in a test harness with the same code, not in the app.)
- After a build that had `kev:0.8b-q8_0` saved, Settings shows the migrated model, and Activity rows recorded before the change still show their original model.

## Backlog selection after Stop, Q71 (2026-11-09)

- Start a Backlog job on a single day, Stop it after one email, then reopen New Backlog Job: the window starts at Mailboxes with no earlier preview.
- Preview the same day: the stopped job's unprocessed emails are offered, Start queues exactly those, and the stopped job still shows its own progress in Activity.
- Preview that day again after the new job finishes: Start is disabled and the window explains that nothing is left to process.
- Resume the stopped job: emails the newer job processed show as skipped, and the job finishes without running the model on them.
- Cancel the setup window on the Preview step and reopen it: no earlier preview appears.
- Stale start: with Start enabled, make the previewed mail unavailable (for example, pause another job holding it), then click Start. The window stays open, reloads the preview and shows "These emails changed after the preview…".
- The empty-preview explanation wraps cleanly and VoiceOver reads it.

## Review window polish (2026-11-09)

- Suggestion rows are two lines, with and without a due date: Priority and Category stay flush right, the quote tile's edge lines up with the title text, and a long title truncates before the pills.
- With no due date, Add Date appears on hover and keyboard focus, clicking the empty slot when it's hidden does nothing, and VoiceOver reads it.
- Round checkbox: click, space key, disabled state, scale animation, and no animation with Reduce Motion on. VoiceOver reads it as a toggle with its state.
- Sidebar icon colours are distinct with the Multicolor accent and with a single accent colour, and stay legible on a selected row in the focused and unfocused window.
- A Backlog row shows "iCloud Inbox" with its date range beneath, and a two-line title keeps a sensible row height.
- The toolbar shows no title next to the sidebar toggle, while the Window menu and Mission Control still name the window. Activity's centred pickers still fit.
- Today shows "8 emails processed · 2 suggestions" and no quoted count line; a day with a real model headline still shows it.
- Info cards in light and dark mode: surface and border, top line truncation, relative time wording, actions appear on hover and keyboard focus without shifting the row, and a set pin or Notes state stays visible.
- Redundant bullets (sender, your name, a bare date) are gone. The name comes from the macOS account, so a different name on the email isn't filtered.
- Scroll Today and Review Queue to the end: the floating bar clears the last item, and content passes under its material while scrolling.
- Run a real digest: new summaries and headlines don't say "User received…" or use your name. Summaries already stored keep their old wording.

## Native visual pass (2026-11-09)

Checked in screenshots of the real `ReviewWindow` on preview fixtures, light and dark: Run Now at the trailing edge, sidebar badges, month headers, grouped cards on Today, Review Queue and Logbook, the bar's band at the top and end of the scroll, and Info rows with and without a linked email. Still to check by hand:

- Live data: the same views on your real mail, and Mail Cleanup with entries (the fixture list was empty).
- ⌘, opens Settings from the app menu while the review window is open, and the menu bar popover's Settings row works when it's closed.
- Activity's centred pickers still sit correctly beside the toolbar spacer.
- Hover and keyboard focus: Info actions replace the age without shifting the row; row hover and focus fills stay inside the card corners.
- Dismiss Unselected reads as dimmed but legible when every suggestion is ticked, and clear when it's available.
- VoiceOver reads sidebar rows without announcing the badges, and the Info row actions when hidden.

## Menu bar panel redesign (2026-11-09)

Builds and Core and Persistence tests pass; nothing below has been checked in the running app.

- Compare the panel with the design in light and dark: width, spacing, capsule buttons, sun tile and the warm card.
- Warning badge on the icon at 1x and 2x, light and dark, with and without the count.
- Quit Ollama and run the Daily digest: the panel shows "Daily Digest", the "Started… stopped before reading any emails" line, the card with Start Ollama and Retry, and the "Retry Daily Digest ⌘R" row. The card updates when the banner changes.
- Start Ollama with the app installed (it launches without taking focus and the panel stays open) and with it missing (the download page opens).
- ⌘O, ⌘N, ⌘R, ⌘, and ⌘Q work while the panel is open.
- A running Backlog job shows its date range in the title.
- The suggestion count updates after approving or dismissing a suggestion, and "this morning" becomes "today" at noon.
- The Review window's job popover still has Pause Now and the Now line.
- VoiceOver reads the attention card and the suggestions row. SwiftUI posts no automatic announcement when the card appears, so judge whether that's acceptable.

## Dock presence and app icon, Q75 (2026-11-09)

- Launch at login (or from Finder): no Dock icon and no flash, including when the scheduled run fires.
- Open Review from the menu bar: Dock icon appears, the window comes to the front and shows in Cmd-Tab. Open Settings too; close Review (icon stays); close Settings (icon goes, menu bar item stays, app keeps running); open a window from the menu bar again (icon returns).
- New Processing Job, Mail Access and Welcome each add the Dock icon the same way. The menu bar panel, popovers, sheets and alerts never do.
- While the Dock icon shows, the main menu responds right after opening the window: Mail Digest menu with Settings… (⌘,) and Quit (⌘Q), plus Edit and Window. If the menu stays inert until you switch apps and back, note it here.
- Minimise Review, then close Settings: the minimised window keeps its Dock tile and restores from it. Cmd-H does not remove the Dock icon.
- Clicking the Dock icon with only a minimised window restores it, without opening a second copy.
- With the new icon: not inside a grey rounded square on macOS 26; Dock and Finder show Letter List; dark appearance shows the dark blue background; the Icon Composer preview shows the light background lighter at the top.

## UI redesign Phase 0: Design layer (2026-11-09)

The shared components (`SidebarTile`, `SenderAvatar`, `RelativeDueLabel`, pills, `StatusDot`, `TintedSymbolTile`, `TriageBar`, `StepIndicator`, `StatStrip`) have no screen of their own; each is checked where it is used. If you want to see them alone, open their `#Preview`s in Xcode in light and dark and check the gradients, the tinted fills (0.12 in light, 0.18 in dark) and the triage bar on macOS 26 (Liquid Glass) against macOS 15 (material).

## UI redesign Phase 1: Sidebar (2026-11-09)

Builds and Core tests pass (new `SidebarPresentationTests`). Nothing below has been checked in the running app or against `Today@2x.png`.

- Compare the sidebar with `Today@2x.png` in light and dark: tile gradients, row spacing, selection colour (follows the System Settings accent), the mini month and the footer.
- Mini calendar: clicking a day with a digest opens that day; days without a digest do nothing; today is the orange disc and the selected day uses the accent. The chevrons step the month, stop at the first and last months that have digests, and are disabled there. VoiceOver reads each day as a date ("Friday 6 November, 3 emails" or similar), not a bare number.
- Backlog Jobs: each row shows the ring (percent) and the subtitles (accounts, state). Check a running, paused, stopped, scheduled and finished job.
- Context menu on a Backlog row: Pause, Resume, Stop, Rename… and Delete… appear dimmed or enabled by state (Pause only while running, Resume for paused or stopped when nothing else runs, Delete never for a running job). Rename… edits in a sheet and saves; Delete… asks first.
- Footer: idle it reads "Next digest today at 6:30 am" (or "tomorrow at" after the time passes, updating without reopening the window); while a job runs or is paused it becomes the task capsule, and goes back when the job ends.

## UI redesign Phase 2: Today (2026-11-09)

Builds and Core tests pass; nothing below has been checked in the running app or against `Today@2x.png`.

- Compare Today with the design in light and dark: header, stat strip, run line, cards, two-column Worth Knowing grid, slim newsletter rows, Skipped disclosure and the floating triage bar (Liquid Glass on macOS 26, material on 15, solid with Reduce Transparency).
- Card states in `#Preview` "Suggestion cards" and "Window · Today with carry-over": selected, unselected, focused (2 pt ring), needs review, write failed with Try Again, read-only added and dismissed.
- Keyboard without a mouse: ↑ ↓ move focus, Space ticks, ⌫ dismisses, Return edits the focused title and returns focus to the card on Return or Escape, ⌘↩ adds, ⌘F opens search, ⌘R runs now, ⌘1 to ⌘5 switch view. None of these fire while a title or the search field is being edited.
- ⌘A on a focused card selects its section (uses `onCommand(selectAll:)`), and ⌘A inside a text field still selects the text. Confirm Edit > Select All is enabled when a card has focus. ⌘⇧A (Edit > Select None) clears the focused section. If either misbehaves, the fallback is explicit key handling in `CanvasScaffold`.
- Search (⌘F) filters Today, a past day and a Backlog by title, sender and evidence (and info and skipped text). With a filter hiding suggestions, the triage bar reads "N selected of M shown" and acts on the shown ones only.
- VoiceOver: a card reads as one element ("Title. High priority. Due in 11 days, Friday 20 November at 5:30 pm. From Philip Fraser. Selected.") with actions Select or Deselect, Dismiss, Edit Title, Change Due Date, Open in Mail. Check that Edit Title moves VoiceOver into the title field. Worth Knowing cards offer Pin, Save to Notes and Open in Mail; a group card offers Show or Hide Details.
- Hover Pin, Save to Notes and Open in Mail on a Worth Knowing card; the same three are in the right-click menu.
- Run line on a real day: "Processed on this Mac with Qwen3 4B", and the mixed "On this Mac and Gemini (N emails)" after a run that used Gemini. Finish time and duration need the job's start and end times.
- Info grouping with real mail: several emails from one sender on one day collapse into one card; a total shows only when every item has one clear amount in one currency.

## UI redesign Phase 3: Review Queue (2026-11-09)

Builds and Core tests pass; nothing below has been checked in the running app or against `Review-Queue@2x.png`.

- Compare Review Queue with the design in light and dark (previews "Review Queue", "Review inspector", "Queue rows"): list column (min 320, ideal 384) beside a flexible inspector, header with "N unreviewed · D days" and the filter button, day sections with Select All, rows with checkbox, title, "Sender · In 11 days" and the `!!!` red, `!!` and `!` grey marks. The review window opens at 1200 × 760 and can't shrink below 900 × 560 (this applies to every sidebar view).
- Native selection: the selected row uses the standard accent fill, with white title, meta, checkbox and priority marks (High is not left red on the accent fill). With the window inactive the selection is grey and still readable.
- Toolbar: previous and next chevrons, "1 of N" (counted within the filtered list), Search and Run Now. Check their order and spacing against the design, and that the search field sits before Run Now.
- Keyboard: ↑ ↓ move the selection in the list, ⌘↑ ⌘↓ move it from anywhere, Space ticks the selected row, ⌫ dismisses it and selects the next row (or shows "No Suggestion Selected" when none remain), Return puts the cursor in the inspector title, ⌘↩ adds the selected row (the inspector's button; the list footer's bulk button has no shortcut). Confirm the plain keys don't fire while the title, Notes or search field is being edited, and that clicking Add or pressing ⌘↩ with typed text in the title or Notes saves that text first and writes it to the reminder. In a text field ⌘↑ and ⌘↓ are swallowed by the toolbar buttons and do nothing; check that this is acceptable, or whether the cursor should jump to the start and end of the text instead.
- ⌘A selects the section of the selected row and ⌘⇧A (Edit > Select None) clears it. A `List` is an `NSTableView`, so confirm Edit > Select All is enabled with a row focused. A key handler on the list is the fallback when it is not, but confirm ⌘A does not select a different row or beep.
- Bulk add: tick several rows, press "Add N to Reminders" in the list footer. Only ticked rows in view are added; rows hidden by the filter, the search or an unloaded page are untouched, and the footer reads "N selected of M shown" while anything is hidden. With Reminders access denied the button is disabled with a tooltip.
- Inspector edits save immediately: title (Return or click away), List, Due date and time (Add Time, remove, Remove Due Date), Priority, Tag, Notes. After a date edit the hint flips from "found in email" to "set by you". Moving to another row while the title or notes field is still focused keeps what was typed. A bad title (under 3 characters or a link) reverts with a message. Nothing reaches Reminders until Add to Reminders.
- List picker: shows the real Reminders lists (the Mail Digest list appears once, as "(Default)"). Choose another list, press Add, and confirm the reminder lands in it with the notes typed in the inspector above the From, Subject and quote lines. Delete the chosen list in Reminders before pressing Add: the reminder should go to the default list instead.
- Priority is a three-segment control (Low, Medium, High) with High tinted red; check the selected High segment is legible in light and dark. There is no None segment (the model has no such level).
- Add Tag opens a menu of the eight category tags and replaces the shown tag (a suggestion has one category).
- From Email card: the evidence quote is the excerpt (Mail Digest does not store email bodies or snippets), fully highlighted in yellow (0.38 light, 0.3 dark) with primary text. The privacy and execution badges ("Private · Rule", "Local · Qwen3 4B") appear for a processed email and are omitted for older emails with no recorded routing. Sent time uses the email's received time.
- After Add or Dismiss the selection moves to the next row. Empty queue shows "Nothing to Review"; a filter or search with no matches shows an empty list and "No Suggestion Selected" in the inspector.
- Pagination: with more than 50 pending suggestions the list ends with "Showing 50 of N" and Load More. Dismiss Unselected is no longer in the Review Queue (the design has only the bulk Add); say if you want it back, for example in the filter menu.
- VoiceOver: a row reads as one element with the actions Select or Deselect, Dismiss and Open in Mail; Previous and Next, Filter and the remove buttons have labels.

## UI redesign Phase 4: New Backlog Job (2026-11-09)

Builds, Core tests (including the new estimate, naming, noise-folder, histogram, overnight and digest-less job tests) and Persistence tests pass. Nothing below has been checked in the running app or against `Step-*@2x.png`.

- Window: id `new-backlog-job`, title "New Backlog Job", 680 × 640, not resizable. Open it from the sidebar's "New Backlog Job…" and from the menu bar panel (⌘N); both are disabled while a job runs or Mail is unavailable. Compare the three steps with the PNGs in light and dark (previews "New Backlog Job · Mailboxes", "· Date Range", "· Ready to Start" use sample data).
- Step 1: INBOX shows as "Inbox"; the Mail Digest folder shows "Mail Cleanup folder"; empty and system folders sit behind "Show N Empty and System Folders" (an empty Inbox is still shown); the filter narrows by mailbox or account name; "Select Inboxes Only" ticks exactly the inboxes; footer "2 mailboxes · 3,630 emails" uses Mail's cached counts. Check the checkbox rows and sections look right in a grouped Form (the design draws them as grey cards).
- Step 2, with Full Disk Access: the chart appears within a moment, about 84 pt of plot height, no y axis, accent bars for the chosen range and grey for the 14 days before it up to today. Change preset, dates or mailboxes quickly: the old numbers vanish, "Counting…" shows, and only the latest result lands. Confirm in Console (category `mail`) that the chart does one query and no AppleScript runs for it. VoiceOver reads "Emails per day" with the summary.
- Step 2, without Full Disk Access: the chart area says "Daily volume needs Full Disk Access…" and the footer fills in only when the header listing finishes (this listing uses the existing JXA path, one call per mailbox, and can be slow on a large mailbox). Confirm the wait is acceptable.
- Footer "374 emails to read · 8 batches" and the Step 3 "Emails" row must equal what Start Job queues (compare with the job's Activity entry). "Skip Ignored Senders" removes mail from addresses on the Ignored list (exact address match, as the filter works today); check the count drops when you toggle it. "Skip Emails Already Processed" is shown on and disabled, because the runner never reprocesses an email.
- Preset "Since Last Job" starts on the day the newest earlier Backlog job's scope ended; with no earlier job it covers the last 30 days and says so.
- Step 3: the Name field starts as the default ("October Backlog" for a whole month or the month so far; "1–14 Oct Backlog" for part of one month; "20 Sep–14 Oct Backlog" across months), follows the range until you type, and a blank name falls back to the default. "Estimated Time" uses the median seconds per email of the last 5 finished jobs that ran on the local model, else 360 s; check it against a few real finished jobs in Activity. Check the "about N nights" text matches the Background Work window in Settings (default 10 pm to 7 am, not the 11 pm to 6 am in the mockup).
- Run mode: "Overnight While Plugged In" (default) stores the job paused as "outside the run window" when you start it during the day, and it appears in the sidebar at once as "Scheduled" and in Activity. Verify the whole path with a short window: set the Background Work window to open in a few minutes, create an overnight job with a handful of emails, leave the app running, and confirm the job starts by itself when the window opens, only while plugged in, and pauses again when the window closes. Also check: Resume on the scheduled job before the window opens stays paused with the reason; Stop on it leaves it Stopped and it never starts by itself; "Start Now" runs at once as before.
- Known gaps to decide: a scheduled job starts only while Mail Digest keeps running (a quit and relaunch leaves it paused until you press Resume, per Q44), and the Mac must be awake in the window (nothing keeps it awake). Selecting a Scheduled job in the sidebar shows "Scheduled" with the window times instead of an empty list.
- The old Step 3 email list with per-email ticks is gone (the design has no list). Say if per-email untick is still wanted.

## UI redesign Phase 5: Mail Access (2026-11-09)

Builds and Core tests pass (new `MailAccessPresentationTests`). Nothing below has been checked in the running app or against `Mail-Access-*@2x.png`.

- Compare both states with the PNGs in light and dark (previews "Ready" and "Limited"): header tile, two permission rows, Daily Digest Reads card, footer. The design draws grey cards; this uses a grouped Form, so check spacing and that the footer stays pinned while the form scrolls.
- Grant Full Disk Access in System Settings and come back: the window should flip to Ready by itself (key-window re-check), without pressing Check Again. Switch to other Mail Digest windows and confirm they don't trigger a check (watch the footer time). Revoke it and repeat.
- Automation: with it never asked, "Allow…" shows the system prompt; after denying, "Allow…" opens Privacy & Security > Automation. Check the "Not Allowed" and "Allowed" states and the footnote ("After you turn on Mail Digest…") appearing only while something is missing.
- Header copy for states the design doesn't draw (Full Disk Access on but Automation off: "Mail Automation Is Off"; neither route works: "Mail Digest Can't Read Your Mail Yet") needs a read and approval.
- Daily Digest Reads: with no stored choice every account's Inbox is ticked. Untick one, quit and relaunch: the choice persists, and the next daily run reads only the ticked mailboxes. Tick it again: the stored list returns to empty (default, new accounts included). The last ticked mailbox is disabled. Expand "Show Other Mailboxes N" and tick Archive or a custom folder; Sent, Junk, Deleted, empty and system folders must not appear.
- Check Again and "Checked just now / 8:10 pm" text (12-hour lowercase); the old full mailbox dump and Refresh button are gone.
- Settings no longer has "Daily mailboxes"; until Phase 6 adds the read-only summary there is no pointer to Mail Access there.

## UI redesign Phase 6: Settings (2026-11-09)

Builds (xcodebuild) and Core tests pass (new `SettingsRestructureTests` and Activity grouping tests). Nothing below has been checked in the running app or against `Settings-*@2x.png`.

- Window: Settings opens at 520 wide with General, Mail, Models and Senders tabs. Tab heights are fixed guesses (General 660, Mail 400, Models 470 with Cloud off and 720 with it on, Senders 560); check each fits its content, scrolls if it must, and that the window resizes cleanly when you switch tabs or toggle Cloud Digest. Compare with the PNGs in light and dark; the design draws grey cards, this is a grouped Form.
- General: Look Back is a popup of 24, 48 and 72 Hours; with an older stored value (for example 60) that value is also listed and stays selected. "Limit Emails per Run" shows its stepper only when on. "Only Run Overnight" shows the From and Until pickers only when on, and its subtitle names the stored window (default 10 pm to 7 am, not the mockup's 11 pm to 6 am). The window times also apply to Overnight While Plugged In backlog jobs whether or not this toggle is on; the UI does not say so (the design does not either). Delete All History… still confirms first and reports its result. Launch at Login still asks for approval when macOS requires it.
- Add Reminders To: with Reminders access, the popup lists your real lists and the one in use is selected (an existing user's "Mail Digest" list shows as selected). Choose another existing list, approve a suggestion, and confirm the reminder lands there and that no list in Reminders was renamed. Delete the chosen list in Reminders and approve again: it is recreated under its old name and the popup shows "<name> (New List)" until then. Without access the popup is replaced by the list name, an explanation, and Allow Access… or Open Reminders Settings…; check both states (revoke access in System Settings, or reset it with `tccutil reset Reminders`). The old free-text list name field and the rename on edit are gone; the Welcome window still has its list-name field.
- Mail: the status row follows Mail Access (green "Full Access" when both permissions are on; orange otherwise), Mail Access… opens the Mail Access window, and Daily Digest Reads reads "All Inboxes" until you change it in Mail Access, then lists the chosen mailboxes (more than 3 shows "N mailboxes"). Change the selection in Mail Access with Settings open and confirm the text follows. File Handled Emails is the old auto-file switch; turning it on still only affects mail handled afterwards.
- Models: Ollama shows Running or Not Running (quit Ollama to check) and Edit URL… edits the address; a bad address cannot be saved and blank restores the default. Digest Model lists installed models (not the two System One models) and keeps a stored model that is not installed, marked "(Not Installed)". Cloud rows appear only when the toggle is on. (Superseded by Q93, see "Cloud providers" below: the toggle needs no key and the Gemini rows now live under a Cloud Provider picker.) Change… and Test Connection work with a real key (nothing is shown or logged); Remove asks first (and no longer turns Cloud Digest off). Cloud Model lists the default (and any model you typed); Other… opens a field for another model ID. Check the Privacy Threshold slider ends at 80% and 99% (the code's range; the design's 50 to 99 would weaken the approved Q62 range) and its end labels. The orange box is always visible, in light and dark, and What Gets Sent… shows the full disclosure; the Gemini API Terms link opens https://ai.google.dev/gemini-api/terms.
- Senders: the segmented control shows the counts; each list's description changes with it; + opens an address field (whole domains are rejected with a message), − removes the selected row (also Delete), and Add from Recent Senders… lists people from mail already read on this Mac. Rows show the address only (names are not stored), with no rule label because only full addresses match; an old entry such as "@example.com" shows "Won't Match". The footnote states the real order (Blocked, VIP, Ignored, Newsletters).
- Context menus: right-click a suggestion card, a Review Queue row and a Worth Knowing card (single and group). Add Sender to VIP, Block Sender, Ignore Sender and Trust as Newsletter add the sender to that list (visible in Settings > Senders) and are dimmed when already there.
- Jobs tab is gone. Activity: each job row shows Resume (paused, stopped, failed with emails left) and Retry Failed where they apply, and a stopped job stays stopped until you press Resume. Expanding a row shows Summary (scope, totals, processing time). The filter menu (top right) has Show Empty Runs, off by default; check that a running, paused, stopped or failed job is never hidden. Start the same backlog job twice with the same range so two finished runs sit side by side and check they collapse to "Run 2 times" and expand.
- Menu bar: with a stopped Daily job, "Review Daily Job…" now opens the review window on Activity, where Resume is. The panel itself shows no Resume for a stopped job (Daily or Backlog); a paused job still has Resume on its card or the Daily row. Say if the panel should resume a stopped job directly.

## UI redesign Phase 7: Polish (2026-11-09)

Builds (xcodebuild) and Core tests pass. This was a code-level pass; nothing below has been checked in the running app.

- Dark Mode: walk every screen (Today, Review Queue, Logbook, Mail Cleanup, Activity, New Backlog Job, Mail Access, Settings) in dark. Warning pills, banners, the Mail Access tile and the billing note should use the stronger 0.18 tint; the evidence highlight is yellow at about 30% with readable text; sidebar tiles and avatars keep their gradients. The menu bar panel's orange attention card still uses a fixed 0.12 fill (frozen panel); check it reads fine in dark.
- VoiceOver on Today and Review Queue: each card reads as one element with Select or Deselect, Dismiss and Open in Mail actions; the priority and category menus read "Priority, High" and "Category, events"; the toolbar buttons read Run Now, Previous Suggestion, Next Suggestion, Filter (value On or Off) and Open Email in Mail. Check there are no unlabelled buttons.
- Reduce Motion (System Settings > Accessibility > Display): ticking a card, revealing hover actions, the Undo toast and scroll-to-card should not slide or bounce. Reduce Transparency: the triage bar becomes a solid background with a hairline.
- Empty and error states: Today before any digest ("No Digest Yet", "Your first digest runs tomorrow at 6:30 am." with your configured time, and Run Now); after earlier digests but none today it says "Your next digest runs ..."; a Today with no mail ("Inbox Zero for Today"); Today with every suggestion decided ("All Caught Up", Open Logbook jumps to Logbook; Reviewed list and Worth Knowing still show below it); Mail Cleanup empty ("Nothing to Clear"); a failed load ("Couldn't Load This Digest" with Try Again; hard to trigger, so a code review only unless you break the database).
- Banners at the top of the canvas: quit Ollama and run: the banner offers Start Ollama and Retry. Turn Mail Automation off for Mail Digest: "Open Privacy Settings" opens Automation. Remove Full Disk Access: a grey (not orange) banner with "Grant Access…". Deny Reminders: "Open Privacy Settings"; Add to Reminders is disabled and its tooltip says why. No Download Model button exists because the app has no model download path; a missing model still shows the error text with `ollama pull`.
- Dock icon (Q75): open the review window, Settings, Mail Access and New Backlog Job in turn; the Dock icon stays while any is open and disappears after the last closes. Minimise the only window: the icon stays. Hide with Cmd-H and unhide. The menu bar panel, popovers, sheets and alerts alone must not show the icon. Clicking the Dock icon with no window open opens the review window. New observers (occlusion change, deminiaturise, unhide) were added so a window that is hidden without closing still updates the Dock; confirm no flicker when covering windows with other apps.
- Copy: skim every window for Title Case buttons and headings, ellipsis where a window opens, Australian spelling and no em dashes. Known unchanged copy in the frozen menu bar panel: none found.

## Overnight Backlog jobs start automatically (2026-11-10)

Core tests and the xcodebuild build pass; nothing below has been checked on the running app. Overnight-only jobs are an exception to Q44 (recorded separately).

- Relaunch inside the window: create a Backlog job as "Overnight While Plugged In" outside the window, quit, change the window in Settings (or the clock) so now is inside it, plugged in, and relaunch. After onboarding and Mail access pass, the job should start by itself and show progress.
- Relaunch outside the window: same job, relaunch outside the window; it stays "outside the run window" and starts at the window start without further action.
- Quit mid-run: quit while an overnight job runs (inside the window, plugged in) and relaunch; it should continue by itself. A job you paused or stopped must stay paused or stopped after a relaunch, and an ordinary (not overnight) Backlog job paused earlier must not restart.
- Sleep through the window start: with a waiting overnight job, plugged in, close the lid or sleep the Mac before the window opens, then wake it inside the window (and once after the window closed: it must stay waiting). The job should start on wake. No wake events are scheduled, so a Mac that stays asleep does nothing.
- Window edit: change the window times in Settings while a job waits; it should start (or keep waiting) straight away with the new times.
- Power assertion: while an overnight job runs on mains, `pmset -g assertions` should list "Mail Digest is running an overnight job" (PreventUserIdleSystemSleep). It must disappear on Pause, Stop, finish, failure, when unplugged (the job also pauses) and on quitting the app. An ordinary Backlog job and the Daily job must not hold it.
- Access gate: revoke Mail access (or skip onboarding) with a waiting overnight job and launch inside the window; nothing should start and no Mail prompt should appear. Granting access and then any re-evaluation (wake, window boundary, power change, Settings change) starts it.
- Copy: change the window to something other than 10 pm to 7 am and check every overnight string (New Backlog Job, Settings, sidebar) shows the new times. A source search found no hard-coded overnight times.

## Review Queue footer, reminder notes, menu bar Resume (2026-11-10)

Core tests and the xcodebuild build pass; nothing below has been checked on the running app. The menu bar item under "Activity" above (panel shows no Resume for a stopped job) is superseded by this section.

- Review Queue footer: reads "<n> of <shown> selected", "Dismiss <k> Unselected", "Add <n> to Reminders" with a filter, a search and Load More pending. Dismiss Unselected only removes unticked pending rows currently shown (not failed ones, not ones behind Load More or hidden by the filter); disabled at 0 and while working. With more than 10 it shows a confirmation naming the number with a red Dismiss button; with 10 or fewer it dismisses at once.
- Inspector: "Tags" is now "Category", a pop-up of #uni ... #other; choosing one saves it and the reminder's hashtag follows.
- Notes: a suggestion with no saved notes shows "From <sender> · <subject>" as editable text. Leave it alone and nothing is saved; edit it and it is saved; clear it and select another row and back, and the default shows again. Add one (inspector and bulk) and check the Reminders note is notes line, quote line, #category, and the link opens the email in Mail.
- New Backlog Job step 2: no "Skip Emails Already Processed" toggle; a plain line "<n> already processed will be skipped" ("Counting…" until the preview is ready). Skip Ignored Senders is still a toggle.
- Menu bar: stop a Daily job and a Backlog job in turn. The panel shows "<job name> · Stopped at <done> of <total>" with a Resume button; Resume continues it without opening a window. A paused job shows "<job name> · Paused at <done> of <total>" in one block (no second row). The Daily row reads "Resume Daily Digest" for a paused or stopped Daily job and "Retry Daily Digest" for a failed one; a stopped Backlog job does not change it. The review window's toolbar button reads Resume for a stopped Daily job. Nothing resumes by itself after a relaunch (Q48).

## Whole-domain sender rules (manual check)

- In Settings > Senders, add `@example.com` to a list through the + popover: the row should read "Anyone @example.com" with "Whole domain" on the right, and `name@example.com` should show "Address". Typing `@` or `@com` should show the explanation and disable Add.
- Confirm a domain rule affects a real preview: put a domain on Ignored, open New Backlog Job, and check the "skip ignored senders" count includes mail from that domain and its subdomains.
- Right-click a card whose sender is covered by a listed domain: that list's menu item should be dimmed. Check VoiceOver reads the domain rows sensibly.

## Sender logos (2026-11-10)

Core tests and the xcodebuild build pass. A scratch program confirmed that `NSImage(data:)` renders a BIMI-style SVG correctly on macOS 15 and that the DNS TXT resolver returns `default._bimi.cnn.com` in about 0.2 s (DNS only). Nothing else below has been checked on the running app.

- Off by default: Settings > General has a "Sender Logos" section with "Show Sender Logos" (subtitle "Fetches logos from senders' websites. They can see your IP address."), switched off on a fresh install and after upgrading from older settings.
- Nothing fetched while off (network monitor): with the switch off, open the review window, Settings > Senders and a few cards, and run a Daily job; watch with Little Snitch / `sudo tcpdump -i any port 53 or port 443` / Network Instruments. There must be no DNS query for `_bimi` names, no request to any sender site and no icon-service request, other than Ollama / Mail traffic. Avatars show initials.
- On: switch it on; avatars for non-personal domains should change from initials to logos within a few seconds, with no size change or jump. Each domain is requested at most once (check the monitor, then scroll the lists again). Senders at gmail.com, googlemail.com, outlook.com, hotmail.com, live.com, icloud.com, me.com, mac.com, yahoo.com and proton.me, and their subdomains, never produce a request.
- Subdomain folding: mail from `email.uber.com` should query `default._bimi.uber.com` and `https://uber.com/apple-touch-icon.png`, never the subdomain.
- Off again: switch it off; website logos disappear at once (initials), no new requests start, and logos taken from a mail's BIMI header (below) still show.
- Cache: `~/Library/Application Support/MailDigest/SenderLogos/` holds `index.json` and hash-named `.svg`/`.png` files (header logos and website logos are separate files). Failures are in the index with a date, and a failed domain isn't requested again for 30 days (change the date in `index.json` to older than 30 days and relaunch to see one retry).
- BIMI header: process an email that has a `BIMI-Indicator` header (a bulk sender that publishes BIMI, e.g. a large bank or retailer), then check its avatar shows the logo with the switch off and no network traffic. This only happens for mail processed after this build (headers aren't stored).
- Fallbacks: a domain with no logo, a timeout, a redirect to http, an oversized or invalid image all end as initials. Check VoiceOver still reads sender names from the row text (the avatar stays hidden from accessibility).
- Settings window height: confirm the General tab (now taller by one section) still fits and scrolls on a small display.

## Download Model (2026-11-10)

Core tests and the xcodebuild build pass. Nothing below has been run against a real Ollama; no model was pulled while building this.

- Settings > Models with Ollama running: choose a digest model that isn't installed (edit `ollamaModel`, or pick a tag in the privacy popup that isn't pulled). The row shows "(Not Installed)" and a "Download Model" button; with Ollama quit, the button is absent and the row says Not Running.
- Click Download Model: the bar and "1.2 GB of 2.5 GB · 48%" appear ("Preparing…" first), the percentage never goes backwards when a new layer starts, and the numbers don't jitter in width. Switch to another Settings tab and back, and close and reopen the Settings window: progress continues.
- Cancel: the request stops (Ollama log shows the pull aborted), the row returns to the button. Click Download Model again: it resumes from the partial layers (the percentage starts above 0).
- Finish: the "(Not Installed)" label and button disappear without reopening Settings; the model is selectable and `ollama list` shows it.
- Failure: quit Ollama mid-download (or edit the URL to an unreachable one and start): a plain-English message with Try Again appears. Try a nonexistent tag (for example `qwen3:nonexistent`): Ollama's error is shown, not a generic one.
- Banner: stop a run whose configured digest model isn't installed; the run-problem banner shows "Download Model" beside Retry. It starts the download and opens Settings on the Models tab. Check the banner clears on Retry after the download finishes.
- VoiceOver reads the progress with its label and value, and the Download Model, Cancel and Try Again buttons by name.
- Network monitor: during a download the only traffic is to the configured Ollama URL.

## Today follow-ups (2026-11-10)

Core tests and the xcodebuild build pass. Screenshots (light and dark) were checked with an injected clock. The time-based behaviour on a live clock has not been watched.

- Greeting on the hour: leave the review window open on Today across 4:59 to 5:00 am, 11:59 am to 12:00 pm, 5:59 to 6:00 pm and 9:59 to 10:00 pm (or change the Mac's clock). The greeting should change to Good morning, Good afternoon, Good evening and Hi without reopening the window. The greeting follows the Mac's time zone; the date overline above it still uses the fixed review calendar.
- Empty-state copy at the scheduled time: with no digest today and the run set a couple of minutes ahead (Settings > General), leave Today open. It should read "Not Ready Yet" with the time, then flip to "Today's Digest Didn't Run" at the scheduled minute. On a brand-new install it should say "No Digest Yet / Your first digest runs at <time>" instead, before and after.
- Reasons: after the time, a failed Daily job should show its stored error, a paused or stopped one says so, a failed start (Ollama quit) shows the banner text, and with none of those it says the Mac may have been asleep or Mail Digest wasn't open. Check that "Run Now" is dimmed exactly when the toolbar's Run Now is, and that Return triggers it.
- Toolbar button: Run Now, Pause, Resume and Retry icons should look level with the title at normal and large text sizes, and Run Now should stay left of the search field.

## Today empty state with a job problem (2026-11-10)

Builds and Core tests pass; not checked in the running app.

- With a failed Daily job and no digest today, the empty state reads "Today's Digest Didn't Run" with the reason and its prominent button says Retry, even before the scheduled time and on a first launch. Clicking it retries the same job.
- With a paused or stopped Daily job, the button says Resume and resumes in place. It matches the toolbar's label and enabled state.
- While a Daily job runs, the state reads "Today's Digest Is Running" and Run Now is disabled.

## Reminder steps and routing coverage (2026-11-22)

Nothing below has been checked on the running app, in Reminders or against real mail yet.

- Review panel: "· N steps" on queue rows, bulleted steps on cards and settled rows; VoiceOver reads steps; long steps truncate cleanly.
- Approve a folded suggestion: Reminders notes show the `• step` lines between the From line and the evidence quote (macOS and iOS).
- Real mail: `.partial.emlx` items with all parts present show as inspected; those with `Attachments/<rowid>` or placeholder parts stay "Content not fully inspected".
- Real mail: Hide My Email senders (e.g. Glassdoor, EatClub) are matched by sender rules using the original address; a relayed bank/government sender stays local.

## Cloud providers: Claude Code and master switch (Q93)

Core tests and the xcodebuild build pass. None of this has been seen in the running app, and Claude Code has not been run from the app yet.

- **Critical, Finder launch:** launch the built app from Finder (double-click, not `open` from Terminal or Xcode's Run). In Settings > Models turn Cloud Digest on, choose Claude Code and accept the notice. The status row must read "Signed in" (with the plan) and Test Connection must succeed. An earlier reduced-environment `claude auth status` reported `loggedIn: false`. If the app shows "Not signed in" while Terminal shows you are signed in, do not guess: record the app's environment (is `HOME` set? is `PATH` minimal? any `ANTHROPIC_*` or `CLAUDE_*` variables?) and whether the Keychain item for Claude Code is readable from the app (a Keychain prompt may have been denied), then compare with `env` and `claude auth status` in Terminal.
- Layout, light and dark: the Cloud Digest section shows only the toggle and its caption while off. When on it reads: caption (orange with "Review Privacy Notice…" when inactive), Privacy Check Model, Privacy Threshold, Cloud Provider (Claude Code listed first, Gemini second), then the provider's rows and its disclosure box. Check the fixed tab heights (430 off, 800 on) fit the content for both providers and that nothing is clipped.
- Cloud Digest toggle turns on without a Gemini key. With an unaccepted notice for the selected provider the sheet appears; Cancel turns the switch back off. Change provider while on: the new provider's sheet appears if its notice is not accepted; Cancel keeps the provider and the switch, the caption says inactive, and "Review Privacy Notice…" reopens the sheet.
- Acknowledgement flows: Gemini sheet (unchanged text, button now "I Understand, Use Gemini") and Claude Code sheet (text per spec, both Anthropic links open https://www.anthropic.com/legal/consumer-terms and https://www.anthropic.com/legal/privacy). Accepting Claude Code does not change the Gemini acknowledgement and the reverse. Esc cancels.
- Gemini: removing the saved key keeps the toggle on, the caption says it is inactive until a key is saved, and a run keeps everything local ("No Gemini API key").
- Claude Code status row: found (path with `~`, version, "Signed in", plan name), not found (Claude Code Setup link opens https://code.claude.com/docs/en/setup; test by temporarily renaming the binary), not signed in (`claude auth logout` in Terminal, then Check Again: tells you to open Terminal and run `claude`), too old (cannot be forced easily; confirm only by code review of the 2.1.323 minimum unless an old version is at hand). Check Again re-probes without relaunching. Account email and organisation never appear anywhere.
- Test Connection with Claude Code: reports "Claude Haiku 5.5 answered through your Claude sign-in" (or the model it reports), and with Sonnet selected the Sonnet model. Signed out gives the friendly sign-in message. It is disabled unless Claude Code is found and signed in.
- A real run with Claude Code selected (synthetic allowlisted newsletter, complete inspection, Privacy Check Model installed): the Activity row reads `Cloud · Claude Haiku 5.5`. Quit Claude Code's sign-in (`claude auth logout`) and run again: the job still finishes locally with reason "provider unavailable", with no automatic switch to Gemini. Make Claude Code fail mid-run (for example a short network cut): the row reads "Claude Code failed → Local Qwen3 4B".
- Privacy Check Model not installed: the Download Model row (Q87) appears under it as soon as Cloud Digest is on.
- Old Activity rows that used Gemini still read "Gemini failed → Local ..." and "Gemini could not process it, so this Mac did."; the local-reasons summary now says "cloud failed".
- No provider by default: with fresh settings, Settings > Models > Cloud Provider shows "Choose…" (no provider selected), turning Cloud Digest on shows no notice sheet and the caption says to choose a provider, and a run stays local (reason "no cloud provider chosen") until one is picked; picking one shows its notice if needed. An existing Gemini user (notice accepted before Q93) still sees Gemini selected.

## Auto-file destinations (Q94)

Core tests and the xcodebuild build pass. Nothing here has been checked in the running app or against real mail.

- Settings > Mail: the two pickers ("Reminders Added or Info Only", "All Suggestions Dismissed") appear only while "File Handled Emails" is on, with their secondary explanations. Check light and dark, that the tab height (400 off, 540 on) fits without clipping, and that VoiceOver reads each picker with its explanation. The footer reads "Nothing is deleted: Trash keeps mail until Mail empties it."
- Defaults: a fresh setup shows Mail Digest Mailbox for the first picker and Trash for the second. A user who already had File Handled Emails on sees Trash for dismissed mail.
- Dismiss every suggestion of an email (with the toggle on, finished after enabling): it lands in that account's Trash, the Mail Cleanup toast reads "Moved 1 email to Trash.", and Undo puts it back in its original mailbox. It is not auto-filed again after Undo.
- An email with an approved reminder goes to the account's Mail Digest mailbox ("Moved 1 email to Mail Digest."). A batch with both shows "Moved 3 emails: 2 to Mail Digest, 1 to Trash." and one Undo restores all of them.
- On My Mac mail with a Trash destination reports a failure (no Trash target), is not moved anywhere else and is not retried.
- Switch both pickers (reminders to Trash, dismissed to Mail Digest) and confirm routing swaps; blocked/ignored senders follow the first picker.

## Bulk notification routing (Q95–Q97)

- Run the rebuilt app on new mail with Cloud Digest on. Relayed (Hide My Email) Glassdoor, Letterboxd, LinkedIn job/newsletter and `email.openai.com` mail shows `Public · Trusted Sender`. Other relayed promotions (DoorDash, YHA) with non-sensitive ≥ 0.85 show `Public · System One`, and the info popover reads "Public floor: Waived (Hide My Email)".
- A relayed reply (subject "Re: …", e.g. a Nike support thread) gets no waiver: the popover shows the 85% public floor.
- An account-verification email ("Confirm your email address…") shows `Private · Rule` with rule `kw.credentials`.
- `messages-noreply@`, `messaging-digest-noreply@` and `invitations@linkedin.com` are not `Public · Trusted Sender`.
- Older Activity rows from before Q96 still open their popover without errors.
