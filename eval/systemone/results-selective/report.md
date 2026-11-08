# Selective-routing evaluation

Real `DigestRouter.assess` (cloud on, threshold 0.90, floor 0.85) over synthetic fixtures. False-cloud counts `ambiguous` as non-public; false-local excludes ambiguous, inspection-only, over-budget and evaluation-failure items (those are reported separately).

## Model kev:4b-q4_K_M

### original 144 scored items (144 items)

- Cloud-eligible: 34/144
- False-cloud: 0
  none
- False-local: 6
  - news-02 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-05 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-09 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - inj-03 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - inj-05 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - inj-09 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
- Over budget (fail closed, own count): 0
  none
- Evaluation failures (triage errors, own count): 0
  none
- Public-email Gemini eligibility: 85.0%
- Private-email local-routing rate: 100.0%
- Messages needing System One: 90.3%
- Trusted newsletters needing System One: 1/5 (20.0%)
- System One calls per message: 0.95
- Calls-per-message distribution (calls: messages): 1 123, 0 14, 2 7
- Per-call latency median / p95: 20.91 / 31.32 s
- Per-message latency median / p95: 20.78 / 43.63 s
- Inspection-exclusion rate: 0.0%
- Paths: ambiguousSystemOne 129, deterministicPrivate 10, trustedDirect 4, trustedSelective 1
- Local reasons: uncertain/below threshold 67, sensitive 33, deterministic private 10
- Cloud-off outcomes: notAssessed/cloudOff 130, private/rule 10, public/trustedSender 4
- Gemini-fallback outcomes (eligible items, Gemini call failing): local/cloudFailed/network 34

### new scenarios (81 items)

- Cloud-eligible: 40/81
- False-cloud: 0
  none
