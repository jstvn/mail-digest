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

## Metrics

Definitions are in the doc comments of `Packages/MailDigestCore/Sources/MailDigestCore/Eval/RoutingBenchmark.swift` (`BenchmarkMetrics`, `BenchmarkRouting.classifyModelOnly`, `ThresholdSweep`). In short: the production route comes from the real `DigestRouter.assess` (cloud on, threshold 0.90, floor 0.85) replaying recorded scores; cloud-eligible means verdict `public`; false-cloud-eligible and false-local are both reported; the threshold sweep (0.85-0.98 x floor 0.70-0.95) is chosen on the calibration split with zero false-cloud as a gate, then evaluated on the held-out split.
