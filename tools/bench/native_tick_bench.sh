#!/usr/bin/env bash
# The native server tick bench (docs/native-server-tick.md): the dedicated server alone, headless, 31 bots,
# cp-orange-x3 CTF, for N seconds, once with sv_native_tick=1 and once with 0, on one pinned box (default ph).
# Prints mean, p50, p99 and max server tick ms per run (every tick's cost from SIM_HOST_TICK_US, boot windows
# dropped), and with --sections the per-section ms/tick averaged over the run.
#
#   tools/bench/native_tick_bench.sh [--box ph] [--seconds 60] [--bots 31] [--map cp-orange-x3] [--sections]
#                                    [--only 1|0] [--logs DIR]
#
# Runs through gs-bootstrap's gpu.sh like tools/perf_bench.sh (GODOT_ROOT = this checkout's parent), so the box gets
# this checkout, addons included. One big before/after bench per batch, not an A/B per change.
set -euo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)
gpu=${GPU_SH:-/home/gamedev/godot/gs-bootstrap/tools/gpu.sh}
box=ph seconds=60 bots=31 map=cp-orange-x3 sections=0 only="" logs=${NATIVE_TICK_BENCH_LOGS:-/home/gamedev/perf-bench}
while (($#)); do
	case $1 in
	--box) box=$2; shift 2 ;;
	--seconds) seconds=$2; shift 2 ;;
	--bots) bots=$2; shift 2 ;;
	--map) map=$2; shift 2 ;;
	--sections) sections=1; shift ;;
	--only) only=$2; shift 2 ;;
	--logs) logs=$2; shift 2 ;;
	-h | --help) sed -n '2,11p' "$0"; exit 0 ;;
	*) echo "native_tick_bench: unknown argument $1" >&2; exit 2 ;;
	esac
done
[[ -x $gpu ]] || { echo "native_tick_bench: no gpu.sh at $gpu (set GPU_SH)" >&2; exit 2; }
mkdir -p "$logs"
stamp=$(date +%Y%m%d-%H%M%S)
rev=$(git -C "$here" rev-parse --short HEAD 2>/dev/null || echo unknown)

run_one() {
	local master=$1 log="$logs/$stamp-$box-native-tick-$master.log"
	echo "native_tick_bench: sv_native_tick=$master on $box ($bots bots, $map, ${seconds}s, $rev) -> $log" >&2
	# Boot (map load, bots) comes on top of the run; the server quits by itself after --sim_bench_sec.
	GODOT_ROOT=$(dirname "$here") GPU_BOX=$box GPU_XORG=0 GPU_TIMEOUT=${GPU_TIMEOUT:-$((seconds + 600))} \
		"$gpu" run "$(basename "$here")" --headless -- --sim_server 1 --port $((27100 + master)) --bots "$bots" \
		--map "$map" --mode ctf --sim_bench_sec "$seconds" --sim_tick_raw 1 --sim_sections "$sections" \
		--cvar "sv_native_tick=$master" > "$log" 2>&1 || echo "native_tick_bench: run exited $? (see $log)" >&2
	python3 - "$log" "$master" "$map" <<'EOF'
import re, statistics, sys
path, master, want_map = sys.argv[1:4]
text = open(path, errors="replace").read().splitlines()
ready = next((l for l in text if l.startswith("SIM_HOST ready")), "")
if f"map={want_map}" not in ready:
    print(f"sv_native_tick={master}: INVALID, the server did not load {want_map}: {ready or 'no ready line'}")
    sys.exit(3)
windows = [l.split(" ", 1)[1] for l in text if l.startswith("SIM_HOST_TICK_US ")]
# The first steady window still carries the warm-up's tail: drop it with the boot ones.
steady = [w for w in windows if not w.startswith("boot")][1:]
us = [int(v) for w in steady for v in w.strip().split(",") if v.strip().isdigit()]
if not us:
    print(f"sv_native_tick={master}: INVALID, no steady tick windows in {path}")
    sys.exit(3)
us.sort()
pick = lambda q: us[min(len(us) - 1, int(q * len(us)))] / 1000.0
print(f"sv_native_tick={master}: ticks {len(us)} | mean {statistics.fmean(us) / 1000.0:.2f} ms | p50 {pick(0.50):.2f} | "
      f"p99 {pick(0.99):.2f} | max {us[-1] / 1000.0:.2f}")
native = [l for l in text if l.startswith("SIM_HOST_NATIVE ")]
if native:
    print("  " + native[-1])
secs = {}
rows = [l for l in text if l.startswith("SIM_HOST_SECTIONS ")][2:]
for l in rows:
    for name, ms in re.findall(r"(\S+) ([0-9.]+) x[0-9.]+", l.split("|", 1)[1]):
        secs.setdefault(name, []).append(float(ms))
if secs:
    top = sorted(((statistics.fmean(v), k) for k, v in secs.items()), reverse=True)[:14]
    print("  sections ms/tick (nested, do not add up): " + ", ".join(f"{k} {v:.3f}" for v, k in top))
EOF
}

rc=0
for master in ${only:-1 0}; do
	run_one "$master" || rc=$?
done
exit $rc
