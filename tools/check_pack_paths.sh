#!/usr/bin/env bash
# Every res:// path a shipped script loads at run time must go through FcPaths.rebase. A delivered pack
# mounts at res://gs_cloud/<id>/<version>/, so "res://maps/fc_map.gd" names a file of the host project,
# which on a panel server is nothing: 0.1.69 died there in FcMap.box ("Attempt to open script
# 'res://maps/fc_map.gd' ... File not found"), setup() handed back null and no match started. A dev
# checkout has the file at both paths, so no suite sees it; this reads the source instead.
#   tools/check_pack_paths.sh        exit 0 = clean; 1 = an un-rebased path (each printed as file:line)
# The rule, per shipped script (publish.sh's exclusions: examples, tests, tools, docs, addons, ...):
# - a "res://X" literal where X is not addons/ (host-side, shared), gs_cloud/ (the mount itself) or
#   .godot/ must sit on a line that also calls rebase( or a helper that rebases (RebaseHelpers below);
# - or be a `const NAME := "res://X..."` whose every use is on such a line.
# preload("res://<own file>") is the same mistake and is caught by the first rule. Comments are ignored; a
# call split over lines counts when rebase( is on one of the two lines above. A path that is meant to be the
# host's (an operator's res://maps.yml) says so on its line with the comment `pack-paths: host`.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
# Helpers whose body runs FcPaths.rebase on the path they are given (each one checked by hand: keep short).
REBASE='rebase\(|Ink\.texture\(|[^_a-zA-Z]texture\(|_texture\('
SKIP='^(examples|tests|tools|docs|images|screenshots|shots_boot|ci|\.github|addons|maps/imported|maps/imported_dm|worlds|worlds_dm|\.stores)/'
OWN='"res://(?!addons(/|")|gs_cloud/|\.godot/)[^"]+"'
bad=0
while IFS= read -r f; do
    [[ "$f" =~ $SKIP ]] && continue
    while IFS=: read -r n line; do
        case "$line" in *'pack-paths: host'*) continue ;; esac
        code="${line%%#*}"
        printf '%s' "$code" | grep -Pq "$OWN" || continue
        printf '%s' "$code" | grep -Eq "$REBASE" && continue
        [ "$n" -gt 2 ] && sed -n "$((n - 2)),$((n - 1))p" "$f" | grep -Eq "$REBASE" && continue
        name="$(printf '%s' "$code" | sed -nE 's/^[[:space:]]*const[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*/\1/p')"
        if [ -n "$name" ]; then
            # A path constant: every use (in any shipped script, a subclass reads it too) must rebase.
            uses="$(git grep -nwE "$name" -- '*.gd' | grep -Ev "$SKIP" | grep -v "^$f:$n:" | sed -E 's/^([^:]*:[0-9]+:)([^#]*).*/\1\2/' | grep -wE "$name" || true)"
            leak="$(printf '%s\n' "$uses" | grep -Ev "$REBASE|^\$|^[^:]*:[0-9]+:[[:space:]]*(static[[:space:]]+)?const[[:space:]]" || true)"
            [ -z "$leak" ] && continue
            printf '%s:%s: %s is used without FcPaths.rebase:\n%s\n' "$f" "$n" "$name" "$leak"
        else
            printf '%s:%s: a res:// path loaded without FcPaths.rebase:%s\n' "$f" "$n" "$line"
        fi
        bad=1
    done < <(grep -nP "$OWN" "$f")
done < <(git ls-files '*.gd')
# A `class_name` in a shipped script is a global only where the editor's class list has it: a dev checkout
# and a panel server (imported project) do, a browser shell mounting the pack does not. 0.1.70's
# FcHudDamageDirs broke the web HUD and, through it, the whole client chain ("Could not find type").
# Preload by relative path instead. Every shipped script counts here (publish.sh's exclusions only).
SHIPPED='^(examples|tests|tools|docs|images|screenshots|shots_boot|ci|\.github|addons)/'
while IFS=: read -r f n line; do
    [[ "$f" =~ $SHIPPED ]] && continue
    printf '%s:%s: a class_name in a pack (not a global on a web shell; preload by relative path):%s\n' "$f" "$n" "$line"
    bad=1
done < <(git grep -nE '^[[:space:]]*(@[a-z_]+[[:space:]]+)*class_name[[:space:]]' -- '*.gd')
[ "$bad" = 0 ] && echo "check_pack_paths: every shipped res:// path is rebased and no shipped script declares a class_name"
exit "$bad"
