#!/usr/bin/env bash
# The README's Screenshots gallery frames on a real GPU (route: tools/*_shots.sh): menus, scoreboard, buy menu,
# attachments menu, hip and aimed views, a map overview, the HUD. Everything lands in screenshots/; pick and
# optimise into docs/screenshots/ by hand after reading each frame.
#   tools/readme_gallery_shots.sh      (GALLERY_GUNS=marksman,rifle picks the guns)
set -uo pipefail
cd "$(dirname "$0")/.."
tools/screenshot_menus.sh || true
tools/render_loadout.sh || true
tools/render_maps.sh || true
tools/attach_menu_shot.sh "${GALLERY_GUNS:-marksman}" || true
RENDER_ONLY="${GALLERY_GUNS:-marksman}" tools/render_weapons.sh || true
tools/screenshot.sh pit || true
tools/screenshot.sh box --glance tdm || true
