#!/usr/bin/env bash
# Remote figures at 8, 28 and 36 m with cl_figure_lift_range 22 and 0, and cl_figure_bone_lod_range 22, whole frame and a close crop of each bot, into
# screenshots/far_figures/*.png; exit 1 on a failed check. See tools/render_far_figures.gd. Imports first so a fresh box has
# the class cache.
#   GPU_SHOT_BOXES=staging02 ~/godot/gpu.sh shot <worktree> tools/render_far_figures.sh
set -euo pipefail
cd "$(dirname "$0")/.."
godot --headless --path . --import >/dev/null 2>&1 || true
exec timeout 400 xvfb-run -a godot --path . --resolution "${RESOLUTION:-1280x720}" --script tools/render_far_figures.gd
