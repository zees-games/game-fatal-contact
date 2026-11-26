#!/usr/bin/env bash
# Run before `git tag` on Fatal Contact (docs/testing.md#before-a-tag). Two gates, both must pass:
#   1. gs-ci's scripts/pre-tag.sh: builds the pack the tag would build, check-pack-static.py and server-compat strictly.
#   2. tools/perf_gate.sh --tier windowed: the 32-player client bench on staging02, medians of 3 against
#      ci/perf/client_gate_windowed.json (20 to 40 minutes with the GPU queue).
#   tools/pre_tag.sh [--no-pack] [--no-perf] [-- perf_gate args]
# GS_CI names the gs-ci checkout (default: the sibling ../gs-ci, else ~gamedev/godot/gs-ci).
# Exit 0 both pass; otherwise the first failing gate's code (perf_gate: 1 regression, 2 missing data, 3 not comparable).
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
pack=1 perf=1
while [[ $# -gt 0 ]]; do
	case $1 in
		--no-pack) pack=0; shift ;;
		--no-perf) perf=0; shift ;;
		--) shift; break ;;
		*) echo "pre_tag: unknown option $1" >&2; exit 2 ;;
	esac
done
if [[ $pack == 1 ]]; then
	ci=${GS_CI:-}
	[[ -n $ci ]] || for c in "$here/../gs-ci" /home/gamedev/godot/gs-ci; do [[ -x $c/scripts/pre-tag.sh ]] && { ci=$c; break; }; done
	[[ -n $ci && -x $ci/scripts/pre-tag.sh ]] || { echo "pre_tag: no gs-ci checkout (set GS_CI)" >&2; exit 2; }
	echo "pre_tag: pack gates ($ci/scripts/pre-tag.sh)" >&2
	GODOT=${GODOT:-godot} "$ci/scripts/pre-tag.sh" "$here" || { rc=$?; echo "pre_tag: FAIL pack gates (exit $rc)" >&2; exit "$rc"; }
fi
if [[ $perf == 1 ]]; then
	echo "pre_tag: client perf gate (windowed, staging02)" >&2
	timeout "${PRE_TAG_PERF_TIMEOUT:-3600}" bash "$here/tools/perf_gate.sh" --tier windowed "$@" || { rc=$?; echo "pre_tag: FAIL client perf gate (exit $rc)" >&2; exit "$rc"; }
fi
echo "pre_tag: PASS" >&2
