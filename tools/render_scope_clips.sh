#!/usr/bin/env bash
# Scope clips of the real game for the visual judge (see render_scope_clips.gd): tools/render_scope_clips.sh [out dir under the project, default screenshots/scope_clips]
# Needs a GPU window (run it through heavy/gpu.sh shot so the judge's log names the box); frames land in <out>/<role>/<clip>/NNNN.png.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-screenshots/scope_clips}
xvfb-run -a -s "-screen 0 1280x720x24" timeout 900 godot --path . --resolution 1280x720 --fixed-fps 30 --script tools/render_scope_clips.gd -- "$OUT" 2>&1 | grep -E 'ERROR|SCRIPT|no def|scope_clips' | head -60 || true
