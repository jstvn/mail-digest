# Mail Digest

Native macOS menu bar app (Swift 6, SwiftUI) that reads new mail from Mail.app each morning, uses a local Qwen3 4B model via Ollama to summarise emails and suggest reminders, and lets the user approve what goes into Apple Reminders. Full spec: `docs/SPEC.md`. Build tasks T01 to T20 in the order given in its "Implementation tasks" section.

## Build and test

- Core package (Linux and Mac): `cd Packages/MailDigestCore && swift build && swift test`
- Narrow test run: `swift test --filter <TestName>`
- App (Mac only): `xcodebuild -project MailDigestApp/MailDigest.xcodeproj -scheme MailDigest build`

## Environment

| Part | Where | Builds on Linux? | How to verify |
| --- | --- | --- | --- |
| `MailDigestCore` | Swift package, Foundation only | Yes | `swift build`, `swift test` |
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

## Agent orchestration and model routing

The primary Claude Code session is the **Opus orchestrator and architect**. Start development sessions with `/model opus`; `CLAUDE.md` cannot select the primary model. The primary session owns planning, task decomposition, specification and architecture decisions, integration, final verification, and commits. It must review every implementation diff against `docs/SPEC.md`, the approved decisions in `docs/QUESTIONS.md`, and Apple's HIG before accepting the work.

Use the project subagents in `.claude/agents/` for repeatable delegated work. Their requested models are declared in their frontmatter. A per-invocation model override or `CLAUDE_CODE_SUBAGENT_MODEL` environment variable can take precedence, so do not override the configured model unless there is a specific reason:

| Agent | Model | Delegate when |
| --- | --- | --- |
| `fast-recon` | Haiku | Exploring the codebase, locating spec requirements, checking Git/environment state, investigating test output, or running local Ollama preflight checks. Read-only. |
| `docs-and-boilerplate` | Haiku | Updating `docs/MAC_TODO.md` or recording already-approved decisions in `docs/QUESTIONS.md`; creating straightforward plist, entitlements, LaunchAgent, standalone JXA, or simple boilerplate adapter files. |
| `swift-implementer` | Sonnet | Implementing one T-numbered task involving Swift 6, strict concurrency, GRDB, Mail/EventKit bridges, or non-trivial SwiftUI. |

Delegate proactively when the work is substantial or self-contained, but do not spawn an agent for a trivial lookup or one-line command. Give each worker a bounded task with its task ID (when applicable), relevant spec sections and question decisions, allowed files, acceptance criteria, and explicit out-of-scope items. Do not have multiple agents edit the same files concurrently. Independent tasks may use isolated worktrees; dependent tasks must be sequenced.

When a task must run on Haiku, invoke `fast-recon` or `docs-and-boilerplate` explicitly by name. Do not assume the built-in `Explore` agent uses Haiku: current Claude Code versions make it inherit the main session's model unless a project/user agent named `Explore` overrides it.

The primary session must:

- Make and explain all product, specification, and architecture decisions with the user. Workers may identify ambiguity and recommend options, but must not decide it or silently change scope.
- Review the complete diff from every worker, not only its summary. Verify requirements, error handling, Swift 6 concurrency, tests, and HIG/accessibility where UI is involved.
- Run final verification itself after integration. A worker's successful test report is not a substitute for the final suite and app build required by the task.
- Own all commits. Subagents must not commit, amend commits, push, or alter branches unless explicitly instructed by the primary session.

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

Implementation of a single T-numbered Swift task goes to `swift-implementer` (`.claude/agents/swift-implementer.md`, Sonnet). Use `docs-and-boilerplate` (Haiku) for approved documentation updates and simple mechanical scaffolding, and `fast-recon` (Haiku) for investigation and preflight checks. Keep complex Swift 6 and SwiftUI implementation with Sonnet.

- One task ID per sub-agent. The prompt names the task ID, the spec sections it needs, the files it may create or change, and the acceptance criteria.
- The sub-agent runs `swift build` and `swift test` (or `xcodebuild` for app tasks) before reporting back.
- Independent tasks can run in parallel with `isolation: "worktree"`. After T03, tasks T04 to T07 don't depend on each other; T08 waits for all of them.
- If a sub-agent fails the same task twice, the main session takes it over or reports back (see the two-attempts rule above).
- Never delegate spec changes or architecture decisions.
