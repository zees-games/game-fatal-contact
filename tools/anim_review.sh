#!/usr/bin/env bash
# The animation review loop's capture step (docs/anim-review.md): plays every first-person clip of the named weapons, writes
# labelled contact sheets per weapon and clip (first person, behind-right, opponent), one side-by-side clip per animation
# (<weapon>/<clip>.mp4 at --fps, default 60) and a PASS/FAIL report from the glitch metrics.
#   tools/anim_review.sh <game-dir> <weapon[,weapon]|all> [--anim reload_empty[,draw]] [--avatar] [--fps 60] [--frames] [--soft] [--team red|blue] [--fit optic=holo,muzzle=suppressor]
# --team plays team deathmatch on that side, so the views show its team body (docs/client.md, Avatars).
# --avatar adds the locomotion clips (avatar_walk, _strafe, _run, _crouch, _crouch_walk, _jump) with the weapon held.
# Every clip's per-frame numbers go to <weapon>/<clip>_frames.tsv; a FAIL clip's (every clip's with --frames) are printed too.
# The capture runs through gs-game's visual QA driver (gs-game docs/visual-qa.md): on a GPU box through gpu.sh shot,
# through heavy here when no box takes it; run it as gamedev (who holds the box key) from the checkout or a ~/wt worktree. --soft keeps it
# here on software rendering (slower, same frames apart from lighting).
set -euo pipefail
game=${1:?usage: anim_review.sh <game-dir> <weapon|all> [--anim X] [--soft]}
weapons=${2:?usage: anim_review.sh <game-dir> <weapon|all> [--anim X] [--soft]}
shift 2
anims="idle,draw,holster,fire,ads,reload_empty,reload_tactical,sprint,inspect"
soft=0
frames=0
fps=60
avatar=0
team=()
fit=()
while (($#)); do
  case $1 in
    --anim | --anims) anims=$2; shift 2 ;;
    --soft) soft=1; shift ;;
    --avatar) avatar=1; shift ;;
    --fps) fps=$2; shift 2 ;;
    --frames) frames=1; shift ;;
    --team) team=(--team "$2"); shift 2 ;;
    --fit) fit=(--fit "$2"); shift 2 ;;
    *) echo "anim_review.sh: unknown argument $1 (weapons and clips are one comma list each: launcher,knife)" >&2; exit 2 ;;
  esac
done
# --avatar adds to whatever --anim names, in either order, and a clip named twice runs once.
((avatar == 0)) || anims="$anims,avatar_walk,avatar_strafe,avatar_run,avatar_crouch,avatar_crouch_walk,avatar_jump"
anims=$(tr , '\n' <<< "$anims" | awk 'NF && !seen[$0]++' | paste -sd,)
cd "$game"
out=screenshots/anim_review
log=$out/capture.log
rc=0
pick=()
[[ $weapons == all ]] || pick=(--only "$weapons")
drive=(--shot tools/anim_review_shot.sh --out "$out" --fps "$fps" --fresh "$weapons" --no-report)
[[ $soft == 1 ]] && drive+=(--soft)
# gs-game's driver routes the shot to a GPU box (heavy here when none takes it), files the clips as <weapon>/<clip>.mp4
# and leaves report.md to the report below.
bash addons/gs_game/tools/gs_game_visual_qa.sh "${drive[@]}" -- --anims "$anims" "${pick[@]}" "${team[@]}" "${fit[@]}" || rc=$?
python3 - "$out" "$log" "$frames" "$fps" <<'PY'
import json, math, os, sys
out, log, all_frames = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
fps = sys.argv[4]
rows, per_clip = [], {}
for line in open(log, errors="replace"):
    if line.startswith("ANIMREVIEW {"):
        rows.append(json.loads(line[len("ANIMREVIEW "):]))
    elif line.startswith("ANIMFRAMES {"):
        c = json.loads(line[len("ANIMFRAMES "):])
        per_clip[(c["weapon"], c["anim"])] = c["frames"]

PARTS = [("weapon", "wpn"), ("Middle1.R", "handR"), ("Middle1.L", "handL"), ("LowerArm.R", "foreR"), ("LowerArm.L", "foreL")]
HEAD = ["#", "t", "sw", "rl", "deploy", "wid", "turn"] + [n for _, n in PARTS] + ["hand_err", "isect", "near", "cut", "weapon_xyz"]

