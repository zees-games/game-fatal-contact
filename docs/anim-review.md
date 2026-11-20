# Animation review

How to find and fix glitches in fc-weapons' first-person and third-person animations (reload, draw, holster, fire, arms) and the avatar's locomotion by looking at them. A check can only flag a problem; the sheets and clips are what you judge. The question for every clip is: **does this look like a real game?**

This was the pilot of the family's visual QA loop and now runs on it: dot-game's visual QA harness (dot-game `docs/visual-qa.md`) holds the views (`DotGameVisualQaViews`), the shot tool that makes the sheets and clips, the driver that routes the capture to a GPU box and the post tool. FC keeps only what knows FC: `tools/anim_review.gd` (the offline client, the weapon lab, the grip and muzzle numbers) and the report in `tools/anim_review.sh`. `tools/anim_review_shot.sh` and `tools/anim_review_post.sh` are one-line wrappers. Another game adopts the loop from the dot-game doc, never by copying these scripts.

## The loop

1. Capture: `tools/anim_review.sh . <weapon[,weapon]|all> [--anim reload_empty,draw] [--avatar] [--fps 60] [--frames]`, run as gamedev from the checkout or a `~/wt` worktree (`sudo -u gamedev env WT_ROOT=$HOME/wt tools/anim_review.sh . rifle`; the script puts gamedev's `bin` dirs on PATH itself). A run replaces only the named weapons' sheets; the others' stay. The default clips are idle, draw, holster, fire, ads, reload_empty, reload_tactical, sprint and inspect; `--avatar` adds avatar_walk, avatar_strafe, avatar_run, avatar_crouch, avatar_crouch_walk and avatar_jump (the player moving with the weapon held, driven through the real input actions).
2. Read `screenshots/anim_review/report.md`: one row per weapon and clip with PASS, FAIL, N/A (the weapon has no such clip: no magazine, no sights) or MISSING (fc-weapons below API 21, which has no inspect), the failing metrics with their frame numbers, and the paths of the three sheets and the clip.
3. Judge with a fresh judge, never by your own reading: `bash addons/dot_game/tools/dot_game_visual_judge.sh --clips screenshots/anim_review --only <weapon> --anims <clips> --capture 'tools/anim_review.sh . <weapon> --anim <clips>'` (output in `screenshots/anim_review/judge`, where step 7's post tool reads `verdict.json`; `--capture` recaptures every pass, so each of the three passes sees fresh frames; dot-game `docs/visual-qa.md#the-judge-loop`). It builds full-resolution stills and a delta strip for every camera and writes `verdict.json` from the rubric (dot-game `docs/visual-judge-rubric.md`). The report's PASS/FAIL is only a pre-filter.
4. Fix each defect in `verdict.json` where it lives: the weapon pose and rig in fc-weapons (`view/aw_weapon_pose.gd`, `view/aw_view_model.gd`, `runtime/aw_weapon_rig*.gd`, the art row in `aw_weapon_art.gd`), the arms and grip in dot-player-char (`DotPlayerViewArms`, `DotViewGrip`), or one weapon's numbers in its def. Never fix a defect by moving a camera or cropping. Work in a `~/wt` worktree of that addon with a board claim, and link the worktree's addon into your game worktree for the run.
5. Capture again and judge again with a new judge. Repeat until the judge exits 0 (production_ready). There is no round cap. If you must stop with defects open, rerun the judge with `--give-up`: it files one nightly item per open defect and exits 3.
6. Run the game's suites (`./game.sh test`) once before committing an addon change.
7. Record what the judge saw as nightly notes on the item you work, and post the judged clips to a review item (the post tool refuses a clip with no passing or filed verdict, and posts the verdict as its look text): `tools/anim_review_post.sh <review-key> --variant before [--fails]` before the fix and `--variant after --only <weapon> --anims <clip>` after it, so the owner sees the pair. Create the item once per pass (`nightly review new "FC animation review <date>" --key fc-anim-<date>`).
8. File a nightly item per weapon for anything left, naming the clip, the frame numbers and the sheet. Never leave a finding only in a doc or a commit message.

The loop is recursive: a fix is done when a fresh judge says production_ready on the re-captured clips, not when the metric passes and not when the author thinks it looks right.

## What it captures

`tools/anim_review.gd` extends `tools/weapon_lab.gd`. For each weapon the offline client is built, the weapon is put in hand on a flat floor, and each clip is played at a fixed rate, 60 frames a second by default (`--fps`, at least 15; the clips' timings are written for 30 and scale, so a clip covers the same seconds at any rate). Every frame saves three images:

- first person: the client's own camera, the arms and the view model, with your own body left out;
- third person: a fixed camera 2 m behind and to the right of the player, looking at the waist, showing the whole figure with the gun in its hands as other players see it;
- opponent: a fixed camera 4 m in front and slightly to the side at eye height, looking back at the player, as the enemy sees the muzzle flash and the hands.

`tools/anim_review_shot.sh` (dot-game's `dot_game_visual_qa_shot.sh`) turns the frames into contact sheets with ffmpeg (`<clip>_fp_sheet.png`, `_tp_sheet.png`, `_op_sheet.png`): 15 cells a second (every fourth frame at 60 fps), eight to a row, each cell labelled `#<frame> <seconds>s`. It also writes one clip per animation, `<weapon>/<clip>.mp4`: the three views side by side (1920x540), every frame, at the capture rate, with the frame index burnt in. The frames themselves are deleted.

The nightly review viewer plays a posted clip at its own rate and steps one frame per 1/fps (read from the file; `anim_review_post.sh` also posts it as the `fps` metric). A browser shows at most the display's refresh rate, so a 60 fps clip plays at full rate on a 60 Hz or faster screen; step frame by frame for anything finer. Sheets show 15 frames a second: a one-frame pop at 60 fps can fall between cells, which is what the clip and the per-frame table are for.

A draw or holster is a real switch (`DotWeaponArsenal.select`, the holster then the deploy, as a slot key does), never `equip`, which is the spawn hand-out and swaps instantly. The draw starts from another slot (often a grenade), so its first frames show that weapon going down.

## Where it runs

- `anim_review.sh` calls dot-game's `dot_game_visual_qa.sh`, which hands `tools/anim_review_shot.sh` to a GPU box (staging or staging02) with `gpu.sh shot --route --pull <clips dir>`, which needs gamedev's box key and brings the sheets and the clips back; when no box takes it (exit 75) it runs through `heavy` here. gpu.sh may print "could not copy the frames back" because the frames are already deleted; the sheets still arrive.
- If rsync cannot write into `screenshots/`, make the folder writable for gamedev first (`chmod -R a+rwX screenshots`).
- `--soft` keeps it on the local machine with software rendering. On dev02 that build crashes (signal 11 in llvmpipe), as `weapon_lab.gd` does too, so use the GPU route.
- One weapon with one clip takes 1 to 3 minutes; every weapon with every clip takes much longer. Run it in the background and poll.

## The metrics

Every frame is sampled just before it is drawn. Each clip's verdict, with every frame's numbers, is in `<weapon>/fp_<clip>_metrics.json` when the capture ran locally; the GPU route brings back only the sheets and the log, so every clip also prints an `ANIMFRAMES` line with the per-frame numbers. `anim_review.sh` turns those into `<weapon>/<clip>_frames.tsv` and prints the table for every failing clip (every clip with `--frames`): switch (`sw`), reload (`rl`) and deploy state, the weapon's swap id, and each frame's step from the previous one for the weapon, both hands and both forearms, plus hand error, intersection, near-plane and cut. A pop reported "at #n" is the step from frame n-1 to frame n.

| Metric | Fails when | What it usually is |
| --- | --- | --- |
| pop (`<part> jumps … m at #n`) | a hand, an elbow or the weapon moves more than 0.04 m in one frame (0.09 m in a fire clip, where each shot kicks the gun by design), and more than 3 times as far as in the frames on either side | a missing key, a pose snapping between two blends, a reload phase starting from the wrong place |
| turn (`weapon turns … deg at #n`) | the weapon turns more than 25 degrees in one frame, 3 times its neighbours | the same, in rotation |
| hand off grip | a hand more than 0.06 m from its grip point | IK not reaching, a grip point wrong for this weapon |
| forearm inside weapon | the forearm (elbow to just short of the wrist) more than 0.03 m inside one part of the weapon (receiver, scope, magazine); the air under a scope does not count | the hands placed too far forward or the weapon too close |
| arm through near plane | any visible arm point closer than the near plane plus the arm's radius | the arms clipped open at the screen edge |
| gun held far out | the settled weapon (no swap, deploy done) more than 1.0 m in front of the eye in camera space | the view model's `hands_depth_comp` giving a narrow `viewmodel_fov`'s size back as distance (`cl_fp_hold_depth`), so the gun draws small behind arms a quarter metre away |
| weapon through near plane | the weapon cut more than 0.005 m by the near plane | a muzzle or stock poking through the camera |
| wrong hand | the left hand nearer the main grip than the right by more than 4 cm for more than 2 frames (the left hand working a magwell beside the grip comes within 3 cm; mirrored arms are 15 cm or more apart) | mirrored arms, a swapped grip |
| T-pose | the upper arm straight out sideways and level in a frame, for an arm with some of its forearm on screen (the free arm of a one-handed weapon hangs out of view) | IK not applied, a missing skeleton pose |
| weapon drawn without arms | the model shown, not scoped, with no arms holding it, for more than 3 frames | the arms losing the weapon after a swap |
| no draw / holster motion | the deploy fraction never goes below 0.9 in a draw or holster | an instant swap with no animation |
| muzzle in front / inside / beside the gun | in a settled fire frame, the muzzle point (where the flash and tracer start) more than 0.10 m in front of the barrel's end, 0.10 m back inside the gun, or 0.03 m beside its outline, measured against the view model's mesh bounds in camera space | a muzzle offset in the def or the art table that does not match the model, a model swapped without its muzzle |
| avatar did not move | a walk, strafe or run clip moved the player less than 0.5 m | input not reaching the controller, the player stuck in the floor |
| tp body pop | dot-core's `DotClipMetrics` bone pop on the third-person figure | the body snapping between animations |

Thresholds are written per frame at 30 fps: a pop or turn limit halves at 60 fps (half the time between frames), and a frame count (wrong hand, hidden) doubles.

The pop checks skip the frame where the weapon node changes and the hands' regrip in the frame after it, so a swap is not a pop, and a hand jump off screen in both frames (the free hand of a one-handed weapon going to rest). A loop discontinuity shows as a pop where the clip wraps (idle, sprint).

## The defect checklist

Read the first-person sheet left to right as a flip book, then the behind-right and opponent sheets. Ask whether it looks like a real game, and look for:

- a cell that does not follow from its neighbours (a pop the threshold missed);
- the gun or a hand cut off at the edge of the screen;
- an arm passing through the gun, or a hand floating off it;
- the hands crossing to the wrong side, or a left arm holding the trigger;
- arms straight out (a T-pose), or arms with no gun;
- a reload that never takes the magazine out, or puts it back in the wrong place;
- a draw or holster with no motion, or a gun that ends somewhere other than where idle holds it;
- in third person, the gun out of the hands, held at the knee, or pointing away from where the player looks;
- clipping arms: a forearm or hand through the gun, the body or the camera;
- floating hands: a hand a few centimetres off the grip or the magazine it is meant to hold;
- finger grip: fingers through the grip, open in the air, or the trigger finger not near the trigger;
- wrong muzzle flash origin: the flash or tracer starting behind the barrel's end, inside the gun, beside it, or (opponent view) from the body instead of the gun;
- texture stretching: a texture smeared along one axis, a seam, a face with no texture, a material that is plain white or magenta;
- animation pops: one cell that jumps out of the motion, a loop that snaps where it wraps (idle, sprint, walk);
- in the avatar clips, feet sliding over the floor, legs not moving while the body moves, the gun dropping out of the hands while running or jumping, or the camera passing through the body.

Frame 0 of a third-person sheet can show the scene before the camera is placed; ignore it.

## The horde monsters

`tools/visual_qa.gd` (`tools/visual_qa_shot.sh`, a `DotGameVisualQaCapture`) records each monster kind in `npcs/` (grunt, gunner, brute, stalker) idling, walking and running a circle: the victim's eye, behind-right and the opponent view at 60 fps. Run it with dot-game's driver: `bash addons/dot_game/tools/dot_game_visual_qa.sh --shot tools/visual_qa_shot.sh --fresh grunt -- --only grunt`, then read the sheets against the same checklist.
