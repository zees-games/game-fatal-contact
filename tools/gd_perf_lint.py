#!/usr/bin/env python3
"""The GDScript performance gate over this game's hot scripts: gs-ci's scripts/check-gd-perf.py.

    tools/gd_perf_lint.py [--by-file] [--update] [--top N] [--no-baseline]

The hot list is ci/efficiency/gd-perf-hot.txt, the ratchet ci/efficiency/gd-perf.tsv (only
shrinks: fix a site, then --update). gs-ci is found at $GS_CI_DIR, next to this repository, or
/home/gamedev/godot/gs-ci; this file is a launcher, never a copy of the checker.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def find_checker():
    for d in (os.environ.get("GS_CI_DIR", ""), os.path.join(os.path.dirname(ROOT), "gs-ci"),
              "/home/gamedev/godot/gs-ci"):
        p = os.path.join(d, "scripts", "check-gd-perf.py") if d else ""
        if p and os.path.isfile(p):
            return p
    return None


def main():
    checker = find_checker()
    if checker is None:
        print("gd_perf_lint: gs-ci scripts/check-gd-perf.py not found (set GS_CI_DIR); not checked", file=sys.stderr)
        return 0
    return subprocess.call([sys.executable, checker, *sys.argv[1:], ROOT])


if __name__ == "__main__":
    sys.exit(main())
