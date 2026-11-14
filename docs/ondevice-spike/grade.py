"""Scores the PROBE lines from OnDeviceProbe.swift. Usage: python3 -I grade.py probe.log
Rules are fixed before the run; see docs/ONDEVICE-SPIKE.md for what each one means."""
import json, re, statistics, sys

FIX = {
    "fix01": ["I will be there at 5 tomorrow."],
    "fix02": ["Can you send me the receipt when you get a chance?"],
    "fix03": ["She doesn't know about the meeting yet."],
    "fix04": ["Thanks for your help yesterday, it really helped."],
    "fix05": ["We were planning to leave around 7."],
    "fix06": ["It's going to rain, so bring an umbrella."],
    "fix07": ["Let's meet at the cafe on Main Street at 10am."],
    "fix08": ["I have attached the invoice for $240."],
    "fix09": ["You're welcome, happy to help anytime."],
    "fix10": ["The package arrived, but the box was damaged."],
}
# Facts a rewrite must keep, compared case-insensitively.
FACTS = {
    "rw01": ["report"], "rw02": ["$50"], "rw03": ["4", "3"], "rw04": ["9:30", "9"], "rw05": ["draft", "friday"],
    "rw06": ["sam"], "rw07": ["300", "250"], "rw08": ["tomorrow"], "rw09": ["files", "monday"], "rw10": ["app"],
}
INPUT_WORDS = {"rw04": 30, "rw05": 27, "rw06": 25}
INTENT = {"in01": "plan", "in02": "plan", "in03": "reminder", "in04": "reminder", "in05": "note",
          "in06": "note", "in07": "question", "in08": "question", "in09": "none", "in10": "none"}
PREAMBLE = re.compile(r"^(sure|here is|here's|certainly|of course)\b|rewritten text|edited message", re.I)
SLANG = re.compile(r"\b(hey|yo|tmrw|asap|gonna|wanna)\b", re.I)


def norm(s):
    return re.sub(r"[^a-z0-9'$]", "", s.lower().replace("’", "'"))


def passes(row):
    out, task, i = row.get("output", "").strip(), row["task"], row["id"]
    if not out or row.get("error"):
        return False
    if task == "fix":
        return norm(out) in {norm(r) for r in FIX[i]}
    if task == "intent":
        return out == INTENT[i]
    if PREAMBLE.search(out) or not all(f in out.lower() for f in FACTS[i]):
        return False
    if task == "polite":
        return re.search(r"\b(please|could you|would you|thank)", out, re.I) is not None
    if task == "shorter":
        return len(out.split()) <= 0.75 * INPUT_WORDS[i]
    if task == "professional":
        return not SLANG.search(out)
    return False


rows = []
for line in open(sys.argv[1]):
    if "PROBE {" in line:
        rows.append(json.loads(line.split("PROBE ", 1)[1].replace("\\134", "\\")))

for host in sorted({r["host"] for r in rows}):
    hr = [r for r in rows if r["host"] == host]
    for r in hr:
        if r["kind"] != "item":
            print(host, json.dumps(r, sort_keys=True))
    items = [r for r in hr if r["kind"] == "item"]
    for name, tasks in [("fix", {"fix"}), ("rewrite", {"polite", "shorter", "professional"}), ("intent", {"intent"})]:
        g = [r for r in items if r["task"] in tasks]
        if not g:
            print(host, name, "not measured")
            continue
        ttft = [r["ttft_ms"] for r in g if "ttft_ms" in r]
        tot = [r["total_ms"] for r in g]
        print(f"{host} {name}: pass {sum(passes(r) for r in g)}/{len(g)}  ttft median {statistics.median(ttft) if ttft else 'n/a'} ms"
              f"  total median {statistics.median(tot)} ms  max {max(tot)} ms  errors {sum('error' in r for r in g)}")
    for r in items:
        print(f"  {host} {r['id']:5} {'PASS' if passes(r) else 'fail'} {r['total_ms']:5}ms  {r.get('error') or r['output'][:110]!r}")
