# Mail Digest

Native macOS menu bar app (Swift 6, SwiftUI) that reads new mail from Mail.app each morning, uses a local Qwen3 4B model via Ollama to summarise emails and suggest reminders, and lets the user approve what goes into Apple Reminders. Full spec: `docs/SPEC.md`. Build tasks T01 to T20 in the order given in its "Implementation tasks" section.

## Build and test

- Core package (Linux and Mac): `cd Packages/MailDigestCore && swift build && swift test`
- Narrow test run: `swift test --filter <TestName>`
- App (Mac only): `xcodebuild -project MailDigestApp/MailDigest.xcodeproj -scheme MailDigest build`

## Environment

| Part | Where | Builds on Linux? | How to verify |
| --- | --- | --- | --- |
| `MailDigestCore` | Swift package, Foundation plus SwiftSoup (Q99) | Yes | `swift build`, `swift test` |
| `MailDigestApp` | Xcode macOS app (SwiftUI, EventKit, JXA scripts) | No (Mac only) | `xcodebuild ... build` on Mac |

If running in a Linux container without `swift`, install a Swift 6 toolchain first (for example via `swiftly`). On macOS, Xcode 26.6+ and native frameworks are available.

## Project rules

1. Put every piece of logic that doesn't need an Apple framework into `MailDigestCore`, behind a protocol. The app target holds only thin adapters and UI.
2. Never import AppKit, SwiftUI, EventKit, SwiftData or Combine in `MailDigestCore`.
3. For networking, add `#if canImport(FoundationNetworking)` / `import FoundationNetworking` so `URLSession` compiles on Linux.
4. Swift 6 with strict concurrency; models are `Sendable` structs.
5. Tests never need a network, Ollama or Mail. Use the fakes and JSON fixtures described in the spec. Inject `Clock` instead of reading the time.
6. **[Mac-only]** tasks: write the code against the APIs named in the spec, verify with `xcodebuild` when on macOS, and list anything requiring manual UI/system check in `docs/MAC_TODO.md`.
7. **UI & Design:** All macOS UI, menu bar extras, windows, typography, spacing, SF Symbols, keyboard shortcuts, and accessibility must strictly follow Apple's [Human Interface Guidelines (HIG)](https://developer.apple.com/design/human-interface-guidelines). Use idiomatic macOS SwiftUI controls and standard system materials/margins.
8. Don't add features that aren't in the spec. Put ambiguities in `docs/QUESTIONS.md` instead of guessing.
9. Add short, clear English comments where they help: a `///` doc comment on public types and functions, and a brief comment above non-obvious logic explaining why, not what. Don't comment the obvious.
10. Use short **Conventional Commits** messages (under 50 chars, lowercase, imperative), scoping by task ID or module—for example `feat(T10): add macOS app target` or `fix(core): shadow ObjectiveC.Category`.
11. **Default delivery includes a commit.** For every requested development task (implementation, bug fix, refactor, tests, or project documentation/configuration), complete verification and create a commit without asking whether to commit. The commit includes all non-ignored project changes present in the working tree at delivery, including pre-existing changes made by the user or other tools—not only files edited by Claude. Inspect the full status and diff first; do not discard or silently omit existing work. Never commit secrets, credentials, private email/message data, local databases, build products, or other sensitive/generated local state. Do not push. See the commit workflow below.

## Agent orchestration and model routing

The primary Claude Code session is the **Opus orchestrator and architect**. Start development sessions with `/model opus`; `CLAUDE.md` cannot select the primary model. The primary session owns planning, task decomposition, specification and architecture decisions, integration, final verification, and commits. It must review every implementation diff against `docs/SPEC.md`, the approved decisions in `docs/QUESTIONS.md`, and Apple's HIG before accepting the work.

Use the project subagents in `.claude/agents/` for repeatable delegated work. Their requested models are declared in their frontmatter. A per-invocation model override or `CLAUDE_CODE_SUBAGENT_MODEL` environment variable can take precedence, so do not override the configured model unless there is a specific reason:

