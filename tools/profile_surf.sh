#!/usr/bin/env bash
# Profiles a bot match on surf_10x_reloaded_fixed with gs-profiler's runner: prints PERF and PROFILER lines and the text report.
# Usage: tools/profile_surf.sh [seconds] [map]. Headless measures scripts and physics only; render cost wants ../gpu.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
SECONDS_REC="${1:-20}"
MAP="${2:-surf_10x_reloaded_fixed}"
if [ ! -e addons/gs_profiler ]; then
    echo "addons/gs_profiler missing: ln -s ../../gs-profiler/addons/gs_profiler addons/gs_profiler" >&2
    exit 2
fi
exec heavy -- timeout -k 10 $((SECONDS_REC + 150)) godot --headless --path . \
    res://addons/gs_profiler/tools/gs_profiler_run.tscn -- \
    --profile-scene res://tools/client_bench.tscn --profile-warmup 25 --profile-seconds "$SECONDS_REC" \
    --profile-budget 16.7 \
    --map "$MAP" --bots 3 --delay 20 --play --seconds $((SECONDS_REC + 60))
