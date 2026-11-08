"""System One latency, load and residency benchmark on synthetic emails.

Sends the same request body as OllamaSystemOneClient.requestBody (model, state, questions).
Usage: python3 -I latency.py [model ...]   (default: the three benchmark models)
"""
import json, statistics, subprocess, sys, threading, time, urllib.request

BASE = "http://localhost:11434"
MODELS = sys.argv[1:] or ["kev:0.8b-q8_0", "kev:4b-q4_K_M", "tev1:0.8b-q8_0"]
CRITERIA = {
    "public_newsletter_or_promo": "Public newsletters, marketing promotions, product updates, or public notifications.",
    "personal_or_work_private": "Private correspondence, internal work communication, or personal scheduling.",
    "sensitive_transactional": "Bills, receipts, security alerts, account statements, or legal or medical documents.",
}
QUESTIONS = {
    "contains_pii_or_sensitive": {"type": "noul", "instructions": "Does this email contain personally identifiable information, financial records, medical information, credentials, private personal matters, or confidential work discussions?"},
    "mail_category": {"type": "choice", "instructions": "Classify the primary nature of this email.", "criteria": CRITERIA},
}
FILLER = "This week we look at new Swift concurrency proposals, a SwiftUI layout deep dive, three open-source packages worth trying and a recap of the community meetup. "
PREFIX = "Subject: This week in Swift\nFrom: Swift Weekly <news@weekly.example>\nBody: "
COLD_RUNS, WARM_RUNS = 3, 10


def state(chars):
    return PREFIX + (FILLER * 20)[: chars - len(PREFIX) - 1] + "…"


def post(path, payload, timeout=600):
    req = urllib.request.Request(BASE + path, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def ps():
    with urllib.request.urlopen(BASE + "/api/ps", timeout=10) as r:
        return {m["name"]: m for m in json.load(r)["models"]}


def runner_rss_mb():
    out = subprocess.run(["ps", "-axo", "rss=,command="], capture_output=True, text=True).stdout
    return {line.split(None, 1)[1][-80:]: round(int(line.split()[0]) / 1024) for line in out.splitlines() if "ollama runner" in line}


def call(model, st):
    t = time.perf_counter()
    post("/v1/systemone", {"model": model, "state": st, "questions": QUESTIONS})
    return time.perf_counter() - t


def stop_all():
    for name in ps():
        subprocess.run(["ollama", "stop", name], capture_output=True)
    while ps():
        time.sleep(0.2)


def cold_call(model, st):
    """Total cold latency plus the time until the model shows up in /api/ps (load complete)."""
    seen, done = [None], threading.Event()
    t0 = time.perf_counter()

    def poll():
        while not done.is_set():
            if model in ps():
                seen[0] = time.perf_counter() - t0
                return
            time.sleep(0.1)

    th = threading.Thread(target=poll); th.start()
    total = call(model, st)
    done.set(); th.join()
    return total, seen[0]


def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1))))]


report = {}
for model in MODELS:
    report[model] = {}
    for label, chars in [("short", 300), ("near-1500", 1500)]:
        st = state(chars)
        colds, loads = [], []
        for _ in range(COLD_RUNS):
            stop_all()
            total, load = cold_call(model, st)
            colds.append(total); loads.append(load)
        warms = [call(model, st) for _ in range(WARM_RUNS)]
        info = ps().get(model, {})
        report[model][label] = {
            "chars": len(st),
            "cold_median_s": round(statistics.median(colds), 2), "cold_max_s": round(max(colds), 2),
            "load_visible_median_s": round(statistics.median([l for l in loads if l is not None]), 2) if any(loads) else None,
            "warm_median_s": round(statistics.median(warms), 2), "warm_p95_s": round(pct(warms, 95), 2),
            "warm_min_s": round(min(warms), 2),
            "ps_size_gb": round(info.get("size", 0) / 1e9, 2), "context": info.get("context_length"),
        }
        report[model][label]["runner_rss_mb"] = runner_rss_mb()
        print(model, label, json.dumps(report[model][label]), flush=True)

# Residency: triage model then a Qwen3 4B extraction-sized call, then all three triage models in turn.
stop_all()
res = []
for model in MODELS:
    k = call(model, state(1500))
    q_t = time.perf_counter()
    post("/api/chat", {"model": "qwen3:4b", "stream": False, "think": False,
                       "options": {"num_predict": 200, "temperature": 0},
                       "messages": [{"role": "user", "content": "Summarise as JSON {\"summary\": string}.\n" + state(1500)}]})
    q = time.perf_counter() - q_t
    k2 = call(model, state(1500))
    res.append({"model": model, "triage_s": round(k, 2), "qwen_s": round(q, 2), "triage_after_qwen_s": round(k2, 2),
                "resident": sorted(ps())})
    print("residency", json.dumps(res[-1]), flush=True)
report["residency"] = res
report["final_ps"] = subprocess.run(["ollama", "ps"], capture_output=True, text=True).stdout
report["vm_stat"] = subprocess.run(["sh", "-c", "vm_stat | head -4"], capture_output=True, text=True).stdout
print(json.dumps(report, indent=1))