| Agent | Model | Delegate when |
| --- | --- | --- |
| `fast-recon` | Haiku | Initial reconnaissance for non-trivial work and first-pass diagnosis of bugs, regressions, failing tests/builds, runtime hangs, logs, stack traces, and performance issues; also locating spec requirements, checking Git/environment state, and local Ollama preflight checks. Read-only. |
| `docs-and-boilerplate` | Haiku | Updating `docs/MAC_TODO.md` or recording already-approved decisions in `docs/QUESTIONS.md`; creating straightforward plist, entitlements, LaunchAgent, standalone JXA, or simple boilerplate adapter files. |
| `swift-implementer` | Sonnet | Implementing any non-trivial code change in this project—not only T-numbered tasks. This includes features, bug fixes, regressions found during debugging, refactors, performance work, tests, Swift 6/concurrency, GRDB, Mail/EventKit bridges, JXA and non-trivial SwiftUI. Assign a bounded task or workstream, whether or not it has a T-number. |

Delegate proactively rather than doing substantial work in the primary session. Do not spawn an agent for a trivial lookup or one-line edit. Give each worker a bounded task or named workstream (a T-number is optional), relevant spec sections and question decisions, allowed files, acceptance criteria, and explicit out-of-scope items. Do not have multiple agents edit the same files concurrently. Independent tasks may use isolated worktrees; dependent tasks must be sequenced.

When a task must run on Haiku, invoke `fast-recon` or `docs-and-boilerplate` explicitly by name. Do not assume the built-in `Explore` agent uses Haiku: current Claude Code versions make it inherit the main session's model unless a project/user agent named `Explore` overrides it.

The primary session must:

- Make and explain all product, specification, and architecture decisions with the user. Workers may identify ambiguity and recommend options, but must not decide it or silently change scope.
- Review the complete diff from every worker, not only its summary. Verify requirements, error handling, Swift 6 concurrency, tests, and HIG/accessibility where UI is involved.
- Run final verification itself after integration. A worker's successful test report is not a substitute for the final suite and app build required by the task.
- Own all commits. Subagents must not commit, amend commits, push, or alter branches unless explicitly instructed by the primary session.

### Debugging and regression workflow

For a non-trivial bug report, regression, test/build failure, runtime hang, crash, or performance issue, **invoke `fast-recon` by name as the first investigation step**. Do not keep the initial diagnosis entirely in the Opus context or substitute the built-in `Explore` agent. Give `fast-recon` the observed symptoms, reproduction steps, relevant logs/test output and a read-only scope. Ask it to trace the execution path, run safe focused diagnostics/reproduction commands, identify likely root cause(s), distinguish verified facts from hypotheses, and report exact files/symbols plus the narrowest useful regression test.

The primary session evaluates the evidence and owns the diagnosis and any product/architecture decision. If a code change is needed, delegate the bounded fix and regression tests to `swift-implementer` (Sonnet), even when the fix is not associated with a T-number. The primary session reviews the full diff and independently runs final verification. Keep trivial, immediately evident fixes in the primary session; do not force a delegation for a one-line typo. If `fast-recon` cannot reproduce an issue because it requires interactive UI or external device/system state, have it complete the code-path and diagnostic review, then state precisely what must be reproduced manually rather than claiming a root cause.

For failing tests or builds, first delegate log/output triage to `fast-recon` (Haiku); once the failing area and likely cause are isolated, delegate the implementation to `swift-implementer` as needed. For a production bug with independent layers, parallelise only the read-only investigations; keep edits to overlapping files sequential.

### Decision and specification precedence

