# Mail Digest

Native macOS menu bar app (Swift 6, SwiftUI) that reads new mail from Mail.app each morning, uses a local Qwen3 4B model via Ollama to summarise emails and suggest reminders, and lets the user approve what goes into Apple Reminders. Full spec: `docs/SPEC.md`. Build tasks T01 to T20 in the order given in its "Implementation tasks" section.

## Build and test

- Core package (Linux and Mac): `cd Packages/MailDigestCore && swift build && swift test`
- Narrow test run: `swift test --filter <TestName>`
- App (Mac only): `xcodebuild -project MailDigestApp/MailDigest.xcodeproj -scheme MailDigest build`

## Environment

This repo is built in a Linux cloud session. There is no Xcode, AppKit, SwiftUI, EventKit, Apple Events or Ollama there.

| Part | Where | Builds on Linux? | How to verify |
| --- | --- | --- | --- |
| `MailDigestCore` | Swift package, Foundation only | Yes | `swift build`, `swift test` |
| `MailDigestApp` | Xcode macOS app (SwiftUI, EventKit, JXA scripts) | No | Write carefully; Justin builds on his Mac |

If `swift` isn't installed in the container, install a Swift 6 toolchain first (for example via `swiftly`).

## Project rules

1. Put every piece of logic that doesn't need an Apple framework into `MailDigestCore`, behind a protocol. The app target holds only thin adapters and UI.
2. Never import AppKit, SwiftUI, EventKit, SwiftData or Combine in `MailDigestCore`.
3. For networking, add `#if canImport(FoundationNetworking)` / `import FoundationNetworking` so `URLSession` compiles on Linux.
4. Swift 6 with strict concurrency; models are `Sendable` structs.
5. Tests never need a network, Ollama or Mail. Use the fakes and JSON fixtures described in the spec. Inject `Clock` instead of reading the time.
6. **[Mac-only]** tasks: write the code against the APIs named in the spec, and list anything you couldn't verify in `docs/MAC_TODO.md`.
7. Don't add features that aren't in the spec. Put ambiguities in `docs/QUESTIONS.md` instead of guessing.
8. Add short, clear English comments where they help: a `///` doc comment on public types and functions, and a brief comment above non-obvious logic explaining why, not what. Don't comment the obvious.
9. Commit after each task with a message naming the task ID, for example `T06: Ollama client`.
10. After T09, stop and summarise progress in `docs/MAC_TODO.md` so Justin can do a first Mac build before UI work starts.

## Token-efficient agent work

- Search first, then read only the lines you need. Don't re-read a file you already have unless it changed.
- Run the narrowest test first (`-only-testing:` or `--filter`). Run the full suite once, at the end.
- Wait inside one command (`gh run watch`, `gh pr checks --watch`, an `until` loop) instead of repeated sleep-and-check turns.
- Load a skill only when the task needs it. Never load two skills that cover the same framework.
- Give search and exploration subagents a small, fast model. Keep the main model for decisions and edits.
- Before adding code, check whether this codebase, the Swift standard library, or an Apple framework already solves it. Then write the smallest change that works, without dropping validation, error handling, or accessibility.
- Lead with the result. Skip restating the plan and narrating tool calls, but keep sentences complete.
- After two failed attempts at the same fix, stop and report what you learned instead of looping.
- Delegate self-contained searches and investigations to a subagent so their reads stay out of this conversation. When the user switches to an unrelated task, suggest a new chat with a short handoff note.

## Delegating implementation

The main session orchestrates: it plans, reviews each diff against the spec, makes spec and architecture decisions, runs the final test suite, and commits. Implementation of a single T-numbered task goes to the `swift-implementer` sub-agent (`.claude/agents/swift-implementer.md`). The agent file doesn't pin a model: choose one per session, from any provider, that can write and test Swift 6 code. Mechanical work such as fixture JSON or boilerplate can go to a smaller, cheaper model.

- One task ID per sub-agent. The prompt names the task ID, the spec sections it needs, the files it may create or change, and the acceptance criteria.
- The sub-agent runs `swift build` and `swift test` before reporting back.
- Independent tasks can run in parallel with `isolation: "worktree"`. After T03, tasks T04 to T07 don't depend on each other; T08 waits for all of them.
- If a sub-agent fails the same task twice, the main session takes it over or reports back (see the two-attempts rule above).
- Never delegate spec changes or architecture decisions.
