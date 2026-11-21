#!/usr/bin/env bash
# The 16v16 benchmark on a GPU box: gs-game's tool (addons/gs_game/tools/gs_game_perf_bench.sh), against the owner's profile.
# Present through a headless Xorg, not Xvfb: Xvfb costs the NVIDIA driver ~10 ms/frame of sched_yield spin (gpu.sh ensure_xorg).
# The box is --box (default staging02). ph has no GPU and no Xorg: GPU_XORG=1 fails loudly there, and a windowed run (llvmpipe) crashes
# with signal 11, so ph needs --headless (frame times are then CPU-only, no render rows). GPU_XORG=0 is always honoured; staging boxes keep GPU_XORG=1.
bench_box=staging02 bench_hl=0
for ((i = 1; i <= $#; i++)); do
	[[ ${!i} == -- ]] && break
	[[ ${!i} == --headless ]] && bench_hl=1
	[[ ${!i} == --box ]] && { j=$((i + 1)); bench_box=${!j:-}; }
done
if [[ $bench_box == ph ]]; then
	[[ ${GPU_XORG:-0} == 1 ]] && { echo "perf_bench: --box ph has no GPU and no Xorg, so GPU_XORG=1 cannot work; unset it" >&2; exit 2; }
	[[ $bench_hl == 1 ]] || { echo "perf_bench: --box ph has no GPU: a windowed run crashes there (llvmpipe, signal 11). Add --headless (CPU-only numbers) or use --box staging02" >&2; exit 2; }
	export GPU_XORG=0
else
	export GPU_XORG=${GPU_XORG:-1}
fi
# The reference profile moved from perf-logs/arena to perf-logs/fc; a missing file means "report only", not a crash.
export PERF_BENCH_REF=${PERF_BENCH_REF:-/home/christian/perf-logs/fc/profile-20261108160712-051.json}
[[ -f $PERF_BENCH_REF ]] || { echo "perf_bench: reference profile $PERF_BENCH_REF missing: report only" >&2; export PERF_BENCH_REF=; }
exec bash "$(dirname "$0")/../addons/gs_game/tools/gs_game_perf_bench.sh" "$@"
