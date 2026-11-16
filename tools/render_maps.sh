#!/usr/bin/env bash
# Renders the M map picker at 1080p. Imports first so a fresh box has the class cache.
set -uo pipefail
cd "$(dirname "$0")/.."
# A short frame sequence beside each still (DotShotSeq), so Nightly -> Review can play it.
export GS_SHOT_FRAMES=${GS_SHOT_FRAMES:-${DOT_SHOT_FRAMES:-8}} GS_SHOT_SECS=${GS_SHOT_SECS:-${DOT_SHOT_SECS:-1}}
godot --headless --path . --import >/dev/null 2>&1 || true
xvfb-run -a godot --path . --resolution 1920x1080 --script tools/render_maps.gd
