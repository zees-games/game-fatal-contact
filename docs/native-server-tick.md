This doc plans how gs-sim takes over the whole FC server tick, the way Source's `server.so` owns its own. It starts with an audit of every native path that exists today, then splits the 19.6 ms tick by who owns each part, then lays out phases that can each land on their own. Comparison numbers already in the repo are linked, not repeated: [source-server-comparison.md](source-server-comparison.md), [css-dedicated-server-baseline.md](css-dedicated-server-baseline.md), [perf-vs-css.md](perf-vs-css.md), [perf-architecture.md](perf-architecture.md) and [sim-thread.md](sim-thread.md).

## Why it is slow (summary)

Native code was never switched off. Every FC native cvar defaults on, and the sim host takes the native path: `SIM_HOST ready brain=native loop=native`, and PH logs show `gs-sim: native motor_tick=full motor=on bots=on snapshot=on`. The 19.6 ms comes from how the tick is built:

1. A GDScript loop runs over 32 entities and calls dozens of small natives per entity. Every crossing marshals Variants, and the glue between the calls costs more than the calls do.
2. The native motor (`gs-sim-gdext/src/motor.rs:238 cast_motion`, `:253 get_rest_info`, `:291 intersect_ray`) still asks Godot's PhysicsServer for every sweep on mesh maps. Bot sight and nav also cast PhysicsServer rays (`fc_bots_world.gd:636`, `fc_bots_world_nav.gd:122`), as do `fc_player.gd:278`, `fc_touch.gd:211` and `fc_surf.gd:273`. One FC ray costs about 22 us. One CS:S `CM_BoxTrace` costs about 0.8 us.
3. Each leaf port saves 0.1-0.6 ms. An n=3 A/B has about +-1 ms of noise, so a port that helps can still read as "no gain" (for example fc-srvgame-split2: srv_game 11.52 against 12.25).

## Part 1: native path audit

| Path / cvar | Where | Default | Sim host takes it | History |
|---|---|---|---|---|
| bot_fast_sense, bot_threads, bot_native, bot_native_pickup, bot_native_act, bot_native_think | `game/fc_engine_cvars.gd:19-156` | on | yes (`brain=native`, bot_threads=4) | never flipped |
| bot_native_brain | same file | on | yes | **off** in f273376f (2026-11-12) after a staging02 n=5 A/B read +2.4% (noise), and because the native brain then dropped bot_threads. **Back on** in 3f2c3175 (2026-11-16) |
| motor_native, motor_native_tick, motor_native_full | same file | on | yes (`motor_tick=full`) | never flipped in FC |
| gs-player-controller native_tick | addon | on | yes | started false in 727ca7e (2026-11-09), on in 8010d24 (2026-11-12, API 27) |
| net_pack_native, ctl_native, ragdoll_native (client) | same file | on | n/a for ragdoll | never flipped |
| fc_hull_grid, fc_hull_fast, fc_hull_native, fc_motor_batch, fc_bot_pvs, fc_bot_pvs_native, fc_spawn_native, fc_posture_native, fc_mechanics_native | same file | on | yes | never flipped |
| sv_net_pull_native | `game/fc_module_cvars.gd:655` | on | yes | never flipped |
| sv_net_pull_weapons_native, sv_net_pull_content_native | `game/fc_net_pull_weapons.gd:30,33` | on | yes | never flipped |
| gs-bot, gs-player-controller motor_batch, gs-weapon hitscan, gs-net switches | addons | on | yes | never flipped |

**Lib against pin.** FC origin/main pins gs-sim v0.2.34. The shared lib stamp (`gs-sim/addons/gs_sim/bin/.natives-linux-x86_64`) says v0.2.33, and gs-sim HEAD is 06cc482 (v0.2.35). `hv/gpu.sh` rsyncs with `--copy-links`, so PH and staging run whatever the local symlink points to, which is v0.2.33. hv prints a warning but goes on (`/home/christian/wt-scripts/srvhot/prof.log`: "gs-sim library is v0.2.33 but this checkout pins v0.2.34"). v0.2.33..v0.2.35 adds:

- GSSimUnlagRing (8286134);
- GSSimBotMind.pickup_choose, steer_step and unstick_step;
- GSSimBotDrops.pack and fill_arms.

On the boxes these quietly fall back to GDScript through `class_has_method` (for example `gs_bot_unstick.gd:129`), and the ready line does not show it. The FC main checkout and the other games' checkouts still pin v0.2.12.

## Profile split of the 19.6 ms

Source: `/home/gamedev/perf-bench/20261126-215037-ph-fc-srvgame-split2-A-headless.log`, PH, 31 bots, SIM_HOST_TICK p50 19.59 ms, 45.9 ticks/s.

**Top level:**

| Section | ms |
|---|---|
| srv_net (whole tick) | 19.705 |
| srv_game | 12.110 |
| srv_bots | 5.425 |
| srv_netpull | 0.968 |
| send | 0.480 |
| input, check, rest | 0.37 |
| srv_killview | 0.349 |

**Inside srv_game:**