- `docs/SPEC.md` is the product and implementation specification.
- `docs/QUESTIONS.md` records decisions explicitly approved by the user. Treat each `Decision` entry as settled and binding; do not ask the user to walk through or re-approve it. Reopen a decision only if implementation reveals a concrete contradiction or an unanticipated technical constraint, and bring that conflict to the primary session before changing behaviour.
- When a question has both an interim choice and a `Decision` entry, follow the `Decision` entry.
- `docs/MAC_TODO.md` tracks Mac-only checks and verification status. Update it when a Mac-only task changes what remains to be checked.

## Token-efficient agent work

- Search first, then read only the lines you need. Don't re-read a file you already have unless it changed.
- Run the narrowest test first (`-only-testing:` or `--filter`). Run the full suite once, at the end.
- Wait inside one command (`gh run watch`, `gh pr checks --watch`, an `until` loop) instead of repeated sleep-and-check turns.
- Inspect the Simulator through its accessibility tree (for example, the RocketSim CLI). Take a screenshot only to verify visuals.
- Load a skill only when the task needs it. Never load two skills that cover the same framework.
- Give search and exploration subagents a small, fast model. Keep the main model for decisions and edits.
- Before adding code, check whether this codebase, the Swift standard library, or an Apple framework already solves it. Then write the smallest change that works, without dropping validation, error handling, or accessibility.
- Lead with the result. Skip restating the plan and narrating tool calls, but keep sentences complete.
- After two failed attempts at the same fix, stop and report what you learned instead of looping.
- Delegate self-contained searches and investigations to a subagent so their reads stay out of this conversation. When the user switches to an unrelated task, suggest a new chat with a short handoff note.

## Delegating implementation

Any non-trivial implementation work goes to `swift-implementer` (`.claude/agents/swift-implementer.md`, Sonnet), whether it is a T-numbered task, a bug fix, a feature request, a refactor, a performance improvement, or regression coverage. A task ID is not required: define a clear, bounded workstream instead. Use `docs-and-boilerplate` (Haiku) for approved documentation updates and simple mechanical scaffolding, and `fast-recon` (Haiku) for initial investigation, debugging triage and preflight checks. Keep complex Swift 6, persistence and SwiftUI implementation with Sonnet.

- One bounded task/workstream per implementation sub-agent. Name the T-number when one exists; otherwise use a concise workstream title. The prompt identifies the relevant spec sections and approved decisions, files it may create or change, acceptance criteria, tests, and explicit out-of-scope items.
- The sub-agent runs `swift build` and `swift test` (or `xcodebuild` for app tasks) before reporting back.
- Independent tasks can run in parallel with `isolation: "worktree"`. After T03, tasks T04 to T07 don't depend on each other; T08 waits for all of them.
- If a sub-agent fails the same task twice, the main session takes it over or reports back (see the two-attempts rule above).
- Never delegate spec changes or architecture decisions.

### Default commit workflow

The primary session creates the delivery commit after implementation, review and verification. **Do not ask the user whether to commit** for a completed development task. Subagents never create commits.

1. At task start, inspect `git status --short --branch` and the current diff. Record which changes already existed before work; preserve them and do not treat them as disposable merely because Claude did not create them.
2. Before committing, inspect the complete tracked and untracked working-tree changes, including pre-existing user/tool edits and automatic project-file changes from Xcode. Check for secrets, credentials, private email/message data, local databases, derived data, build products, and unrelated machine-local state; never stage those sensitive or generated files.
3. By default, stage all remaining non-ignored project changes (`git add -A`) and commit them together in a short Conventional Commit message under 50 characters. This intentionally includes pre-existing, user-authored project changes in the delivery commit. Do not selectively omit them just because they were not authored in the current task.
4. Do not discard, reset, stash, or revert pre-existing changes. Do not amend an earlier commit. Do not push.
5. After committing, verify the commit contents and `git status --short --branch`; report the hash, verification results, and any excluded sensitive/generated files. If a sensitive or otherwise unsafe file is present and cannot be safely excluded without ambiguity, stop before committing and explain the blocker.
