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
- **T12 `GRDBDigestStore`** must implement every `DigestStore` method. Beyond the spec's list: `digest(id:)`, `recentSuggestions(since:)`, `updateJob`, `items(job:)`, `isQueued`, `recordItemOutcome(_:outcome:seconds:finishedAt:)`, `requeueFailed(job:)`. `InMemoryDigestStore` is the reference behaviour; consider running the same tests against both.
- **T13/T14 review panel.** Use `ReviewActions` for selection, edits, approve and dismiss; `ReviewActions.reminderNotes` and `messageURL` build the EventKit notes and `message://` link. Category edits live in `ReviewState.categoryOverrides` (QUESTIONS 19).
- **T14 tags.** EventKit has no public API for Reminders tags, so the category is written as `#category` at the end of the notes. Check how this shows in Reminders on macOS 26 and iOS (does it become a real tag or stay searchable text?).
- **T15 scheduler.** Call `JobRunner.recoverOnLaunch()` on every launch before anything else, then `startDaily()` from the 15-minute check.
- **T19 job setup.** Pass a plan with a fixed `to` date to `JobRunner.preview(_:)`, then pass the same plan (plus unticked ids in `excludedMessageIDs`) to `start(_:)`; `JobPreviewBuilder.startTitle` and `ActivityFeed` produce the strings in the spec.

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
- **Not tested / follow-up validation:** Gmail, Outlook.com specifically, empty-body partials, missing `.emlx` files, nested folders with messages, mailbox names containing a literal `/`, a busy or locked database, FDA denial, Automation denial, index-based JXA paging for very large mailboxes, and whether `FetchMail.js` / mail-action lookup by canonical Message-ID is safe when `Resent-Message-ID` is present. The last item must be verified during T11-B before relying on JXA ID-based lookup.

## Open items

- The core package builds and its tests pass on macOS (Xcode 26.6 SDK), after the `Category` fix. The app target also builds with `CODE_SIGNING_ALLOWED=NO`; its visual menu-bar check is still pending. Ollama 0.40.14 with `qwen3:4b` answered a raw `/api/chat` call (`think: false`, JSON-schema `format`) with valid JSON; still unverified: `OllamaClient.healthCheck()` and one `extract` through the Swift code (item 2), plus the feature-level app-target work in T11–T16, T18 and T19.