| Section | ms | Inner sections |
|---|---|---|
| tick_players | 9.925 | pl_sim 6.326; tb_pass2 6.765; tb_pass1 2.663 |
| p_controller | 2.529 | pc_* adds up to only about 0.53, pc_motor 0.000 |
| p_weapons | 2.017 | pw_arsenal 1.122 |
| pb_head | 1.231 | |
| pl_pre | 0.869 | |
| pl_post | 0.874 | |
| p_mechanics | 0.539 | |
| tick_shots | 1.283 | s_resolve 1.151 |
| srv_pre | 0.979 | |
| tick_world | 0.436 | |

**Inside srv_bots:**

| Section | ms | Notes |
|---|---|---|
| bot_brain | 2.164 | worker wall time |
| sb_begin | 1.984 | |
| sb_finish | 0.995 | |
| bot_refresh | 1.028 | |
| br_contacts | 0.874 | |
| c_finish | 0.937 | |
| bq_walkable | 0.444 | 11 rays |

No server-side script profile or native profile exists yet: `top.py` and `script_functions` cover only the client. So this split is an estimate, made by which code owns each section:

| Owner | ms | Share | How estimated |
|---|---|---|---|
| Native Rust compute | 1.5-2.5 | about 10% | motor batch about 20 us per player-tick x 32 = 0.65 ms (controller end_tick 20.2-20.7 us), native perceive and act on the bot workers, netpull pack |
| Engine calls | 1-2 | about 8% | PhysicsServer casts from the native motor and bot rays, Node and Transform access |
| GDScript orchestration and marshalling | 14-16 | 75-80% | everything else: per-entity loops, the glue between native calls, event plumbing |

CS:S does the same work in 2.20 ms per tick: 1.115 ms of bots (36 us per bot-tick), 0.8 us per BoxTrace, 1.74 us per `IsVisible(pos)`.

## Part 2: target architecture

gs-sim owns the server tick the way `server.so` does. Each tick makes one batched call in and one out:

```
inputs (PackedByteArray: usercmds + server events)
  -> GSSimServerTick.step(dt)
       run commands (CGameMovement on the collision mirror)
       bot think (rayon over the bot table, reads a frozen snapshot)
       shots + lag comp (unlag ring, hull traces on the mirror)
       triggers / pickups / damage -> event list
       snapshot pack per client (PVS on the mirror)
  -> outputs (PackedByteArray: events + per-client snapshots)
```

GDScript keeps the work that is events and presentation: game mode rules, spawning scene nodes, sounds and effects, chat, admin, and RPC delivery. Player and bot state lives in Rust struct-of-arrays tables. Nodes on the dedicated server become optional mirrors, written once per tick only if a game script asks for them.

### Source files mirrored

| Concern | Source file:function |
|---|---|
| Frame driver | `game/server/gameinterface.cpp:1177 CServerGameDLL::GameFrame`, `game/server/physics_main.cpp:2019 Physics_RunThinkFunctions` |
| Command run | `game/server/player.cpp:3195 PhysicsSimulate`, `:3651 PlayerRunCommand`; `game/server/player_command.cpp:314 RunCommand`, `:132 SetupMove`, `:205 FinishMove` |
| Movement | `game/shared/gamemovement.cpp:1133 ProcessMovement`, `:4548 PlayerMove`, `:2025 FullWalkMove`, `:1895 WalkMove`, `:1753 AirMove`, `:1822 Accelerate`, `:1612 Friction`, `:1517 StepMove`, `:2560 TryPlayerMove`, `:3774 CategorizePosition`, `:4333 Duck`, `:774 TracePlayerBBox`; `game/shared/cstrike/cs_gamemovement.cpp` |
| Collision | `engine/cmodel.cpp:462 CM_PointLeafnum`, `:2098 CM_BoxTraceAgainstLeafList`, `:2182 CM_BoxTrace`; `engine/cmodel_bsp.cpp`, `engine/cmodel_disp.cpp`, `engine/cmodel_private.h`; `engine/enginetrace.cpp:1661 CEngineTrace::TraceRay` |
| Bots | `game/shared/cstrike/bot/bot_manager.cpp:57 CBotManager::StartFrame`; `game/server/cstrike/bot/cs_bot_update.cpp:28 Upkeep`, `:240 Update`; `cs_bot_vision.cpp:327 IsVisible(pos)`, `:360 IsVisible(player)`, `:1197 FindMostDangerousThreat`, `:1576 UpdateReactionQueue`; `cs_bot_manager.cpp`; `game/server/nav_mesh.cpp` |
| Shots | `game/shared/cstrike/cs_player_shared.cpp:326 FireBullet`, `game/shared/cstrike/fx_cs_shared.cpp:108 FX_FireBullets` |
| Lag comp | `game/server/player_lagcompensation.cpp:228 FrameUpdatePostEntityThink`, `:323 StartLagCompensation`, `:414 BacktrackPlayer`, `:730 FinishLagCompensation` |
| Threads | `vstdlib/jobthread.cpp` |

Paths are relative to `~/inspiration/game/engine/source-engine/`; the same files sit under `source-sdk-2013/src/`.

### Phases

