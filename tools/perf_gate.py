#!/usr/bin/env python3
"""Client perf gate comparator: medians of N perf_bench logs against a stored baseline (tools/perf_gate.sh drives it).

  perf_gate.py --baseline ci/perf/client_gate_headless.json [--update] [--note TEXT] LOG...

Each LOG is a tools/perf_bench.sh log (PERF_BENCH_REPORT + PERF_BENCH_SIDECAR lines). Every metric is the median over
the logs. A count fails when it grows more than max(count_pct (default 5%), noise_k x the baseline's own spread); an ms
metric fails when it grows more than max(ms_pct, noise_k x spread) and by more than ms_floor, so a 0.05 ms span cannot
fail on jitter.
Exit 0 pass, 1 regression, 2 usage or missing data, 3 baseline taken on another GPU / scenario (not comparable).
"""
import argparse
import json
import os
import statistics
import sys

# Counts: per-run p50 of the engine monitors. Render counts are 0 headless, so they drop out there.
COUNTS = ["nodes", "objects", "objects_drawn", "draw_calls", "primitives"]
# Spans, matched on the name after the first dot ('arena.present' and 'fc.present' are one span).
SYSTEMS = ["present", "net_snapshot", "predict"]
TREE = ["pf_nodes", "pf_tail"]
SCENARIO = ["map", "mode", "bots", "players", "seconds", "seed", "sim_host", "pilot", "pilot_view", "renderer"]
DEFAULT_LIMITS = {"count_pct": 5.0, "ms_pct": 10.0, "noise_k": 1.0, "ms_floor": 0.1}


def read_log(path):
    report = sidecar = None
    with open(path, errors="replace") as f:
        for line in f:
            if line.startswith("PERF_BENCH_REPORT "):
                report = json.loads(line[len("PERF_BENCH_REPORT "):])
            elif line.startswith("PERF_BENCH_SIDECAR "):
                sidecar = json.loads(line[len("PERF_BENCH_SIDECAR "):])
    if report is None or sidecar is None:
        raise ValueError("%s: no PERF_BENCH_REPORT/SIDECAR line" % path)
    return report, sidecar


def span(name):
    return name.split(".", 1)[1] if "." in name else name


def metrics(report):
    m = {
        "frame_p50_ms": report["p50_ms"],
        "frame_p95_ms": report["p95_ms"],
        "frame_p99_ms": report["p99_ms"],
    }
    for k in ("script", "physics", "render"):
        m["%s_ms" % k] = report["frame_stats"][k]["avg"]
    for s in report.get("systems", []):
        if span(s["system"]) in SYSTEMS:
            m["%s_ms" % span(s["system"])] = s["ms_per_frame"]
    for t in report.get("tree", []):
        if span(t["name"]) in TREE:
            m["%s_ms" % span(t["name"])] = t["ms"]
    mon = report.get("monitors", {})
    for k in COUNTS:
        v = mon.get(k)
        if isinstance(v, dict) and v.get("p50"):
            m["%s_count" % k] = v["p50"]
    return m


def scenario(sidecar):
    out = {k: sidecar.get(k) for k in SCENARIO}
    out["gpu"] = sidecar.get("adapter", "")
    out["cpu"] = sidecar.get("cpu", "")
    return out


def write_baseline(path, scen, med, spread, logs, note):
    old = {}
    if os.path.exists(path):
        with open(path) as f:
            old = json.load(f)
    base = {
        "scenario": scen,
        "runs": len(logs),
        "note": note or old.get("note", ""),
        "limits": old.get("limits", DEFAULT_LIMITS),
        "median": {k: round(v, 4) for k, v in med.items()},
        "spread": {k: round(v, 4) for k, v in spread.items()},
        "logs": [os.path.basename(p) for p in logs],
    }
    with open(path, "w") as f:
        json.dump(base, f, indent=1, sort_keys=True)
        f.write("\n")
    print("perf_gate: baseline written to %s (%d runs)" % (path, len(logs)))
    for k in sorted(med):
        print("  %-20s %10.3f  spread %5.1f%%" % (k, med[k], 100 * spread[k]))


def compare(base, scen, med):
    bs = base["scenario"]
    # The CPU model is reported, not matched: PH and staging02 keep one model each, and a headless count must not care.
    diff = {k: (bs.get(k), scen.get(k)) for k in bs if k != "cpu" and bs.get(k) != scen.get(k)}
    if diff:
        print("perf_gate: NOT COMPARABLE: the scenario differs from the baseline's %s; re-baseline on purpose with --update" % diff)
        return 3
    lim = base["limits"]
    fails = 0
    print("  %-20s %10s %10s %8s %7s" % ("metric", "baseline", "median", "delta", "limit"))
    for k, b in sorted(base["median"].items()):
        if k not in med:
            print("  %-20s %10.3f %10s  MISSING  FAIL" % (k, b, "-"))
            fails += 1
            continue
        v = med[k]
        d = 100.0 * (v - b) / b if b else 0.0
        # A metric that already swung more than its limit across the baseline's own runs gets that swing as its limit:
        # the seeded pilot's camera wanders, so windowed draw counts can differ 2x run to run (a 3x regression still fails).
        noise = lim["noise_k"] * 100.0 * base["spread"].get(k, 0.0)
        if k.endswith("_count"):
            limit = max(lim["count_pct"], noise)
            bad = d > limit
        else:
            limit = max(lim["ms_pct"], noise)
            bad = d > limit and (v - b) > lim["ms_floor"]
        fails += bad
        print("  %-20s %10.3f %10.3f %+7.1f%% %6.1f%%%s" % (k, b, v, d, limit, "  FAIL" if bad else ""))
    print("perf_gate: %s (%d metric(s) over their limit)" % ("FAIL" if fails else "PASS", fails))
    return 1 if fails else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline", required=True)
    ap.add_argument("--update", action="store_true")
    ap.add_argument("--note", default="")
    ap.add_argument("logs", nargs="+")
    a = ap.parse_args()

    runs = []
    for p in a.logs:
        try:
            runs.append(read_log(p))
        except (OSError, ValueError) as e:
            print("perf_gate: %s" % e, file=sys.stderr)
            return 2
    if len(runs) < 3:
        print("perf_gate: %d run(s); the gate takes the median of at least 3" % len(runs), file=sys.stderr)
        return 2
    scens = [scenario(s) for _, s in runs]
    if any(s != scens[0] for s in scens):
        print("perf_gate: the runs differ in scenario: %s" % scens, file=sys.stderr)
        return 2
    per_run = [metrics(r) for r, _ in runs]
    keys = set.intersection(*(set(m) for m in per_run))
    med = {k: statistics.median(m[k] for m in per_run) for k in keys}
    # Relative spread (max - min over median) of this set: the noise a baseline was taken with.
    spread = {k: (max(m[k] for m in per_run) - min(m[k] for m in per_run)) / med[k] if med[k] else 0.0 for k in keys}

    if a.update:
        write_baseline(a.baseline, scens[0], med, spread, a.logs, a.note)
        return 0
    try:
        with open(a.baseline) as f:
            base = json.load(f)
    except OSError:
        print("perf_gate: no baseline %s: take one with --update" % a.baseline, file=sys.stderr)
        return 2
    print("perf_gate: %d runs vs %s (%s)" % (len(runs), a.baseline, base["scenario"].get("gpu") or "headless"))
    return compare(base, scens[0], med)


if __name__ == "__main__":
    sys.exit(main())
