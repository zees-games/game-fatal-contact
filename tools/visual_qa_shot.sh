#!/usr/bin/env bash
# FC's visual QA capture of the horde monsters on dot-game's shot tool (docs/visual-qa.md). gpu.sh runs only tools/*.sh.
exec bash "$(dirname "$0")/../addons/dot_game/tools/dot_game_visual_qa_shot.sh" --script tools/visual_qa.gd -- "$@"
