#!/usr/bin/env bash
# Engaged firefight bench: the server tick while every bot is fighting (box, all spawned and respawned), so a
# combat cost shows instead of bots wandering a big map unseen. Runs tools/scale128.tscn --engaged 1, RUNS times per
# bot count, one run after another on one box (PH by default, through hv), and prints each run's SERVER_TICK line
# and the spread (min / median / max) per bot count.
#
#   sudo -u gamedev tools/engaged_bench.sh                         16 and 31 bots, 3 runs each, 25 s
#   sudo -u gamedev tools/engaged_bench.sh "16" 5 -- --threads 0   extra scale128 flags after --
#   PIN=2-5 ...                                                    pins the run's threads to those cores
#
# For a code change, prefer an in-process A/B (scale128's --weapab/--leanab/--gateab style flags): both sides share
# the host's load, which a run-to-run spread on a shared box does not. Raw lines go to $OUT (default engaged-<date>.jsonl).
set -uo pipefail
cd "$(dirname "$0")/.."
NS=${1:-"16 31"}; RUNS=${2:-3}
shift $(( $# < 2 ? $# : 2 )); [ "${1:-}" = "--" ] && shift
SECS=${SECS:-25}; BOX=${GPU_BOX:-ph}
OUT=${OUT:-engaged-$(date +%Y%m%d-%H%M).jsonl}
for n in $NS; do
  for r in $(seq 1 "$RUNS"); do
    echo "== engaged bots=$n run=$r box=$BOX" >&2
    GPU_BOX=$BOX HV_TIMEOUT=$((SECS * 4 + 240)) /home/gamedev/bin/hv "$PWD" scene res://tools/scale128.tscn -- \
      --bots "$n" --engaged 1 --seconds "$SECS" --port $(( 27300 + RANDOM % 600 )) ${PIN:+--pin "$PIN"} "$@" 2>&1 \
      | grep -E '^(SCALE128|SERVER_TICK) ' | tee -a "$OUT" | grep '^SERVER_TICK'
  done
done
python3 - "$OUT" <<'PY'
import json, statistics, sys
runs = {}
for line in open(sys.argv[1]):
    if line.startswith("SCALE128 "):
        d = json.loads(line[9:])
        runs.setdefault(d["bots"], []).append(d)
for n, ds in sorted(runs.items()):
    def spread(f):
        v = sorted(f(d) for d in ds)
        return "%.2f/%.2f/%.2f" % (v[0], statistics.median(v), v[-1])
    print("bots=%d n=%d  p50 %s  p95 %s  p99 %s  tps %s  kills/min %s  (min/median/max)" % (n, len(ds),
        spread(lambda d: d["script_ms"]["p50"]), spread(lambda d: d["script_ms"]["p95"]),
        spread(lambda d: d["script_ms"]["p99"]), spread(lambda d: d["ticks_per_s"]),
        spread(lambda d: d["per_min"]["kills"])))
PY
