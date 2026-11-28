#!/usr/bin/env bash
# Carrying a flag in the real offline client: a bot carrier from the front and both sides, the carrier's own shoulder view
# (both hands) and a flag thrown with the drop key, in flight and at rest (screenshots/ctf_carry/*.png), failing on any defect.
#
#   tools/render_ctf_carry.sh                 # atrium
set -euo pipefail
cd "$(dirname "$0")/.."
# A short frame sequence beside each still (GSShotSeq), so Nightly -> Review can play it.
export GS_SHOT_FRAMES=${GS_SHOT_FRAMES:-8} GS_SHOT_SECS=${GS_SHOT_SECS:-1}
map="${1:-atrium}"
exec timeout 600 xvfb-run -a godot --path . --resolution "${RESOLUTION:-1280x720}" \
  --script tools/render_ctf_carry.gd -- --map "$map"
