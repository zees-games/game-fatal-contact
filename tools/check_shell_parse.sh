#!/usr/bin/env bash
# Every script the pack ships must compile against the addons the Gamespice client shell carries: the tags in
# dot-server-deploy's addons.lock, not the linked working trees (usually some levels ahead). The suites and the
# parse pass in game.sh only see the linked heads. On 2026-11-16 pack 0.1.67 named dot-bot 32 and dot-weapon 41
# calls; on the shell (dot-bot 26, dot-weapon 40) the bot brain and the HUD did not compile, bots stood still and
# the throw meter's empty track sat under the crosshair. tools/publish.sh runs this first.
#   tools/check_shell_parse.sh [--lock FILE]   default lock: <repos>/dot-server-deploy/addons.lock
# The addon repositories are the siblings of dot-server-deploy (GS_REPOS_ROOT, else this checkout's parent).
# GODOT names the binary (default godot). Exit 0 = every shipped script parses; 1 = some do not; 2 = cannot check.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
ROOTS=("${GS_REPOS_ROOT:-${DOT_REPOS_ROOT:-}}" "$(dirname "$HERE")" /home/gamedev/godot /home/gamedev/projects/godot)
LOCK=""
[ "${1:-}" = --lock ] && LOCK="${2:-}"
if [ -z "$LOCK" ]; then
    for r in "${ROOTS[@]}"; do [ -n "$r" ] && [ -f "$r/dot-server-deploy/addons.lock" ] && { LOCK="$r/dot-server-deploy/addons.lock"; break; }; done
fi
[ -f "$LOCK" ] || { echo "check_shell_parse: no dot-server-deploy/addons.lock found (set GS_REPOS_ROOT or --lock)" >&2; exit 2; }
SIB="$(cd "$(dirname "$LOCK")/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/addons"
# The pinned addons, as dot-server-deploy's tools/check-pinned.sh builds them (the lock's own directory naming).
bad=0
while IFS=$'\t' read -r repo tag; do
    case "$repo" in ''|\#*) continue ;; esac
    src="$SIB/$repo"
    [ "$repo" = fc-weapons ] && [ ! -e "$src/.git" ] && src="$SIB/arena-weapons"
    d="$(echo "$repo" | tr - _ | sed 's/_dot//')"
    [ -L "$HERE/addons/$d" ] || [ -d "$HERE/addons/$d" ] || continue
    if [ -e "$src/.git" ] && git -C "$src" archive "$tag" "addons/$d" 2>/dev/null | tar -x -C "$W"; then
        :
    else
        echo "check_shell_parse: cannot take addons/$d at $tag from $src" >&2; bad=1
    fi
done < "$LOCK"
[ "$bad" = 0 ] || exit 2
# Addons this checkout links that the lock does not pin (git-ignored downloads such as godot-sqlite): as linked.
for l in "$HERE"/addons/*; do
    d="$(basename "$l")"; [ -e "$W/addons/$d" ] || cp -a "$(readlink -f "$l")" "$W/addons/$d"
done
# The shipped scripts: what tools/publish.sh leaves in (examples, tests, tools and docs are not runtime content).
mkdir -p "$W/p"
(cd "$HERE" && git ls-files -co --exclude-standard \
    | grep -vE '^(addons|examples|tests|tools|docs|images|screenshots|shots_boot|ci|\.github)/' \
    | while read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done | tar -cf - -T -) | tar -xf - -C "$W/p"
ln -s "$W/addons" "$W/p/addons"
timeout 900 "$GODOT" --headless --path "$W/p" --import >"$W/import.log" 2>&1
(cd "$W/p" && find . -name '*.gd' -not -path './.godot/*' -not -path './addons/*' | sed 's|^\./||' > "$W/list")
PARSE_LIST="$W/list" timeout 900 "$GODOT" --headless --path "$W/p" --script res://addons/dot_core/tools/dot_parse_all.gd >"$W/parse.log" 2>&1
grep -aq '^PARSED ' "$W/parse.log" || { tail -20 "$W/parse.log" >&2; echo "check_shell_parse: the parse tool did not finish" >&2; exit 2; }
fails="$(grep -aE -A1 'Parse Error' "$W/parse.log" | grep -aE 'Parse Error|at: ' | paste - - | sed 's/SCRIPT ERROR: //; s/ *at: GDScript::reload//' | sort -u)"
if [ -n "$fails" ]; then
    echo "FAIL shipped scripts that do not compile against the shell's pinned addons ($LOCK):"
    echo "$fails"
    exit 1
fi
echo "ok   every shipped script compiles against the shell's pinned addons ($(grep -a '^PARSED ' "$W/parse.log"))"
