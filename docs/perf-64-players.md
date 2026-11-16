# FC at 64 players: measurements and plan

Measured 2026-11-16 on the GPU test box (RTX 2070, i7-8700K), windowed, editor binary (about 27% slower than a
release export), 1152x648, cp-orange-x3 CTF, `tools/perf_bench.sh -- --bots N --sim-host 1` (server as a child
process, so snapshots flow). n=1 per size; treat differences under 0.6 ms as noise. Raw logs: `~/perf-bench/`.

## Client frame

| Players | p50 ms | p95 | p99 | fps | Server tick |
| --- | --- | --- | --- | --- | --- |
| 16 | 6.2 | 9.2 | 11.0 | 155 | 66 Hz |
| 32 | 8.9 | 13.5 | 16.2 | 109 | 66 Hz |
| 64 | 14.2 | 21.6 | 25.9 | 69 | 33 Hz (solo tier `<=64:33`) |

Compat renderer (browser approximation, `--compat --web-defaults 1`): 32 players p50 10.3 ms (p95 14.8),
64 players p50 12.7 ms (p95 18.7). Compat render_cpu is 2.0-2.4 ms against 0.9-1.2 ms in Forward+.
The frame is main-thread script bound, not GPU bound.

## Per-system ms per frame (16 / 32 / 64 players)

| System | 16 | 32 | 64 |
| --- | --- | --- | --- |
| phase.script | 3.73 | 5.32 | 9.05 |
| arena.present | 1.57 | 2.65 | 5.27 |
| phase.physics | 0.96 | 1.87 | 2.72 |
| arena.bodies | 0.59 | 1.08 | 2.43 |
| phase.render | 1.36 | 1.54 | 1.92 |
| engine.physics_outside_game | 0.41 | 1.01 | 1.91 |
| arena.interpolate | 0.45 | 0.85 | 1.67 |
| arena.net_snapshot | 0.16 | 0.40 | 1.15 |
| render_gpu | 1.33 | 1.68 | 2.75 |
| arena.r_anim | 0.24 | 0.35 | 0.75 |
| arena.c_rest | 0.22 | 0.35 | 0.70 |
| arena.c_killcam | 0.09 | 0.21 | 0.54 |
| arena.r_held | 0.05 | 0.15 | 0.50 |
| arena.predict | 0.37 | 0.57 | 0.50 |
| arena.r_held_fired | 0.01 | 0.04 | 0.25 |
| arena.r_tag | 0.03 | 0.09 | 0.20 |
| arena.r_pose | 0.02 | 0.07 | 0.16 |
| arena.audio | 0.01 | 0.02 | 0.03 |

Scene: draw calls 525 / 528 / 682, primitives 184k / 188k / 443k, nodes 3558 / 4617 / 6849 (about 70-80 nodes per
remote player), objects 871 / 877 / 1132. Primitives grow about 4k per added player; 8-12k triangle avatars will
multiply that, so body LOD is the first dependency.

## Server tick (child process, ms per tick)

| Players | Hz | sim ms/tick | Share of budget | send ms/tick |
| --- | --- | --- | --- | --- |
| 16 | 66 | 6.1 | 40% | 0.39 |
| 32 | 66 | 10.7 | 70% | 0.57 |
| 64 | 33 | 23 | 76% | 2.0 |

At 64 players the server uses three quarters of a 33 Hz tick and could not hold 66 Hz (PH scale128, about 2x slower
than the GPU box: 36.6 ticks/s at 26.6 ms/tick). Breakdown there: srv_net 27, srv_game 17.6, tick_players 16.4,
srv_bots 7.3, p_controller 6.8, bot_brain 3.3, p_weapons 3.3, bot_los 1.4. Hit reg, lag comp, p_controller and
p_weapons are authoritative sim and are not candidates; the levers are the net layer, bot scheduling and tiers.

## Snapshot cost (net_probe, `--bots N --fake N`, ms per snapshot, 4 workers)

| Clients | prepare | begin | nint | submit | join | apply | bytes per fake client per snapshot |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 16 | 0.16 | 0.55 | 0.25 | 0.17 | 0.20 | 0.37 | 212 |
| 32 | 0.20 | 0.98 | 0.46 | 0.25 | 0.53 | 0.35 | 317 |
| 64 | 0.26 | 1.92 | 0.91 | 0.45 | 1.90 | 0.91 | 623 |

Per-client bytes roughly triple from 16 to 64 clients, and begin/join grow superlinearly: this is where interest
management (`sv_net_aoi_players`, currently above 32) pays. At 64 players 623 B x 33 Hz is about 20 KB/s per
client down.

