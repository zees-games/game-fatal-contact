#!/usr/bin/env bash
# The attachments menu on a real GPU, windowed: every hover and pick of the given guns, a frame each, into
# screenshots/attach_menu (examples/headless_attach_all.tscn with --only and --shots).
#   tools/attach_menu_shot.sh [marksman,rifle]
set -euo pipefail
cd "$(dirname "$0")/.."
only="${1:-marksman}"
shift || true
rm -rf screenshots/attach_menu
mkdir -p screenshots/attach_menu
exec timeout 900 xvfb-run -a -s "-screen 0 ${RESOLUTION:-1600x900}x24" godot --path . --resolution "${RESOLUTION:-1600x900}" \
  res://examples/headless_attach_all.tscn -- "--only=$only" "--shots=$PWD/screenshots/attach_menu" "$@"
