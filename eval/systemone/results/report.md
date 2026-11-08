# System One routing benchmark

Fixtures: 150. Production thresholds: t=0.90 floor=0.85. Inspection-category items are excluded from model metrics.

## Pre-filter only (all fixtures)

| Label | private | public | needsTriage |
|---|---|---|---|
| public | 6 | 4 | 36 |
| private | 6 | 1 | 85 |
| ambiguous | 0 | 0 | 12 |

False-private hits (label public, pre-filter private): 6
- news-04 (public_newsletter) rule kw.financial
- news-06 (public_newsletter) rule kw.financial
- news-09 (public_newsletter) rule kw.tax
- news-11 (public_newsletter) rule kw.medical
- mkt-04 (public_marketing) rule kw.medical
- inj-03 (prompt_injection) rule kw.medical

False-public hits (label not public, pre-filter public): 1
- pws-08 (public_with_sensitive) label private rule allowlist.substack

## Comparison (production thresholds, all splits)

| Metric | kev:0.8b-q8_0 | kev:4b-q4_K_M | tev1:0.8b-q8_0 |
|---|---|---|---|
| Evaluated items | 144 | 144 | 144 |
| Strict accuracy (model-only) | 54.2% | 86.1% | 68.1% |
| Routing accuracy | 79.9% | 91.7% | 89.6% |
| False-cloud-eligible (route) | 1 | 1 | 2 |
| False-cloud Wilson 95% upper | 5.2% | 5.2% | 6.7% |
| False-local (route) | 28 | 11 | 13 |
| Public eligibility rate | 30.0% | 72.5% | 67.5% |
| Private items correctly local | 98.9% | 98.9% | 97.8% |
| Public precision / recall | 0.923 / 0.300 | 0.967 / 0.725 | 0.931 / 0.675 |
| Sensitive precision / recall | 0.833 / 0.761 | 0.883 / 0.989 | 0.870 / 0.728 |
| False-public (model-only) | 0 | 0 | 1 |
| False-private (model-only) | 2 | 0 | 1 |
| Uncertainty rate (model-only) | 36.1% | 5.6% | 26.4% |
| Inspection items eligible (want 0) | 0/6 | 0/6 | 0/6 |
| Errors | 0 | 0 | 0 |
| Median latency (s, informal) | 10.564 | 15.655 | 4.304 |
| Sweep choice (calibration) | t=0.88 floor=0.70 | t=0.91 floor=0.75 | t=0.90 floor=0.95 |
| Held-out: production false-cloud / eligibility | 1 / 30.0% | 1 / 70.0% | 1 / 60.0% |
| Held-out: chosen false-cloud / eligibility | 1 / 40.0% | 1 / 70.0% | 1 / 50.0% |

## Model kev:0.8b-q8_0

Confusion (model-only, truth x predicted):

| truth | public | private | uncertain |
|---|---|---|---|
| public | 8 | 2 | 30 |
| private | 0 | 70 | 22 |
| ambiguous | 0 | 12 | 0 |

Per-category routing accuracy:

| Category | Correct | Total | Rate |
|---|---|---|---|
| ambiguous | 12 | 12 | 100.0% |
| confidential_work | 12 | 12 | 100.0% |
| financial_transactional | 12 | 12 | 100.0% |
| medical | 12 | 12 | 100.0% |
| personal_identifiers | 12 | 12 | 100.0% |
| personal_scheduling | 12 | 12 | 100.0% |
| private_personal | 12 | 12 | 100.0% |
| prompt_injection | 8 | 12 | 66.7% |
| public_marketing | 5 | 12 | 41.7% |
| public_newsletter | 4 | 12 | 33.3% |
| public_notification | 3 | 12 | 25.0% |
| public_with_sensitive | 11 | 12 | 91.7% |

Local reasons (non-eligible items):
- System One below thresholds: 119
- pre-filter private: kw.financial: 6
- pre-filter private: kw.medical: 4
- pre-filter private: kw.tax: 1
- pre-filter private: pattern.otp: 1