### Interest at 64 (fc-64p-3)

The rows above use fakes with no entity of their own, so interest never applied to them: 623 B is the cost with
no relevance at all. `net_probe` now gives each fake an eye riding a player (`--fake`), adds blind fakes in the
same run as a control (`--control N`, printed as `CONTROL eyed_bytes_per_snapshot=... control_bytes_per_snapshot=...`),
and takes `--map <id>`, `--port N` (parallel runs) and a sixth `--aoi` field (coherent). Same-run eyed/control
pairs cancel the fight-to-fight noise that made two separate runs differ by 50%. 64 bots, 56 eyed + 8 control
fakes, 30 s, PH (timings there are noise; bytes are not):

| Map | sv_net_far_every / tiers / far m | eyed B | control B | real client B/s |
| --- | --- | --- | --- | --- |
| dm_atrium | rings off (aoi_players 9999) | 637 | 637 | 8152 |
| dm_atrium | 1 / - / - | 616-620 | 616-619 | 8317-8634 |
| dm_atrium | 2 / 2 / 40 (old default) | 801-812 | 617-636 | 12772-13893 |
| dm_atrium | 2 / 1 / 40 | 831 | 619 | 12526 |
| dm_atrium | 2 / 2 / 40, staggered | 829 | 620 | 12305 |
| dm_atrium | 3 / 1 / 40 | 509 | 620 | 6799 |
| dm_atrium | 4 / 1 / 40 | 664 | 620 | 8670 |
| cp-orange-x3 | rings off | 309 | 547 | 5230 |
| cp-orange-x3 | 1 / - / - | 309 | 547 | 5193 |
| cp-orange-x3 | 2 / 2 / 40 (old default) | 307-308 | 547-556 | 4818-5690 |
| dm_atrium | 1 / - / - (thinned-ack sync) | 635 | 635 | - |
| dm_atrium | 2 / 2 / 40 (thinned-ack sync) | 560 | 635 | - |
| cp-orange-x3 | 1 / - / - (thinned-ack sync) | 307 | 555 | - |
| cp-orange-x3 | 2 / 2 / 40 (thinned-ack sync) | 283 | 523 | - |
| dm_atrium | 2 / 2 / 40, before fc-dmatrium-bytes-1 (rerun) | 541-549 | 616 | - |
| dm_atrium | 2 / 2 / 20 | 404 | - | - |
| dm_atrium | 2 / 3 / 15 | 343 | - | - |
| dm_atrium | 3 / 2 / 25 | 389 | - | - |
| dm_atrium | 2 / 2 / 40 + sub-quantum hold | 498 | 563 | - |
| dm_atrium | 2 / 1 / 20 + sub-quantum hold (old default) | 406-411 | 559-562 | - |
| dm_atrium | 2 / 1 / 15 + sub-quantum hold | 382 | - | - |
| dm_atrium | 2 / 1 / 10 + sub-quantum hold | 371 | 540 | - |
| dm_atrium | 2 / 2 / 20 + sub-quantum hold (fails headless_hitreg_scope) | 341-347 | 528-547 | - |
| dm_atrium | 2 / 2 / 15 + sub-quantum hold (fails headless_hitreg_scope) | 302 | 562 | - |
| dm_atrium | 2 / 2 / 20 + hold, aim cone 0 (rerun, fc-dmatrium-bytes-2) | 354 | - | - |
| dm_atrium | 2 / 2 / 20 + hold, aim cone 8 | 356 | - | - |
| dm_atrium | 2 / 2 / 15 + hold, aim cone 0 | 323 | 546 | - |
| dm_atrium | 2 / 2 / 15 + hold, aim cone 8 (default) | 326 | 545 | - |
| dm_atrium | 2 / 2 / 12 + hold, aim cone 8 | 298 | 644 | - |
| dm_atrium | 2 / 2 / 10 + hold, aim cone 10 | 278 | 544 | - |
| cp-orange-x3 | 2 / 2 / 40 + sub-quantum hold | 271 | 485 | - |
| cp-orange-x3 | 2 / 1 / 20 + sub-quantum hold (old default) | 260 | 483 | - |
| cp-orange-x3 | 2 / 2 / 15 + hold, aim cone 8 (default) | 217 | 463 | - |
| cp-orange-x3 | 2 / 2 / 20 + sub-quantum hold | 258 | 518 | - |

