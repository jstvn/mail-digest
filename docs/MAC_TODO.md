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
- Remove Key: the item is gone, status reads "No API key" and the Cloud Digest toggle is off.
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