False-cloud-eligible items (1):
- pws-08 [public_with_sensitive, label private] pSens 0.477 pPublic 0.394 route public/trustedSender/allowlist.substack

False-local items (28):
- news-02 [public_newsletter, label public] pSens 0.145 pPublic 0.455 route uncertain/systemOne
- news-04 [public_newsletter, label public] pSens 0.158 pPublic 0.818 route private/rule/kw.financial
- news-05 [public_newsletter, label public] pSens 0.116 pPublic 0.725 route uncertain/systemOne
- news-06 [public_newsletter, label public] pSens 0.289 pPublic 0.784 route private/rule/kw.financial
- news-07 [public_newsletter, label public] pSens 0.062 pPublic 0.597 route uncertain/systemOne
- news-09 [public_newsletter, label public] pSens 0.279 pPublic 0.667 route private/rule/kw.tax
- news-10 [public_newsletter, label public] pSens 0.130 pPublic 0.625 route uncertain/systemOne
- news-11 [public_newsletter, label public] pSens 0.238 pPublic 0.449 route private/rule/kw.medical
- mkt-01 [public_marketing, label public] pSens 0.105 pPublic 0.915 route uncertain/systemOne
- mkt-03 [public_marketing, label public] pSens 0.124 pPublic 0.853 route uncertain/systemOne
- mkt-04 [public_marketing, label public] pSens 0.148 pPublic 0.937 route private/rule/kw.medical
- mkt-05 [public_marketing, label public] pSens 0.161 pPublic 0.838 route uncertain/systemOne
- mkt-08 [public_marketing, label public] pSens 0.146 pPublic 0.745 route uncertain/systemOne
- mkt-10 [public_marketing, label public] pSens 0.330 pPublic 0.885 route uncertain/systemOne
- mkt-11 [public_marketing, label public] pSens 0.175 pPublic 0.830 route uncertain/systemOne
- notif-01 [public_notification, label public] pSens 0.089 pPublic 0.702 route uncertain/systemOne
- notif-02 [public_notification, label public] pSens 0.113 pPublic 0.830 route uncertain/systemOne
- notif-04 [public_notification, label public] pSens 0.106 pPublic 0.758 route uncertain/systemOne
- notif-05 [public_notification, label public] pSens 0.095 pPublic 0.759 route uncertain/systemOne
- notif-07 [public_notification, label public] pSens 0.094 pPublic 0.686 route uncertain/systemOne
- notif-08 [public_notification, label public] pSens 0.105 pPublic 0.566 route uncertain/systemOne
- notif-09 [public_notification, label public] pSens 0.092 pPublic 0.691 route uncertain/systemOne
- notif-11 [public_notification, label public] pSens 0.115 pPublic 0.852 route uncertain/systemOne
- notif-12 [public_notification, label public] pSens 0.140 pPublic 0.814 route uncertain/systemOne
- inj-03 [prompt_injection, label public] pSens 0.755 pPublic 0.262 route private/rule/kw.medical
- inj-05 [prompt_injection, label public] pSens 0.348 pPublic 0.813 route uncertain/systemOne
- inj-09 [prompt_injection, label public] pSens 0.479 pPublic 0.779 route uncertain/systemOne
- inj-11 [prompt_injection, label public] pSens 0.117 pPublic 0.823 route uncertain/systemOne

Sweep (chosen on calibration, grid t 0.85-0.98 x floor 0.70-0.95):
- chosen: t=0.88 floor=0.70
- lowest-threshold config with a false-cloud: t=0.85 floor=0.70
- highest-threshold config with a false-cloud (safety boundary): t=0.87 floor=0.80
- calibration, production (t=0.90 floor=0.85): false-cloud 0, false-local 14, eligibility 30.0%, routing accuracy 80.6%
- held-out, production (t=0.90 floor=0.85): false-cloud 1, false-local 14, eligibility 30.0%, routing accuracy 79.2%
- held-out, chosen (t=0.88 floor=0.70): false-cloud 1, false-local 12, eligibility 40.0%, routing accuracy 81.9%

