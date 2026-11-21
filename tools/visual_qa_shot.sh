#!/usr/bin/env bash
# FC's visual QA capture of the horde monsters on gs-game's shot tool (docs/visual-qa.md). gpu.sh runs only tools/*.sh.
exec bash "$(dirname "$0")/../addons/gs_game/tools/gs_game_visual_qa_shot.sh" --script tools/visual_qa.gd -- "$@"
