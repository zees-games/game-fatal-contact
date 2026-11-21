#!/usr/bin/env bash
# One animation-review capture on this machine, on gs-game's visual QA shot tool (gs-game docs/visual-qa.md):
# tools/anim_review.gd plays each weapon's clips at --fps, the shared tool makes the sheets and the first person |
# behind-right | opponent clips (into --clip-dir) and drops the frames. Normally started by tools/anim_review.sh.
#   tools/anim_review_shot.sh [--only rifle,pistol] [--anims reload_empty,draw] [--out DIR] [--fps 60] [--clip-dir DIR]
exec bash "$(dirname "$0")/../addons/gs_game/tools/gs_game_visual_qa_shot.sh" --script tools/anim_review.gd \
  --out screenshots/anim_review --keep '^ANIM(REVIEW|FRAMES) |WEAPON_LAB|ERROR: .*(anim_review|weapon_lab)' -- --no-turntable "$@"