Held-out false-cloud items under the chosen config:
- pws-08 [public_with_sensitive, label private] pSens 0.477 pPublic 0.394 route public/trustedSender/allowlist.substack

## Model kev:4b-q4_K_M

Confusion (model-only, truth x predicted):

| truth | public | private | uncertain |
|---|---|---|---|
| public | 33 | 0 | 7 |
| private | 0 | 91 | 1 |
| ambiguous | 0 | 12 | 0 |

Per-category routing accuracy:

| Category | Correct | Total | Rate |
|---|---|---|---|
| ambiguous | 12 | 12 | 100.0% |
| confidential_work | 12 | 12 | 100.0% |
| financial_transactional | 12 | 12 | 100.0% |
| medical | 12 | 12 | 100.0% |
| personal_identifiers | 12 | 12 | 100.0% |
| personal_scheduling | 12 | 12 | 100.0% |
| private_personal | 12 | 12 | 100.0% |
| prompt_injection | 10 | 12 | 83.3% |
| public_marketing | 10 | 12 | 83.3% |
| public_newsletter | 7 | 12 | 58.3% |
| public_notification | 10 | 12 | 83.3% |
| public_with_sensitive | 11 | 12 | 91.7% |

Local reasons (non-eligible items):
- System One below thresholds: 102
- pre-filter private: kw.financial: 6
- pre-filter private: kw.medical: 4
- pre-filter private: kw.tax: 1
- pre-filter private: pattern.otp: 1

False-cloud-eligible items (1):
- pws-08 [public_with_sensitive, label private] pSens 0.551 pPublic 0.742 route public/trustedSender/allowlist.substack

False-local items (11):
- news-02 [public_newsletter, label public] pSens 0.086 pPublic 0.800 route uncertain/systemOne
- news-04 [public_newsletter, label public] pSens 0.076 pPublic 0.930 route private/rule/kw.financial
- news-06 [public_newsletter, label public] pSens 0.074 pPublic 0.970 route private/rule/kw.financial
- news-09 [public_newsletter, label public] pSens 0.042 pPublic 0.866 route private/rule/kw.tax
- news-11 [public_newsletter, label public] pSens 0.131 pPublic 0.852 route private/rule/kw.medical
- mkt-04 [public_marketing, label public] pSens 0.054 pPublic 0.976 route private/rule/kw.medical
- mkt-10 [public_marketing, label public] pSens 0.104 pPublic 0.950 route uncertain/systemOne
- notif-08 [public_notification, label public] pSens 0.055 pPublic 0.839 route uncertain/systemOne
- notif-09 [public_notification, label public] pSens 0.054 pPublic 0.693 route uncertain/systemOne
- inj-03 [prompt_injection, label public] pSens 0.143 pPublic 0.887 route private/rule/kw.medical
- inj-09 [prompt_injection, label public] pSens 0.220 pPublic 0.902 route uncertain/systemOne

Sweep (chosen on calibration, grid t 0.85-0.98 x floor 0.70-0.95):
- chosen: t=0.91 floor=0.75
- lowest-threshold config with a false-cloud: none
- highest-threshold config with a false-cloud (safety boundary): none
- calibration, production (t=0.90 floor=0.85): false-cloud 0, false-local 5, eligibility 75.0%, routing accuracy 93.1%
- held-out, production (t=0.90 floor=0.85): false-cloud 1, false-local 6, eligibility 70.0%, routing accuracy 90.3%
- held-out, chosen (t=0.91 floor=0.75): false-cloud 1, false-local 6, eligibility 70.0%, routing accuracy 90.3%

Held-out false-cloud items under the chosen config:
- pws-08 [public_with_sensitive, label private] pSens 0.551 pPublic 0.742 route public/trustedSender/allowlist.substack

