#!/usr/bin/env bash
# Client perf gate: the 32-player cp-orange-x3 benchmark (tools/perf_bench.sh: 31 bots, local sim host, seeded pilot)
# run N times, its medians compared with ci/perf/client_gate_<tier>.json by tools/perf_gate.py. See docs/testing.md.
#   tools/perf_gate.sh [--tier headless|windowed] [--runs 3] [--box B] [--update [--note TEXT]] [--logs DIR] [-- bench args]
# headless (default): PH via hv (a shared suite slot), no GPU: script/physics ms, span ms and node/object counts. windowed: staging02's GPU (Xorg) adds
# render ms and draw counts; its baseline names the GPU, so another box's numbers exit 3 instead of passing by luck.
# --logs DIR compares the logs already in DIR (no new runs). --update writes the baseline from these runs instead.
# Exit 0 pass, 1 regression, 2 usage or missing data, 3 not comparable (other GPU, other scenario, inert run).
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tier=headless runs=3 box="" update=() logs_dir=""
while [[ $# -gt 0 ]]; do
	case $1 in
		--tier) tier=$2; shift 2 ;;
		--runs) runs=$2; shift 2 ;;
		--box) box=$2; shift 2 ;;
		--update) update+=(--update); shift ;;
		--note) update+=(--note "$2"); shift 2 ;;
		--logs) logs_dir=$2; shift 2 ;;
		--) shift; break ;;
		*) echo "perf_gate: unknown option $1" >&2; exit 2 ;;
	esac
done
case $tier in
	headless) box=${box:-ph}; hl=(--headless) ;;
	windowed) box=${box:-staging02}; hl=() ;;
	*) echo "perf_gate: --tier headless|windowed" >&2; exit 2 ;;
esac
baseline=$here/ci/perf/client_gate_$tier.json

if [[ -z $logs_dir ]]; then
	logs_dir=${PERF_GATE_LOGS:-/home/gamedev/perf-bench/gate}/$(date +%Y%m%d-%H%M%S)-$tier-$(basename "$here")
	mkdir -p "$logs_dir"
	# The fixed scenario. Changing any of it needs a new baseline: perf_gate.py refuses to compare across scenarios.
	args=(--map cp-orange-x3 --mode ffa --bots 31 --seed 1 --sim-host 1 --pilot 1 --warmup 20 --seconds 60 --res 1152x650)
	# A run that never reached the bench (a failed upload, a lost box) is retried, up to twice the runs asked for.
	for ((i = 1, good = 0; good < runs && i <= 2 * runs; i++)); do
		echo "perf_gate: run $i ($((good + 1))/$runs) on $box ($tier) -> $logs_dir" >&2
		if [[ $tier == headless ]]; then
			# Headless needs no exclusive box: hv runs it in a suite slot pinned to $box (gpu.sh run's exclusive lock on PH
			# starved for 20+ min behind suites). Neighbouring suites add ms noise, which the median of 3 and noise_k absorb.
			( cd "$here" && GPU_BOX=$box HV_TIMEOUT=900 /home/gamedev/bin/hv "$here" scene res://tools/perf_bench.tscn -- \
				--tag "gate$i" "${args[@]}" "$@" ) > "$logs_dir/$(date +%Y%m%d-%H%M%S)-$box-$(basename "$here")-gate$i-headless.log" 2>&1
		else
			# An empty reference: perf_bench only reports, and the gate reads the log it leaves.
			PERF_BENCH_LOGS=$logs_dir PERF_BENCH_REF=none bash "$here/tools/perf_bench.sh" --box "$box" "${hl[@]}" --tag "gate$i" -- "${args[@]}" "$@" > /dev/null 2>&1
		fi
		good=$(grep -l '^PERF_BENCH_REPORT ' "$logs_dir"/*.log 2>/dev/null | wc -l)
	done
fi
mapfile -t logs < <(grep -l '^PERF_BENCH_REPORT ' "$logs_dir"/*.log 2>/dev/null)
for f in "$logs_dir"/*.log; do
	grep -q '^PERF_BENCH_REPORT ' "$f" || echo "perf_gate: no report in $f (skipped): $(grep -a 'gpu.sh\|ERROR' "$f" | tail -1)" >&2
done
[[ ${#logs[@]} -gt 0 ]] || { echo "perf_gate: no bench report in $logs_dir" >&2; exit 2; }
# An inert world (no fights, nothing moving) reads as a speedup: the shared check flags it, and the gate refuses it.
python3 "$here/addons/gs_game/tools/gs_game_perf_bench_compare.py" --check "${logs[@]}" 2>/dev/null | grep -a 'WARN INERT' && exit 3
python3 "$here/tools/perf_gate.py" --baseline "$baseline" "${update[@]}" "${logs[@]}"
