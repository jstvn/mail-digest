# Questions

Spec ambiguities the agent did not guess at; please answer.

## Open questions

Each item says what the spec leaves open and the interim choice the build uses, so work wasn't blocked. Please confirm or correct.

1. **Job types before T20.** `JobRunner.start(_: JobPlan)` (T08) and the `DigestStore` queue methods need `JobPlan`, `Job`, `JobItem`, `JobKind` and friends, which the spec only details under T20. *Interim:* T02 defines the plain types (`Models/Jobs.swift`); T20 adds `JobPreview`, the preview builder and the progress/activity logic.
2. **`MailActions` protocol in T02 or T17?** T02 says "protocols from … Mail cleanup", and T17 also lists the protocol. *Interim:* protocol and `MailActionResult` in T02 (T03's `RecordingMailActions` needs them); T17 does `ProcessedEmailSelector` and undo bookkeeping.
3. **`DigestStore` methods beyond the spec's list.** The spec lists method names only. *Interim additions:* `recentSuggestions(since:)` (needed for validation rule 6, 14-day dedupe), `updateJob(_:)`, `items(job:)` (activity log), `isQueued(_:)` ("already processed or queued ids are dropped"), `recordItemOutcome(_:outcome:seconds:)`. `markProcessed` takes a `ProcessedEmail` (id, receivedAt, tier, processedAt) to match the `processed_email` table. "Appended per email" is done by re-saving (upsert) the run's `Digest` after each email.
4. **`SkippedEmail`, `MailboxKind`, `ExtractionResult`, `Notifier`, `Clock` shapes** aren't spelled out. *Interim:* `SkippedEmail {id, sender, subject, reason}`; `MailboxKind` = inbox, archive, sent, drafts, junk, trash, custom; `ExtractionResult` mirrors the JSON schema (snake_case keys); `Notifier.post(_ message: String) async`; `Clock.now() -> Date` (named `Clock` per spec; it shadows the stdlib `Clock` inside the module).
5. **`Decision` isn't `Equatable` in the spec**, but "all models are Equatable". *Interim:* made it `Equatable` (same for `MailActionResult`).
6. **Osascript timeout:** Mail ingestion says 60 s per call; the Risks table says 120 s. Which one? (Affects T11 only.)
7. **`EvalCLI`** is in the repo layout and Testing section but has no task ID. *Interim:* T01 created a stub executable that prints "not implemented yet".
8. **`FetchMail.js` output shape.** "Missing ids are skipped and reported", but the spec doesn't say how they're reported. *Interim:* `{"messages": [...], "missing": ["id", ...]}`; the decoder also accepts a bare array.
9. **VIP vs blocked sender.** If a sender is on both lists, which wins? *Interim:* VIP wins ("VIP senders always land here"), and VIP also overrides the info-only signals. Block lists match exact addresses only (no domain wildcards).
10. **`Auto-Submitted: no`** means a human sent the email (RFC 3834). *Interim:* only values other than `no` count as info-only.
11. **"Bare tracking URLs" in the cleaner.** *Interim:* only lines that are nothing but a URL get removed; URLs inside sentences stay, so evidence can still match verbatim.
12. **`{today_iso}` in the prompt.** *Interim:* the date only (`2026-11-04`). Adding the weekday ("Wednesday") would probably help the model resolve "this Friday"; should I add it?
13. **Rule 3 "date or time words".** *Interim:* weekday and month names (plus 3-letter forms, with "may" counted only next to a number), relative words (today, tomorrow, week, weekend, morning, …), time patterns (5pm, 17:00) and date patterns (9/11, 2026-11-09, ordinals). The list is in `SuggestionValidator.swift`.
14. **Title length.** The prompt asks for under 60 characters, but validation allows 3 to 80. *Interim:* both kept as written; the validator accepts up to 80.
