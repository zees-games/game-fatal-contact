#!/usr/bin/env bash
# Posts an animation-review capture (tools/anim_review.sh) to a nightly review item through gs-game's visual QA post
# tool: each <weapon>/<clip>.mp4 as a clip with its fps (from the file), frames and verdict in --metrics, and its
# first-person sheet as a filmstrip. The review item must exist: nightly review new "FC animation review" --key fc-anim-<date>.
#   tools/anim_review_post.sh <review-key> [--variant before|after] [--only rifle,pistol] [--anims fire,avatar_walk] [--fails]
exec bash "$(dirname "$0")/../addons/gs_game/tools/gs_game_visual_qa_post.sh" "${1:?usage: anim_review_post.sh <review-key> [--variant before|after] [--only w,w] [--anims a,a] [--fails]}" \
  --out screenshots/anim_review --by anim-review "${@:2}"
