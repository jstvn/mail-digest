# Mac TODO

Things the cloud agent could not verify; check on the Mac.

## Checkpoint after T09 (core ready for a first Mac build)

**Done in the Linux session:** T01 to T09, then T17 and T20. All of it lives in `Packages/MailDigestCore`, which is Foundation only and tested on Linux with Swift 6.0.3. No Mac-only task (T10 to T16, T18, T19) has been started, so there is no `MailDigestApp/` folder or Xcode project yet.

**What exists:**

- Models and protocols (`Models/`, `Protocols/`), with interim choices listed in `docs/QUESTIONS.md`
- Fakes for tests and SwiftUI previews (`Testing/`): `FixtureMailSource` (including a generated 3,000-message inbox), `StubLLMClient`, `InMemoryDigestStore`, `FixedClock`, `RecordingReminderWriter`, `RecordingMailActions`
- `MailJSONDecoder`, `MailFilter`, `EmailCleaner`, `OllamaClient` (+ `Prompts`, `ExtractionSchema`), `DateResolver`, `SuggestionValidator`, `DigestPipeline`, `JobRunner`, `ReviewActions`, `RetentionPolicy`, `ProcessedEmailSelector`, `MailCleanup` / `UndoLedger`, `JobPreviewBuilder`, `ActivityFeed`
- 18 fixture emails with canned model answers (`Tests/MailDigestCoreTests/Fixtures/`)

## First Mac build: please check

1. `cd Packages/MailDigestCore && swift build && swift test --parallel` passes on macOS (only verified on Linux). The tests mix XCTest (2 files) and Swift Testing (the rest); both should run under `swift test` with Xcode 16+.
2. `OllamaClient` uses `dataTask` wrapped in a continuation (not `URLSession.data(for:)`) so it behaves the same on Linux. Check it against a real Ollama: `healthCheck()` with `qwen3:4b` pulled, then one `extract` on a real email. Confirm `think: false` is accepted by your Ollama version and that `format` with the JSON schema returns valid JSON.
3. **`Clock` name clash.** Core defines `public protocol Clock`, which shadows Swift's `Clock` inside the package. In the app target, where both are visible, an unqualified `Clock` may be ambiguous; write `MailDigestCore.Clock` if the compiler complains.
4. Swift 6.0.3 crashed the compiler on `await #expect { … } throws: { … }` with a pattern-matching closure, so two OllamaClient tests use `do`/`catch` instead. A newer Xcode toolchain shouldn't care.
5. `Package.swift` declares `platforms: [.macOS(.v15)]` and Swift 6 language mode. Check the app target's local package dependency resolves with the same settings (T10).

## Notes for the Mac-only tasks

- **T11 `FetchMail.js` output.** The decoder expects `{"messages": [...], "missing": [...]}` (a bare array also works). `rawHeaders` should be the raw header block (e.g. `message.allHeaders()`); `receivedAt` from `toISOString()` is fine (milliseconds are accepted). Nested custom folder names (e.g. "Projects/Uni") must be verified against what `ListMailboxes.js` reports (spec: note in this file).
- **T11 timeout.** The spec says 60 s per osascript call in one place and 120 s in another (QUESTIONS 6).
- **T12 `GRDBDigestStore`** must implement every `DigestStore` method. Beyond the spec's list: `digest(id:)`, `recentSuggestions(since:)`, `updateJob`, `items(job:)`, `isQueued`, `recordItemOutcome(_:outcome:seconds:finishedAt:)`, `requeueFailed(job:)`. `InMemoryDigestStore` is the reference behaviour; consider running the same tests against both.
- **T13/T14 review panel.** Use `ReviewActions` for selection, edits, approve and dismiss; `ReviewActions.reminderNotes` and `messageURL` build the EventKit notes and `message://` link. Category edits live in `ReviewState.categoryOverrides` (QUESTIONS 19).
- **T14 tags.** EventKit has no public API for Reminders tags, so the category is written as `#category` at the end of the notes. Check how this shows in Reminders on macOS 26 and iOS (does it become a real tag or stay searchable text?).
- **T15 scheduler.** Call `JobRunner.recoverOnLaunch()` on every launch before anything else, then `startDaily()` from the 15-minute check.
- **T19 job setup.** Pass a plan with a fixed `to` date to `JobRunner.preview(_:)`, then pass the same plan (plus unticked ids in `excludedMessageIDs`) to `start(_:)`; `JobPreviewBuilder.startTitle` and `ActivityFeed` produce the strings in the spec.

## Open items

- None of the above has been run on a Mac yet.
