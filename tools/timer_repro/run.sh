#!/usr/bin/env bash
# Emulates a Windows box's sim host trouble on Linux and prints the SIM_HOST ticks/s and tick lines.
#   tools/timer_repro/run.sh [--pace auto|0|1] [--bots N] [--sec S] [--coarse 0|1] [--cores LIST] [--hog N] [--map ID]
# --coarse 1 preloads coarse_sleep.c (sleeps wake on a 15.625 ms boundary); --cores pins the sim process
# (taskset list, e.g. 0-3); --hog N starts N busy threads on the same cores. Run it as `heavy -- ...` / hv local.
set -uo pipefail
cd "$(dirname "$0")/../.."
bots=16 sec=30 coarse=0 cores="" hog=0 map=box pace=1 extra=""
while [[ $# -gt 0 ]]; do case $1 in
	--bots) bots=$2; shift 2 ;; --sec) sec=$2; shift 2 ;; --coarse) coarse=$2; shift 2 ;;
	--cores) cores=$2; shift 2 ;; --hog) hog=$2; shift 2 ;; --map) map=$2; shift 2 ;; --pace) pace=$2; shift 2 ;; --extra) extra=$2; shift 2 ;;
	*) echo "unknown $1" >&2; exit 2 ;; esac; done
out=${TMPDIR:-/tmp}/timer_repro.$$; mkdir -p "$out"
cc -O2 -shared -fPIC -o "$out/coarse_sleep.so" tools/timer_repro/coarse_sleep.c -ldl || exit 1
cc -O2 -o "$out/hog" tools/timer_repro/hog.c -lpthread || exit 1
pin=(); [[ -n $cores ]] && pin=(taskset -c "$cores")
pre=(); [[ $coarse == 1 ]] && pre=(env "LD_PRELOAD=$out/coarse_sleep.so")
[[ $hog -gt 0 ]] && "${pin[@]}" "$out/hog" "$hog" $((sec + 10)) &
port=$((20000 + RANDOM % 20000))
"${pin[@]}" "${pre[@]}" timeout "$sec" "${GODOT:-godot}" --headless --path . -- --sim_server 1 --port "$port" --bots "$bots" --map "$map" --sim_pace "$pace" $extra \
	--ready "$out/ready" > "$out/log" 2>&1
kill %1 2>/dev/null
echo "== bots=$bots coarse=$coarse cores=${cores:-all} hog=$hog pace=$pace"
grep -E "SIM_HOST (ready|[0-9]|BEHIND)|SIM_HOST_TICK|SIM_HOST_PACE|WARN.*BEHIND" "$out/log" | tail -n 6
grep -E "SCRIPT ERROR|^ERROR" "$out/log" | head -3