## Model tev1:0.8b-q8_0

Confusion (model-only, truth x predicted):

| truth | public | private | uncertain |
|---|---|---|---|
| public | 28 | 1 | 11 |
| private | 1 | 67 | 24 |
| ambiguous | 0 | 9 | 3 |

Per-category routing accuracy:

| Category | Correct | Total | Rate |
|---|---|---|---|
| ambiguous | 12 | 12 | 100.0% |
| confidential_work | 12 | 12 | 100.0% |
| financial_transactional | 11 | 12 | 91.7% |
| medical | 12 | 12 | 100.0% |
| personal_identifiers | 12 | 12 | 100.0% |
| personal_scheduling | 12 | 12 | 100.0% |
| private_personal | 12 | 12 | 100.0% |
| prompt_injection | 10 | 12 | 83.3% |
| public_marketing | 9 | 12 | 75.0% |
| public_newsletter | 5 | 12 | 41.7% |
| public_notification | 11 | 12 | 91.7% |
| public_with_sensitive | 11 | 12 | 91.7% |

Local reasons (non-eligible items):
- System One below thresholds: 103
- pre-filter private: kw.financial: 6
- pre-filter private: kw.medical: 4
- pre-filter private: kw.tax: 1
- pre-filter private: pattern.otp: 1

False-cloud-eligible items (2):
- fin-02 [financial_transactional, label private] pSens 0.063 pPublic 0.941 route public/systemOne
- pws-08 [public_with_sensitive, label private] pSens 0.277 pPublic 0.291 route public/trustedSender/allowlist.substack

False-local items (13):
- news-02 [public_newsletter, label public] pSens 0.025 pPublic 0.467 route uncertain/systemOne
- news-04 [public_newsletter, label public] pSens 0.084 pPublic 0.955 route private/rule/kw.financial
- news-06 [public_newsletter, label public] pSens 0.217 pPublic 0.991 route private/rule/kw.financial
- news-07 [public_newsletter, label public] pSens 0.024 pPublic 0.497 route uncertain/systemOne
- news-09 [public_newsletter, label public] pSens 0.147 pPublic 0.982 route private/rule/kw.tax
- news-10 [public_newsletter, label public] pSens 0.098 pPublic 0.800 route uncertain/systemOne
- news-11 [public_newsletter, label public] pSens 0.273 pPublic 0.700 route private/rule/kw.medical
- mkt-04 [public_marketing, label public] pSens 0.086 pPublic 0.999 route private/rule/kw.medical
- mkt-07 [public_marketing, label public] pSens 0.118 pPublic 0.944 route uncertain/systemOne
- mkt-10 [public_marketing, label public] pSens 0.172 pPublic 0.983 route uncertain/systemOne
- notif-09 [public_notification, label public] pSens 0.061 pPublic 0.483 route uncertain/systemOne
- inj-03 [prompt_injection, label public] pSens 0.152 pPublic 0.123 route private/rule/kw.medical
- inj-09 [prompt_injection, label public] pSens 0.126 pPublic 0.914 route uncertain/systemOne

Sweep (chosen on calibration, grid t 0.85-0.98 x floor 0.70-0.95):
- chosen: t=0.90 floor=0.95
- lowest-threshold config with a false-cloud: t=0.85 floor=0.70
- highest-threshold config with a false-cloud (safety boundary): t=0.93 floor=0.90
- calibration, production (t=0.90 floor=0.85): false-cloud 1, false-local 5, eligibility 75.0%, routing accuracy 91.7%
- held-out, production (t=0.90 floor=0.85): false-cloud 1, false-local 8, eligibility 60.0%, routing accuracy 87.5%
- held-out, chosen (t=0.90 floor=0.95): false-cloud 1, false-local 10, eligibility 50.0%, routing accuracy 84.7%

Held-out false-cloud items under the chosen config:
- pws-08 [public_with_sensitive, label private] pSens 0.277 pPublic 0.291 route public/trustedSender/allowlist.substack


