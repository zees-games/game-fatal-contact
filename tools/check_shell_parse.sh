#!/usr/bin/env bash
# Every script the pack ships must compile against the addons the Gamespice client shell carries: the tags in
# gs-server-deploy's addons.lock, not the linked working trees (usually some levels ahead). The suites and the
# parse pass in game.sh only see the linked heads. On 2026-11-16 pack 0.1.67 named gs-bot 32 and gs-weapon 41
# calls; on the shell (gs-bot 26, gs-weapon 40) the bot brain and the HUD did not compile, bots stood still and
# the throw meter's empty track sat under the crosshair. tools/publish.sh runs this first.
#   tools/check_shell_parse.sh [--lock FILE]   default lock: <repos>/gs-server-deploy/addons.lock
# The addon repositories are the siblings of gs-server-deploy (GS_REPOS_ROOT, else this checkout's parent).
# GODOT names the binary (default godot). Exit 0 = every shipped script parses; 1 = some do not; 2 = cannot check.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
ROOTS=("${GS_REPOS_ROOT:-}" "$(dirname "$HERE")" /home/gamedev/godot /home/gamedev/projects/godot)
LOCK=""
[ "${1:-}" = --lock ] && LOCK="${2:-}"
if [ -z "$LOCK" ]; then
    for r in "${ROOTS[@]}"; do [ -n "$r" ] && [ -f "$r/gs-server-deploy/addons.lock" ] && { LOCK="$r/gs-server-deploy/addons.lock"; break; }; done
fi
[ -f "$LOCK" ] || { echo "check_shell_parse: no gs-server-deploy/addons.lock found (set GS_REPOS_ROOT or --lock)" >&2; exit 2; }
SIB="$(cd "$(dirname "$LOCK")/.." && pwd)"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/addons"
# The pinned addons, as gs-server-deploy's tools/check-pinned.sh builds them (the lock's own directory naming).
bad=0
while IFS=$'\t' read -r repo tag; do
    case "$repo" in ''|\#*) continue ;; esac
    src="$SIB/$repo"
    [ "$repo" = fc-weapons ] && [ ! -e "$src/.git" ] && src="$SIB/fc-weapons"
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
# The import registered the pack's own `class_name`s, which a browser shell never does: it mounts the pack under
# res://gs_cloud/<owner>/<id>/<ver>/ and its class list is the shell's plus the addon overlay's. Keep only the
# addons' entries so a script that leans on a pack-level global fails here as it does there (0.1.70:
# "Could not find type FcHudDamageDirs", then every client script that extends through the HUD).
CACHE="$W/p/.godot/global_script_class_cache.cfg"
if [ -f "$CACHE" ]; then
    awk '
        /^(list=\[)?\{$/ { buf = ""; next }
        /^\}(, \{|\])$/ { if (buf ~ /"path": "res:\/\/addons\//) keep[++k] = buf; buf = ""; next }
        { buf = buf $0 "\n" }
        END {
            printf "list=["
            for (i = 1; i <= k; i++) printf "%s{\n%s}", (i > 1 ? ", " : ""), keep[i]
            print "]"
        }
    ' "$CACHE" > "$CACHE.addons" && mv "$CACHE.addons" "$CACHE"
fi
PARSE_LIST="$W/list" timeout 900 "$GODOT" --headless --path "$W/p" --script res://addons/gs_core/tools/gs_parse_all.gd >"$W/parse.log" 2>&1
grep -aq '^PARSED ' "$W/parse.log" || { tail -20 "$W/parse.log" >&2; echo "check_shell_parse: the parse tool did not finish" >&2; exit 2; }
fails="$(grep -aE -A1 'Parse Error' "$W/parse.log" | grep -aE 'Parse Error|at: ' | paste - - | sed 's/SCRIPT ERROR: //; s/ *at: GDScript::reload//' | sort -u)"
if [ -n "$fails" ]; then
    echo "FAIL shipped scripts that do not compile against the shell's pinned addons ($LOCK):"
    echo "$fails"
    exit 1
fi
echo "ok   every shipped script compiles against the shell's pinned addons ($(grep -a '^PARSED ' "$W/parse.log"))"