Each phase lands on its own, behind a cvar that defaults on once its gate passes. The GDScript twin stays until parity holds, then gets deleted. **Every phase has the same web fallback: the wasm build of the same crates** (gs-sim already ships wasm). The GDScript twin is only the safety net while a phase is in progress. Following the no-A/B policy, each batch gets one before/after bench (`SIM_HOST_TICK p50`, 31 bots, PH), not a per-change A/B.

| Phase | What | Reuses crates | Expected saving | Gate |
|---|---|---|---|---|
| **P0** lib delivery guard | hv and game.sh fail (not warn) when the stamp is older than the pin; the gs-sim ready line lists every class and method the game asked for that was missing; boxes refresh the lib from the pin | gs-bootstrap, hv | 0 ms directly, but makes every A/B since 11-15 honest (v0.2.34/35 methods currently fall back) | the ready line shows `missing=0` in sim_host on PH |
| **P1** server tick shell + player table | `GSSimServerTick` holds a SoA player table (origin, velocity, flags, ducking, health, weapon state). One `step()` wraps the existing motor batch, players, contacts and posture natives; pl_pre, pl_post, pb_head and the tb_pass glue move inside it | gs-sim-motor, gs-sim-players, gs-sim-contacts, gs-sim-snapshot | 3-4 ms (glue in tick_players, pb_head 1.2, pl_pre+pl_post 1.7) | motor digest parity, native_parity*, sim_host suite, FC `./game.sh test` |
| **P2** collision mirror | new crate gs-sim-cmodel: brush/convex hulls plus displacement and terrain triangles in a BVH, with box trace and ray trace as the `CM_BoxTrace` analog. The data is baked into the map pack at convert time, not built from Godot shapes at runtime. Mesh maps without brushes fall back to a triangle BVH built from the map's collision faces | gs-sim-trace (grows beyond flat AABB), gs_sim_motor::flat (today's flat-world hook, `motor.rs:619`) | 1-2 ms now; per-ray cost drops from about 22 us to about 1 us, which P3-P5 depend on | trace parity suite: the same rays against PhysicsServer and the mirror, fraction within 1e-3 and the normal within 1 degree, on 3 maps |
| **P3** CGameMovement motor on the mirror | the motor switches its `cast_motion`, `get_rest_info` and `intersect_ray` calls to gs-sim-cmodel; the movement code is checked against `gamemovement.cpp` (StepMove, TryPlayerMove, CategorizePosition, Duck) | gs-sim-motor | 1-1.5 ms (p_controller and the engine calls) | motor digest parity, motor_batch_bench, movement selftests (surf, ladder, crouch-jump) |
| **P4** whole bot think in Rust | Upkeep and Update per bot run as one rayon job over the bot table, reading a frozen copy of the world. Vision, reaction queue, route, pickup, unstick and act all stay inside Rust; sight rays and the nav walkable checks use the mirror. Output is a usercmd per bot, which feeds P1's step like a human client's | gs-sim-bots, gs-sim-brain, gs-sim-senses, gs-sim-route, gs-sim-pvs, gs-sim-navjoin | 4-5 ms (srv_bots 5.4 down to about 0.6-1) | native_parity*, bot_selftest, bot match smoke (kills per minute and stuck count inside current bands) |
| **P5** shots + lag comp | FireBullet penetration and the unlag ring backtrack run inside step and trace hitboxes on the mirror; damage and kill come back as events | gs-sim-weapon, gs-sim-unlag (GSSimUnlagRing) | about 2 ms (p_weapons 2.0, tick_shots 1.3, minus what is left) | hitscan parity, lagcomp selftest, weapon suites |
| **P6** snapshot straight from tables | netpull, killview and send pack directly from the SoA tables, with mirror PVS per client | gs-sim-snapshot, gs-sim-pvs, gs-sim-crc | about 1 ms (netpull 0.97, killview 0.35, part of send) | net parity (client decode of snapshot bytes), sim_host suite |

The target after P6 is 4-6 ms per tick at 31 bots, still above CS:S's 2.2 ms. The remainder is GDScript event handling plus wasm/gdext boundary cost, and it is measured again before anything further is planned.

### Order and dependencies

- P0 comes first because it is cheap and makes later measurements trustworthy.
- P1 and P2 are independent and can land in either order.
- P3 needs P2.
- P4 and P5 get their full saving only after P2. They can land on PhysicsServer rays first and switch over later.
- P6 needs P1.

### Cross-repo work this needs (not done here)

- **P2 bake:** dot-map-convert has to write brush planes and hulls into the map pack. Brush reading exists only in Python today: `tests/test_gsbsp.py` `brush_planes` and `brush_hull`, `adapters/*/import_bsp.py`. gs-map then has to load and ship that data; `gs-map/addons/gs_map/bsp` builds meshes only.
- gs-sim: the new gs-sim-cmodel crate and the `GSSimServerTick` class.
- gs-bootstrap and hv: the P0 fail-loud guard.

### Rules for each phase

- One cvar per phase, default on once its gate passes, never a silent fallback: a missing method is logged.
- No leaf ports below about 1 ms on their own; fold them into the phase that owns them.
- Parity suites and FC suites are the gate. The single before/after bench per batch is only a record, not a gate.