Before dotnet-thin-ack-sync, far-ring thinning cost bytes: at far_every 2 a peer got about 30% more than with no
thinning. The cause was in dot-net: a per-peer view was synced to the peer's acks only while its entity was in the
snapshot, so with wired (strict) acks a thinned entity's pending fields were older than `last_ack` when it came back,
counted as lost (`relost`) and went out again. dot-net now keeps a per-peer ring of acked ticks and promotes any send
whose own snapshot was acked (no wire change). With that, the rings save bytes (rows marked "thinned-ack sync", same
probe, 2026-11-16): dm_atrium 560 B against 635 unthinned, cp-orange-x3 283 against 307. `sv_net_far_every` defaults
to 2 again (tiers 2, 40 m). On cp-orange-x3, the map 64 players are for, a peer is at 283 B against 523 unfiltered,
under the 350 B goal; small DM maps stay near 560 B because most players there are within 40 m and in view.

**dm_atrium bytes (fc-dmatrium-bytes-1, 2026-11-16).** `net_probe --fields` counts what each changed field costs
before interest, and how much of it a receiver could tell apart (`FIELDS wire ...`, only changes whose quantised code
moved). On dm_atrium every peer is a player (65 entities, about 33 changed a snapshot): position 153 B, the 36-bit entity
headers 158, velocity 108, yaw 78, pitch 64, flags 40. 61% of pitch writes, 8% of yaw and 7% of velocity carried the
same codes as the last send: dot-net marks a field dirty on any raw change. `ArenaPlayerNet.hold_subquantum`
(`sv_net_hold_subquantum`, default 1) keeps the previous value when the new one quantises the same, so receivers decode
exactly what they did and the repeat is not sent; position is not held (the server reads it back), and neither lag-comp
history nor the owner's rewind (`net_exact`) reads these fields. That alone took the unfiltered control from 616 B to
528-563, and dm_atrium at the old rings from 541-549 to 498.

The rest is distance: 70% of player pairs on dm_atrium are 10-50 m apart (`FIELDS pair distances`), so a 40 m band
thinned almost nobody. A quarter-rate band is what reaches 350 B (20 m with two tiers: 341-347), but a scoped shot at
60 m drawn from every fourth snapshot misses the rewind tolerance (`headless_hitreg_scope`: marksman and sniper worst
0.10-0.20 m against 0.025). The default is therefore one band, `sv_net_far_distance` 20 and `sv_net_far_tiers` 1: full
rate to 20 m, every second snapshot to 120 m (the half rate the scope suite already held at 40-80 m). dm_atrium is at
406-411 B against 541-549, cp-orange-x3 at 260 against 283. The last ~60 B to 350 on small DM maps needs either a
quarter rate that leaves scoped targets alone (an observer-aware tier in dot-net interest) or cheaper observer velocity;
both are on the nightly board.

**Aim cone (fc-dmatrium-bytes-2, 2026-11-16).** dot-net interest (API 22) takes an observer aim,
`DotNetIdentity.interest_aim`, and `DotNetInterest.aim_cone_deg`: a far entity inside that cone of the observer's aim
is sent at most every `far_every`-th snapshot (the first band's rate), never the quarter rate; native core and GDScript
agree (netcode_demo parity). FC's authority sets `interest_aim` from `ArenaPlayer.aim_direction()` each pull, and
`sv_net_aim_cone` (default 8 degrees, 0 = off, outside 0-180 refused) sets the cone. What you aim at, scoped or not,
stays at half rate, so the quarter band no longer reaches a scoped shot: the default is now two bands from 15 m
(`sv_net_far_distance` 15, `sv_net_far_tiers` 2), and `headless_hitreg_scope` passes with the rings on at 30 m and
60 m. dm_atrium is at 326 B against 406-411 (the cone itself costs about 3 B), cp-orange-x3 at 217 against 260.

## Ranking (64 players)

1. Server tick (23 ms of 30 ms): bot scheduling and bot threads, snapshot begin/join, tick tiers.
2. Remote player present + bodies + interpolate (about 9.4 ms of 14.3): per-player node count, anim and body LOD, instancing.
3. Engine physics outside game (1.9 ms) and phase.physics (2.7): per-player collision nodes.
4. Snapshot apply on the client (1.15 ms): native apply hooks.
5. Rendering: GPU 2.75 ms and primitives (443k) grow with avatar triangle count; compat render_cpu doubles.
6. Killcam recorder 0.54 ms, held weapons 0.5+0.25 ms, tags 0.2 ms.

Not measured as separate rows: audio (0.03 ms, negligible), decals/gibs (no 64-player combat load in the bench), GC.

## Status

This pass measured only. No code change landed: the one safe candidate found (scaling `cl_killcam_hz` by player
count, 0.54 to about 0.27 ms) is under the 0.6 ms gate and was left for the board. Follow-ups are nightly items
`fc-64p-1` to `fc-64p-8`.