- False-local: 3
  - rt-case-04 [anonymised_case_study, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-amb-02 [ambiguous_sender, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-sig-05 [pii_in_signature, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
- Over budget (fail closed, own count): 1
  - rt-over-01 [long_over_budget, label public] path ambiguousSystemOne, signal ambiguousSender, reason too long
- Evaluation failures (triage errors, own count): 0
  none
- Public-email Gemini eligibility: 93.0%
- Private-email local-routing rate: 100.0%
- Messages needing System One: 45.7%
- Trusted newsletters needing System One: 11/42 (26.2%)
- System One calls per message: 0.48
- Calls-per-message distribution (calls: messages): 0 45, 1 33, 2 3
- Per-call latency median / p95: 17.77 / 26.45 s
- Per-message latency median / p95: 17.46 / 49.67 s
- Inspection-exclusion rate: 6.2%
- Paths: trustedDirect 29, ambiguousSystemOne 23, trustedSelective 11, deterministicPrivate 10, inspectionLocal 5, sensitiveSenderSystemOne 3
- Local reasons: sensitive 15, deterministic private 10, uncertain/below threshold 10, inspection 5, too long 1
- Cloud-off outcomes: notAssessed/cloudOff 42, public/trustedSender 29, private/rule 10
- Gemini-fallback outcomes (eligible items, Gemini call failing): local/cloudFailed/network 40

### combined (231 items)

- Cloud-eligible: 74/231
- False-cloud: 0
  none
- False-local: 9
  - news-02 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-05 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-09 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - inj-03 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - inj-05 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - inj-09 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-case-04 [anonymised_case_study, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-amb-02 [ambiguous_sender, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-sig-05 [pii_in_signature, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
- Over budget (fail closed, own count): 1
  - rt-over-01 [long_over_budget, label public] path ambiguousSystemOne, signal ambiguousSender, reason too long
- Evaluation failures (triage errors, own count): 0
  none
- Public-email Gemini eligibility: 89.2%
- Private-email local-routing rate: 100.0%
- Messages needing System One: 72.3%
- Trusted newsletters needing System One: 12/47 (25.5%)
- System One calls per message: 0.76
- Calls-per-message distribution (calls: messages): 1 156, 0 65, 2 10
- Per-call latency median / p95: 20.35 / 30.66 s
- Per-message latency median / p95: 20.19 / 43.89 s
- Inspection-exclusion rate: 4.8%
- Paths: ambiguousSystemOne 152, trustedDirect 33, deterministicPrivate 20, trustedSelective 12, inspectionLocal 11, sensitiveSenderSystemOne 3
- Local reasons: uncertain/below threshold 77, sensitive 48, deterministic private 20, inspection 11, too long 1
- Cloud-off outcomes: notAssessed/cloudOff 178, public/trustedSender 33, private/rule 20
- Gemini-fallback outcomes (eligible items, Gemini call failing): local/cloudFailed/network 74

### Per scenario (combined)

| Scenario | Eligible/total | Routes | False-cloud | False-local |
|---|---|---|---|---|
| ambiguous_sender | 1/5 | ambiguousSystemOne 5 | 0 | 1 |
| anonymised_case_study | 4/5 | trustedDirect 3, ambiguousSystemOne 2 | 0 | 1 |
| bulk_sensitive_domain | 3/5 | sensitiveSenderSystemOne 3, deterministicPrivate 2 | 0 | 0 |
| identifiable_sensitive_newsletter | 0/5 | trustedSelective 5 | 0 | 0 |
| long_message | 2/5 | ambiguousSystemOne 3, trustedDirect 1, trustedSelective 1 | 0 | 0 |
| long_over_budget | 0/1 | ambiguousSystemOne 1 | 0 | 0 |
| orig:ambiguous | 0/12 | ambiguousSystemOne 12 | 0 | 0 |
| orig:confidential_work | 0/12 | ambiguousSystemOne 12 | 0 | 0 |
| orig:financial_transactional | 0/12 | ambiguousSystemOne 7, deterministicPrivate 5 | 0 | 0 |
| orig:inspection | 0/6 | inspectionLocal 6 | 0 | 0 |
| orig:medical | 0/12 | ambiguousSystemOne 9, deterministicPrivate 3 | 0 | 0 |
| orig:personal_identifiers | 0/12 | ambiguousSystemOne 10, deterministicPrivate 2 | 0 | 0 |
| orig:personal_scheduling | 0/12 | ambiguousSystemOne 12 | 0 | 0 |
| orig:private_personal | 0/12 | ambiguousSystemOne 12 | 0 | 0 |
| orig:prompt_injection | 1/12 | ambiguousSystemOne 12 | 0 | 3 |
| orig:public_marketing | 12/12 | ambiguousSystemOne 12 | 0 | 0 |
| orig:public_newsletter | 11/12 | ambiguousSystemOne 8, trustedDirect 4 | 0 | 1 |
| orig:public_notification | 10/12 | ambiguousSystemOne 12 | 0 | 2 |
| orig:public_with_sensitive | 0/12 | ambiguousSystemOne 11, trustedSelective 1 | 0 | 0 |
| pii_in_quoted_reply | 0/5 | ambiguousSystemOne 3, deterministicPrivate 1, trustedSelective 1 | 0 | 0 |
| pii_in_signature | 0/5 | ambiguousSystemOne 4, deterministicPrivate 1 | 0 | 1 |
| private_medical_financial | 0/5 | deterministicPrivate 4, ambiguousSystemOne 1 | 0 | 0 |
| public_figure_contact | 5/5 | ambiguousSystemOne 2, trustedDirect 2, trustedSelective 1 | 0 | 0 |
| trusted_embedded_private | 0/5 | trustedSelective 3, deterministicPrivate 2 | 0 | 0 |
| trusted_invoice_software | 5/5 | trustedDirect 5 | 0 | 0 |
| trusted_medical_research | 5/5 | trustedDirect 5 | 0 | 0 |
| trusted_ordinary | 5/5 | trustedDirect 5 | 0 | 0 |
| trusted_tax_policy | 5/5 | trustedDirect 5 | 0 | 0 |
| uninspected_parts | 0/5 | inspectionLocal 5 | 0 | 0 |
| voluntary_reader_story | 5/5 | trustedDirect 3, ambiguousSystemOne 2 | 0 | 0 |

### Daily impact (a model of triage time on a synthetic mix, not a measured Daily job)

Median single-call latency in this run: 20.35 s, used for both policies.

| Policy | System One calls per 100 emails | Modelled seconds per 100 |
|---|---|---|
| Revised, original 144 items | 95.1 | 1936.40 |
| Old (always System One), original 144 items | 88.2 | 1795.05 |
| Revised, all fixtures (calls) | 76.2 | 1550.73 |
| Revised, all fixtures (measured seconds) | 76.2 | 1606.39 |

## Model kev:0.8b-q8_0

### original 144 scored items (144 items)

- Cloud-eligible: 4/144
- False-cloud: 0
  none
- False-local: 36
  - news-02 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - news-04 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - news-05 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - news-06 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - news-07 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - news-09 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - news-10 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - news-11 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-01 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-02 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-03 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-04 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-05 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-06 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-07 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-08 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-09 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-10 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-11 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-12 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-01 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-02 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-03 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-04 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-05 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-06 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-07 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-08 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-09 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-10 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-11 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-12 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - inj-03 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason sensitive
  - inj-05 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - inj-09 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - inj-11 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
- Over budget (fail closed, own count): 0
  none
- Evaluation failures (triage errors, own count): 0
  none
- Public-email Gemini eligibility: 10.0%
- Private-email local-routing rate: 100.0%
- Messages needing System One: 90.3%
- Trusted newsletters needing System One: 1/5 (20.0%)
- System One calls per message: 0.90
- Calls-per-message distribution (calls: messages): 1 130, 0 14
- Per-call latency median / p95: 5.54 / 8.82 s
- Per-message latency median / p95: 5.54 / 8.82 s
- Inspection-exclusion rate: 0.0%
- Paths: ambiguousSystemOne 129, deterministicPrivate 10, trustedDirect 4, trustedSelective 1
- Local reasons: uncertain/below threshold 124, deterministic private 10, sensitive 6
- Cloud-off outcomes: notAssessed/cloudOff 130, private/rule 10, public/trustedSender 4
- Gemini-fallback outcomes (eligible items, Gemini call failing): local/cloudFailed/network 4

### new scenarios (81 items)

- Cloud-eligible: 29/81
- False-cloud: 0
  none
- False-local: 14
  - rt-case-03 [anonymised_case_study, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-case-04 [anonymised_case_study, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-reader-03 [voluntary_reader_story, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-reader-04 [voluntary_reader_story, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-pf-02 [public_figure_contact, label public] path ambiguousSystemOne, signal risk.identifiable.sensitive, reason uncertain/below threshold
  - rt-pf-04 [public_figure_contact, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-pf-05 [public_figure_contact, label public] path trustedSelective, signal risk.identifiable.sensitive, reason uncertain/below threshold
  - rt-amb-01 [ambiguous_sender, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-amb-02 [ambiguous_sender, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-sig-05 [pii_in_signature, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-bulk-01 [bulk_sensitive_domain, label public] path sensitiveSenderSystemOne, signal sensitiveSender, reason uncertain/below threshold
  - rt-bulk-02 [bulk_sensitive_domain, label public] path sensitiveSenderSystemOne, signal sensitiveSender, reason uncertain/below threshold
  - rt-bulk-03 [bulk_sensitive_domain, label public] path sensitiveSenderSystemOne, signal sensitiveSender, reason uncertain/below threshold
  - rt-long-04 [long_message, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
- Over budget (fail closed, own count): 1
  - rt-over-01 [long_over_budget, label public] path ambiguousSystemOne, signal ambiguousSender, reason too long
- Evaluation failures (triage errors, own count): 0
  none
- Public-email Gemini eligibility: 67.4%
- Private-email local-routing rate: 100.0%
- Messages needing System One: 45.7%
- Trusted newsletters needing System One: 11/42 (26.2%)
- System One calls per message: 0.44
- Calls-per-message distribution (calls: messages): 0 45, 1 36
- Per-call latency median / p95: 6.09 / 13.27 s
- Per-message latency median / p95: 6.09 / 13.27 s
- Inspection-exclusion rate: 6.2%
- Paths: trustedDirect 29, ambiguousSystemOne 23, trustedSelective 11, deterministicPrivate 10, inspectionLocal 5, sensitiveSenderSystemOne 3
- Local reasons: uncertain/below threshold 30, deterministic private 10, sensitive 6, inspection 5, too long 1
- Cloud-off outcomes: notAssessed/cloudOff 42, public/trustedSender 29, private/rule 10
- Gemini-fallback outcomes (eligible items, Gemini call failing): local/cloudFailed/network 29

### combined (231 items)

- Cloud-eligible: 33/231
- False-cloud: 0
  none
- False-local: 50
  - news-02 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - news-04 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - news-05 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - news-06 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - news-07 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - news-09 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - news-10 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - news-11 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-01 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-02 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-03 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-04 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-05 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-06 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-07 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-08 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-09 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-10 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-11 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-12 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-01 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-02 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-03 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-04 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-05 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-06 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-07 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-08 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-09 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-10 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-11 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-12 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - inj-03 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason sensitive
  - inj-05 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - inj-09 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - inj-11 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-case-03 [anonymised_case_study, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-case-04 [anonymised_case_study, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-reader-03 [voluntary_reader_story, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-reader-04 [voluntary_reader_story, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-pf-02 [public_figure_contact, label public] path ambiguousSystemOne, signal risk.identifiable.sensitive, reason uncertain/below threshold
  - rt-pf-04 [public_figure_contact, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-pf-05 [public_figure_contact, label public] path trustedSelective, signal risk.identifiable.sensitive, reason uncertain/below threshold
  - rt-amb-01 [ambiguous_sender, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-amb-02 [ambiguous_sender, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-sig-05 [pii_in_signature, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-bulk-01 [bulk_sensitive_domain, label public] path sensitiveSenderSystemOne, signal sensitiveSender, reason uncertain/below threshold
  - rt-bulk-02 [bulk_sensitive_domain, label public] path sensitiveSenderSystemOne, signal sensitiveSender, reason uncertain/below threshold
  - rt-bulk-03 [bulk_sensitive_domain, label public] path sensitiveSenderSystemOne, signal sensitiveSender, reason uncertain/below threshold
  - rt-long-04 [long_message, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
- Over budget (fail closed, own count): 1
  - rt-over-01 [long_over_budget, label public] path ambiguousSystemOne, signal ambiguousSender, reason too long
- Evaluation failures (triage errors, own count): 0
  none
- Public-email Gemini eligibility: 39.8%
- Private-email local-routing rate: 100.0%
- Messages needing System One: 72.3%
- Trusted newsletters needing System One: 12/47 (25.5%)
- System One calls per message: 0.72
- Calls-per-message distribution (calls: messages): 1 166, 0 65
- Per-call latency median / p95: 5.67 / 11.51 s
- Per-message latency median / p95: 5.67 / 11.51 s
- Inspection-exclusion rate: 4.8%
- Paths: ambiguousSystemOne 152, trustedDirect 33, deterministicPrivate 20, trustedSelective 12, inspectionLocal 11, sensitiveSenderSystemOne 3
- Local reasons: uncertain/below threshold 154, deterministic private 20, sensitive 12, inspection 11, too long 1
- Cloud-off outcomes: notAssessed/cloudOff 178, public/trustedSender 33, private/rule 20
- Gemini-fallback outcomes (eligible items, Gemini call failing): local/cloudFailed/network 33

### Per scenario (combined)

| Scenario | Eligible/total | Routes | False-cloud | False-local |
|---|---|---|---|---|
| ambiguous_sender | 0/5 | ambiguousSystemOne 5 | 0 | 2 |
| anonymised_case_study | 3/5 | trustedDirect 3, ambiguousSystemOne 2 | 0 | 2 |
| bulk_sensitive_domain | 0/5 | sensitiveSenderSystemOne 3, deterministicPrivate 2 | 0 | 3 |
| identifiable_sensitive_newsletter | 0/5 | trustedSelective 5 | 0 | 0 |
| long_message | 1/5 | ambiguousSystemOne 3, trustedDirect 1, trustedSelective 1 | 0 | 1 |
| long_over_budget | 0/1 | ambiguousSystemOne 1 | 0 | 0 |
| orig:ambiguous | 0/12 | ambiguousSystemOne 12 | 0 | 0 |
| orig:confidential_work | 0/12 | ambiguousSystemOne 12 | 0 | 0 |
| orig:financial_transactional | 0/12 | ambiguousSystemOne 7, deterministicPrivate 5 | 0 | 0 |
| orig:inspection | 0/6 | inspectionLocal 6 | 0 | 0 |
| orig:medical | 0/12 | ambiguousSystemOne 9, deterministicPrivate 3 | 0 | 0 |
| orig:personal_identifiers | 0/12 | ambiguousSystemOne 10, deterministicPrivate 2 | 0 | 0 |
| orig:personal_scheduling | 0/12 | ambiguousSystemOne 12 | 0 | 0 |
| orig:private_personal | 0/12 | ambiguousSystemOne 12 | 0 | 0 |
| orig:prompt_injection | 0/12 | ambiguousSystemOne 12 | 0 | 4 |
| orig:public_marketing | 0/12 | ambiguousSystemOne 12 | 0 | 12 |
| orig:public_newsletter | 4/12 | ambiguousSystemOne 8, trustedDirect 4 | 0 | 8 |
| orig:public_notification | 0/12 | ambiguousSystemOne 12 | 0 | 12 |
| orig:public_with_sensitive | 0/12 | ambiguousSystemOne 11, trustedSelective 1 | 0 | 0 |
| pii_in_quoted_reply | 0/5 | ambiguousSystemOne 3, deterministicPrivate 1, trustedSelective 1 | 0 | 0 |
| pii_in_signature | 0/5 | ambiguousSystemOne 4, deterministicPrivate 1 | 0 | 1 |
| private_medical_financial | 0/5 | deterministicPrivate 4, ambiguousSystemOne 1 | 0 | 0 |
| public_figure_contact | 2/5 | ambiguousSystemOne 2, trustedDirect 2, trustedSelective 1 | 0 | 3 |
| trusted_embedded_private | 0/5 | trustedSelective 3, deterministicPrivate 2 | 0 | 0 |
| trusted_invoice_software | 5/5 | trustedDirect 5 | 0 | 0 |
| trusted_medical_research | 5/5 | trustedDirect 5 | 0 | 0 |
| trusted_ordinary | 5/5 | trustedDirect 5 | 0 | 0 |
| trusted_tax_policy | 5/5 | trustedDirect 5 | 0 | 0 |
| uninspected_parts | 0/5 | inspectionLocal 5 | 0 | 0 |
| voluntary_reader_story | 3/5 | trustedDirect 3, ambiguousSystemOne 2 | 0 | 2 |

### Daily impact (a model of triage time on a synthetic mix, not a measured Daily job)

Median single-call latency in this run: 5.67 s, used for both policies.

| Policy | System One calls per 100 emails | Modelled seconds per 100 |
|---|---|---|
| Revised, original 144 items | 90.3 | 512.14 |
| Old (always System One), original 144 items | 88.2 | 500.33 |
| Revised, all fixtures (calls) | 71.9 | 407.67 |
| Revised, all fixtures (measured seconds) | 71.9 | 450.91 |

## Model tev1:0.8b-q8_0

### original 144 scored items (144 items)

- Cloud-eligible: 24/144
- False-cloud: 0
  none
- False-local: 16
  - news-02 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - news-07 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - news-10 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-04 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-07 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-08 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-10 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-01 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-04 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-05 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-06 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-07 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-09 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-11 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - inj-03 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - inj-05 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
- Over budget (fail closed, own count): 0
  none
- Evaluation failures (triage errors, own count): 0
  none
- Public-email Gemini eligibility: 60.0%
- Private-email local-routing rate: 100.0%
- Messages needing System One: 90.3%
- Trusted newsletters needing System One: 1/5 (20.0%)
- System One calls per message: 0.94
- Calls-per-message distribution (calls: messages): 1 124, 0 14, 2 6
- Per-call latency median / p95: 5.22 / 7.43 s
- Per-message latency median / p95: 5.20 / 11.11 s
- Inspection-exclusion rate: 0.0%
- Paths: ambiguousSystemOne 129, deterministicPrivate 10, trustedDirect 4, trustedSelective 1
- Local reasons: uncertain/below threshold 110, deterministic private 10
- Cloud-off outcomes: notAssessed/cloudOff 130, private/rule 10, public/trustedSender 4
- Gemini-fallback outcomes (eligible items, Gemini call failing): local/cloudFailed/network 24

### new scenarios (81 items)

- Cloud-eligible: 38/81
- False-cloud: 0
  none
- False-local: 5
  - rt-case-03 [anonymised_case_study, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-case-04 [anonymised_case_study, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-pf-04 [public_figure_contact, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-pf-05 [public_figure_contact, label public] path trustedSelective, signal risk.identifiable.sensitive, reason uncertain/below threshold
  - rt-amb-02 [ambiguous_sender, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
- Over budget (fail closed, own count): 1
  - rt-over-01 [long_over_budget, label public] path ambiguousSystemOne, signal ambiguousSender, reason too long
- Evaluation failures (triage errors, own count): 0
  none
- Public-email Gemini eligibility: 88.4%
- Private-email local-routing rate: 100.0%
- Messages needing System One: 45.7%
- Trusted newsletters needing System One: 11/42 (26.2%)
- System One calls per message: 0.46
- Calls-per-message distribution (calls: messages): 0 45, 1 35, 2 1
- Per-call latency median / p95: 4.89 / 6.03 s
- Per-message latency median / p95: 4.88 / 6.25 s
- Inspection-exclusion rate: 6.2%
- Paths: trustedDirect 29, ambiguousSystemOne 23, trustedSelective 11, deterministicPrivate 10, inspectionLocal 5, sensitiveSenderSystemOne 3
- Local reasons: uncertain/below threshold 27, deterministic private 10, inspection 5, too long 1
- Cloud-off outcomes: notAssessed/cloudOff 42, public/trustedSender 29, private/rule 10
- Gemini-fallback outcomes (eligible items, Gemini call failing): local/cloudFailed/network 38

### combined (231 items)

- Cloud-eligible: 62/231
- False-cloud: 0
  none
- False-local: 21
  - news-02 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - news-07 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - news-10 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-04 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-07 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-08 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - mkt-10 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-01 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-04 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-05 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-06 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-07 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-09 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - notif-11 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - inj-03 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - inj-05 [original, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-case-03 [anonymised_case_study, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-case-04 [anonymised_case_study, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-pf-04 [public_figure_contact, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
  - rt-pf-05 [public_figure_contact, label public] path trustedSelective, signal risk.identifiable.sensitive, reason uncertain/below threshold
  - rt-amb-02 [ambiguous_sender, label public] path ambiguousSystemOne, signal ambiguousSender, reason uncertain/below threshold
- Over budget (fail closed, own count): 1
  - rt-over-01 [long_over_budget, label public] path ambiguousSystemOne, signal ambiguousSender, reason too long
- Evaluation failures (triage errors, own count): 0
  none
- Public-email Gemini eligibility: 74.7%
- Private-email local-routing rate: 100.0%
- Messages needing System One: 72.3%
- Trusted newsletters needing System One: 12/47 (25.5%)
- System One calls per message: 0.75
- Calls-per-message distribution (calls: messages): 1 159, 0 65, 2 7
- Per-call latency median / p95: 5.09 / 7.24 s
- Per-message latency median / p95: 5.07 / 11.07 s
- Inspection-exclusion rate: 4.8%
- Paths: ambiguousSystemOne 152, trustedDirect 33, deterministicPrivate 20, trustedSelective 12, inspectionLocal 11, sensitiveSenderSystemOne 3
- Local reasons: uncertain/below threshold 137, deterministic private 20, inspection 11, too long 1
- Cloud-off outcomes: notAssessed/cloudOff 178, public/trustedSender 33, private/rule 20
- Gemini-fallback outcomes (eligible items, Gemini call failing): local/cloudFailed/network 62

### Per scenario (combined)

| Scenario | Eligible/total | Routes | False-cloud | False-local |
|---|---|---|---|---|
| ambiguous_sender | 1/5 | ambiguousSystemOne 5 | 0 | 1 |
| anonymised_case_study | 3/5 | trustedDirect 3, ambiguousSystemOne 2 | 0 | 2 |
| bulk_sensitive_domain | 3/5 | sensitiveSenderSystemOne 3, deterministicPrivate 2 | 0 | 0 |
| identifiable_sensitive_newsletter | 0/5 | trustedSelective 5 | 0 | 0 |
| long_message | 2/5 | ambiguousSystemOne 3, trustedDirect 1, trustedSelective 1 | 0 | 0 |
| long_over_budget | 0/1 | ambiguousSystemOne 1 | 0 | 0 |
| orig:ambiguous | 0/12 | ambiguousSystemOne 12 | 0 | 0 |
| orig:confidential_work | 0/12 | ambiguousSystemOne 12 | 0 | 0 |
| orig:financial_transactional | 0/12 | ambiguousSystemOne 7, deterministicPrivate 5 | 0 | 0 |
| orig:inspection | 0/6 | inspectionLocal 6 | 0 | 0 |
| orig:medical | 0/12 | ambiguousSystemOne 9, deterministicPrivate 3 | 0 | 0 |
| orig:personal_identifiers | 0/12 | ambiguousSystemOne 10, deterministicPrivate 2 | 0 | 0 |
| orig:personal_scheduling | 0/12 | ambiguousSystemOne 12 | 0 | 0 |
| orig:private_personal | 0/12 | ambiguousSystemOne 12 | 0 | 0 |
| orig:prompt_injection | 2/12 | ambiguousSystemOne 12 | 0 | 2 |
| orig:public_marketing | 8/12 | ambiguousSystemOne 12 | 0 | 4 |
| orig:public_newsletter | 9/12 | ambiguousSystemOne 8, trustedDirect 4 | 0 | 3 |
| orig:public_notification | 5/12 | ambiguousSystemOne 12 | 0 | 7 |
| orig:public_with_sensitive | 0/12 | ambiguousSystemOne 11, trustedSelective 1 | 0 | 0 |
| pii_in_quoted_reply | 0/5 | ambiguousSystemOne 3, deterministicPrivate 1, trustedSelective 1 | 0 | 0 |
| pii_in_signature | 1/5 | ambiguousSystemOne 4, deterministicPrivate 1 | 0 | 0 |
| private_medical_financial | 0/5 | deterministicPrivate 4, ambiguousSystemOne 1 | 0 | 0 |
| public_figure_contact | 3/5 | ambiguousSystemOne 2, trustedDirect 2, trustedSelective 1 | 0 | 2 |
| trusted_embedded_private | 0/5 | trustedSelective 3, deterministicPrivate 2 | 0 | 0 |
| trusted_invoice_software | 5/5 | trustedDirect 5 | 0 | 0 |
| trusted_medical_research | 5/5 | trustedDirect 5 | 0 | 0 |
| trusted_ordinary | 5/5 | trustedDirect 5 | 0 | 0 |
| trusted_tax_policy | 5/5 | trustedDirect 5 | 0 | 0 |
| uninspected_parts | 0/5 | inspectionLocal 5 | 0 | 0 |
| voluntary_reader_story | 5/5 | trustedDirect 3, ambiguousSystemOne 2 | 0 | 0 |

### Daily impact (a model of triage time on a synthetic mix, not a measured Daily job)

Median single-call latency in this run: 5.09 s, used for both policies.

| Policy | System One calls per 100 emails | Modelled seconds per 100 |
|---|---|---|
| Revised, original 144 items | 94.4 | 480.59 |
| Old (always System One), original 144 items | 88.2 | 448.79 |
| Revised, all fixtures (calls) | 74.9 | 381.10 |
| Revised, all fixtures (measured seconds) | 74.9 | 408.93 |


