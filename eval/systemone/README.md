# System One routing benchmark

Measures how well the local System One triage models decide which emails may go to the cloud (Gemini) and which must stay local, with the production request, pre-filter, inspection check and threshold logic.

## Dataset

`fixtures.json` holds 150 **fully synthetic** emails. There is no real email content, no real people and no real account data: all hosts are reserved or fictional (`*.example`, plus `substack.com` / `medium.com` for the allowlist), and all numbers and identifiers are made up.

- 12 categories x 12 items (6 `calibration` + 6 `heldout`, a mix of `easy` and `hard`), plus 6 `inspection` items (heldout) that are public newsletters with `inspection` set to `uninspectedParts` or `unknown`. The inspection items only demonstrate the routing reason and are excluded from model metrics.
- `label` (`public` / `private` / `ambiguous`) is written by hand from the content, never derived from a model. `note` explains the edge case each item tests.
- Known deliberate traps: public mail that trips pre-filter keywords (false-private), one allowlisted Substack issue that prints a reader's health details (pre-filter false-public), sensitive content placed after the 1,500-character triage window, and prompt-injection text in both private and public mail.

## Run

From `Packages/MailDigestCore`:

```sh
swift run EvalCLI systemone validate --fixtures ../../eval/systemone/fixtures.json [--verbose]
swift run EvalCLI systemone run --fixtures ../../eval/systemone/fixtures.json \
    --model kev:0.8b-q8_0 --out /path/to/kev-0.8b.jsonl [--base-url http://localhost:11434] [--limit N]
swift run EvalCLI systemone report --fixtures ../../eval/systemone/fixtures.json \
    --results a.jsonl b.jsonl c.jsonl [--json summary.json]
```

`run` aborts if Ollama or the model is missing (it never pulls or falls back to another tag), sends one request at a time with the production request body, and records the raw response, scores, latency and production route per fixture. Models compared: `kev:0.8b-q8_0` (baseline), `kev:4b-q4_K_M`, `tev1:0.8b-q8_0`.

## Historical results versus the current policy

`results/` (and its `report.md`, `summary.json`, `latency.json`) are the historical record of the **original** benchmark: they were produced with the earlier System One request and the earlier routing, where every message that was not decided by a private rule or the inspection check, trusted newsletters included, went to System One on its first 1,500 characters only. They are kept unchanged. `systemone run` now sends the revised request instructions, so re-running it will not reproduce them. Results of the revised, selective policy go in `results-selective/`.

## End-to-end selective-routing evaluation

`fixtures-routing.json` holds 81 more synthetic emails (same schema plus a required `scenario`, split `selective`), written by hand with labels from the content. 5 items per scenario, except `long_over_budget` (1): `trusted_ordinary`, `trusted_medical_research`, `trusted_tax_policy`, `trusted_invoice_software`, `anonymised_case_study`, `voluntary_reader_story`, `identifiable_sensitive_newsletter`, `public_figure_contact`, `trusted_embedded_private`, `private_medical_financial`, `ambiguous_sender`, `pii_in_quoted_reply`, `pii_in_signature`, `long_message` (2,500 to 9,000 characters, sensitive detail beyond 1,500 in 3), `long_over_budget` (needs more than 6 chunks, expected to fail closed), `bulk_sensitive_domain` (bank, government and health hosts from the sensitive-domain table, with List-Unsubscribe) and `uninspected_parts` (inspection not complete, expected local). Like the original set, all data is invented; `bulk_sensitive_domain` uses subdomains of the sensitive suffixes only because that is what the rule matches.

```sh
swift run EvalCLI systemone validate --routing --fixtures ../../eval/systemone/fixtures-routing.json [--verbose]
swift run EvalCLI systemone route --fixtures ../../eval/systemone/fixtures.json ../../eval/systemone/fixtures-routing.json \
    --model kev:0.8b-q8_0 --out ../../eval/systemone/results-selective/kev-0.8b-q8_0.jsonl [--base-url URL] [--limit N]
swift run EvalCLI systemone route-report --fixtures ../../eval/systemone/fixtures.json ../../eval/systemone/fixtures-routing.json \
    --results results-selective/a.jsonl results-selective/b.jsonl --baseline ../../eval/systemone/results [--json out.json]
```

`route` runs the real `DigestRouter.assess` once per fixture with a (never called) cloud extractor present, threshold 0.90 and floor 0.85, and a recording wrapper around the real `OllamaSystemOneClient` (real preflight and plan, every chunk). It aborts if the model is missing (never pulls or falls back), prints the model tag's digest from `/api/tags` and writes it to `F.meta.json` beside the output. Each JSONL line is a `SelectiveRecord`: path, verdict, method, rule id, trigger, risk signal, triage failure, coverage, per-chunk scores and latency, whether the email would go to Gemini, the same email assessed with cloud off, and, for eligible emails, what the real `DigestRouter.execute` does when the Gemini call fails. It holds no raw model response and no message text.

Routes (`path`): `trustedDirect` (allowlisted sender, no risk signal: public with no model call), `trustedSelective` (allowlisted sender but a risk signal fired: System One decides), `ambiguousSystemOne` (unknown sender), `sensitiveSenderSystemOne` (bank, agency or clinic bulk mail without transactional evidence), `deterministicPrivate` (a private rule or sensitive-domain rule), `inspectionLocal` (content not fully inspected) and `other`.

`route-report` prints Markdown per model for the original 144 scored items, the new scenarios and both combined. False-cloud counts `ambiguous` as non-public. False-local excludes ambiguous labels, inspection-only items, over-budget items and evaluation failures, which are each reported on their own so a timeout is never hidden as a false-local. The daily-impact table models System One load per 100 emails on a synthetic mix (calls and seconds, using this run's median single-call latency for both the revised and, with `--baseline`, the old policy). It is not a measured Daily job.

## Metrics

Definitions are in the doc comments of `Packages/MailDigestCore/Sources/MailDigestCore/Eval/RoutingBenchmark.swift` (`BenchmarkMetrics`, `BenchmarkRouting.classifyModelOnly`, `ThresholdSweep`). In short: the production route comes from the real `DigestRouter.assess` (cloud on, threshold 0.90, floor 0.85) replaying recorded scores; cloud-eligible means verdict `public`; false-cloud-eligible and false-local are both reported; the threshold sweep (0.85-0.98 x floor 0.70-0.95) is chosen on the calibration split with zero false-cloud as a gate, then evaluated on the held-out split.
