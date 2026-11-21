#!/usr/bin/env bash
# Re-records warm.txt (the pack root's warm list: the scripts the web cover compiles before it drops, the rest after it; dot-cloud
# `dot_cloud/warm/list_file`) from a play path: tools/perf_bench.sh windowed on a GPU box with `--first-use 1 --warm-list 1`, once in
# ctf (menu to in-game, every weapon equipped, fired, reloaded, a grenade, a hit, a kill, a death) and once in siege (the NPC rows),
# and the union of their WARM_LIST lines (GSCloudSliceLoader.cached_scripts) written to warm.txt. Run as gamedev, from a checkout:
#   tools/record_warm_list.sh [--box staging02] [--headless]
# The pack does not ship one today (it made the warm web load 4 s slower, docs/testing.md); measure before committing it.
# Re-run it when a change adds scripts the first seconds of play load; a script the list lacks still works (compiled after the
# cover, or on first use), it only costs that frame.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for mode in ctf siege; do
	bash "$here/tools/perf_bench.sh" "$@" -- --mode "$mode" --first-use 1 --warm-list 1 --pilot 0 --bots 3 --warmup 1 --seconds 2 \
		> "$tmp/$mode.out" 2> "$tmp/$mode.err" || true
	log=$(sed -n 's/^perf_bench: .* -> \(.*\.log\)$/\1/p' "$tmp/$mode.err" | tail -1)
	[[ -n $log && -f $log ]] || { echo "record_warm_list: no bench log for $mode" >&2; cat "$tmp/$mode.err" >&2; exit 1; }
	n=$(grep -ac '^WARM_LIST ' "$log" || true)
	[[ $n -gt 0 ]] || { echo "record_warm_list: no WARM_LIST lines in $log" >&2; grep -a 'first use\|warm list\|ERROR' "$log" | tail -20 >&2; exit 1; }
	grep -a 'warm list:' "$log" | sed "s/^/record_warm_list: $mode: /" >&2 || true
	grep -a '^WARM_LIST ' "$log" | cut -d' ' -f2- >> "$tmp/all"
done
{
	echo "# Scripts the web cover compiles before it drops (dot-cloud dot_cloud/warm/list_file); every other script compiles after it."
	echo "# Written by tools/record_warm_list.sh ($(date -u +%Y-%m-%d), $(git -C "$here" rev-parse --short HEAD)): do not edit by hand, re-run it."
	sort -u "$tmp/all"
} > "$here/warm.txt"
echo "record_warm_list: $(grep -vc '^#' "$here/warm.txt") scripts in $here/warm.txt"
