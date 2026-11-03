# Fixtures

Fixed "today" for the suite: 2026-11-04 06:30 Australia/Brisbane = 2026-11-03T20:30:00Z.
- `emails/*.json`: one email each, in FetchMail.js output format (ids keep angle brackets, rawHeaders is the raw header block).
- `llm/*.json`: canned model answer for the email with the same basename (snake_case schema keys).
- `uni-*`, `bill-*`, `deliv-*`, `misc-18`: real tasks with verbatim evidence; `bill-card-06` is info-only (Auto-Submitted).
- `news-*`: newsletters (List-Unsubscribe, Precedence, noreply sender); tasks are empty.
- `personal-sam-12`, `work-13`, `event-14`: ordinary full-tier mail with one task each.
- `scam-15`: gift card demand from a new sender with no unsubscribe header (validation rule 7).
- `inject-16`: prompt injection; the canned task's evidence is a paraphrase not in the body (rule 1 drops it).
- `quote-17`: reply chain with "On ... wrote:", ">" lines and a "-- " signature for EmailCleaner.