def step(a, b, key):
    if key not in a or key not in b or a.get("weapon_id") != b.get("weapon_id"):
        return ""
    return "%.3f" % math.dist(a[key], b[key])

def turn(a, b):
    if "weapon_q" not in a or "weapon_q" not in b or a.get("weapon_id") != b.get("weapon_id"):
        return ""
    d = min(1.0, abs(sum(x * y for x, y in zip(a["weapon_q"], b["weapon_q"]))))
    return "%.1f" % math.degrees(2 * math.acos(d))

def table(frames):
    """One row per frame; a step column is the move from the frame before, as the pop metric reads it."""
    out_rows = [HEAD]
    for i, f in enumerate(frames):
        p = frames[i - 1] if i else {}
        wid = "" if not i or p.get("weapon_id") == f.get("weapon_id") else "swap"
        g = lambda k: "" if k not in f else ("%.3f" % f[k] if isinstance(f[k], float) else str(f[k]))
        out_rows.append([str(i), "%.3f" % f["t"], "S" if f.get("switching") else "", "R" if f.get("reloading") else "", g("deploy"), wid,
            turn(p, f) if i else ""] + [step(p, f, k) if i else "" for k, _ in PARTS]
            + [g("hand_error"), g("intersect"), g("near"), g("cut"), ",".join("%.3f" % x for x in f.get("weapon", []))])
    return out_rows
lines = ["# Animation review", "", "fps: %s (sheets every %d frames; clips play every frame)" % (fps, max(1, int(fps) // 15)), "", "| weapon | clip | verdict | why | first person | behind-right | opponent | clip |", "|---|---|---|---|---|---|---|---|"]
fails = 0
skipped = [r for r in rows if "pass" not in r]
rows = [r for r in rows if "pass" in r]
for r in sorted(rows, key=lambda r: (r["weapon"], r["anim"])):
    base = os.path.join(out, r["weapon"], r["anim"])
    files = [base + "_fp_sheet.png", base + "_tp_sheet.png", base + "_op_sheet.png", base + ".mp4"]
    verdict = "PASS" if r["pass"] else "FAIL"
    fails += 0 if r["pass"] else 1
    why = "; ".join(r["fail"]) if r["fail"] else "worst " + ", ".join("%s %s" % kv for kv in r["worst"].items())
    lines.append("| %s | %s | %s | %s | %s |" % (r["weapon"], r["anim"], verdict, why,
        " | ".join(os.path.abspath(f) if os.path.exists(f) else "missing" for f in files)))
for r in sorted(skipped, key=lambda r: (r["weapon"], r["anim"])):
    lines.append("| %s | %s | %s | %s | | | | |" % (r["weapon"], r["anim"], "MISSING" if r["anim"] == "inspect" else "N/A", r.get("why") or r.get("status")))
lines += ["", "%d clips, %d FAIL, %d not playable" % (len(rows), fails, len(skipped))]
open(os.path.join(out, "report.md"), "w").write("\n".join(lines) + "\n")
for r in sorted(rows, key=lambda r: (r["weapon"], r["anim"])):
    frames = per_clip.get((r["weapon"], r["anim"]))
    if not frames:
        continue
    t = table(frames)
    os.makedirs(os.path.join(out, r["weapon"]), exist_ok=True)
    open(os.path.join(out, r["weapon"], r["anim"] + "_frames.tsv"), "w").write("\n".join("\t".join(row) for row in t) + "\n")
    if all_frames or not r["pass"]:
        width = [max(len(row[c]) for row in t) for c in range(len(HEAD))]
        print("\n== %s %s %s: %s" % (r["weapon"], r["anim"], "PASS" if r["pass"] else "FAIL", "; ".join(r["fail"]) or "clean"))
        for row in t:
            print("  ".join(v.rjust(w) for v, w in zip(row, width)).rstrip())
print("anim_review: %d clips, %d PASS, %d FAIL; report %s" % (len(rows), len(rows) - fails, fails, os.path.abspath(os.path.join(out, "report.md"))))
if not rows and not skipped:
    sys.exit("anim_review: nothing captured (see %s; llvmpipe crashes, so wait for a GPU box with GPU_SHOT_WAIT)" % log)
PY
exit $rc
