The FC server tick runs in six phases. Each phase has a gs-sim (Rust) path and a GDScript fallback. `sv_native_tick` is the master switch for all of them (`game/fc_native_phases.gd`).

| Phase | Cvars the master writes |
|---|---|
| players | `sv_native_players`, `sv_native_slots` |
| mirror | `sv_trace_mirror` |
| motor | `motor_native`, `sv_native_motor_state`, `motor_native_tick`, `motor_native_full`, `fc_hull_native`, `fc_posture_native`, `fc_mechanics_native`, `fc_tick_events` |
| bots | `bot_native*`, `fc_bot_pvs_native`, `fc_hull_grid_native` |
| shots | `sv_native_shots`, `sv_native_unlag` |
| snapshots | `net_pack_native`, `sv_net_pull_*native`, `sv_native_snapshots`, `sv_net_pull_batch` |

## Master switch

- `sv_native_tick 1` is the default. It sets every phase cvar registered in this build to 1. `0` sets them all to 0, so every phase runs its GDScript fallback.
- The phase cvars still work as overrides. A later `--cvar motor_native=0`, or a write from the console, wins until the master is written again.
- A phase cvar set to 1 without its library still runs the fallback. It never errors.

## Startup report

Each phase is placed in one of three states by checking what the build actually has. Nothing is assumed.

| Status | Meaning |
|---|---|
| absent | None of the phase's cvars are registered in this build. |
| fallback | A gs-sim class or method is missing, a cvar is 0, or the addon's own runtime switch is off. The reason is printed, and a warning is logged once. |
| native | Everything is present and on. |

- The server prints `FC_NATIVE_TICK master=1 native=[...] fallback=[...] absent=[...]` at load.
- At the end of a run, it prints `FC_NATIVE_TICK_CALLS players=N/M ...`: native and script dispatches per phase, counted by `FcNativePhases.tally`.
- A bench (`--sim_bench_sec`) also prints `SIM_HOST_NATIVE <status> | end`.

## Coverage suite

`examples/headless_native_tick_coverage` runs a dedicated server through a 31-bot CTF match on cp-orange-x3 with the master on. It fails if:

- any expected phase is on the GDScript path. Expected means the phases main has always run native, plus every phase the server reports as registered. A phase branch that lands is held to native without editing a list.
- `FC_NATIVE_TICK_CALLS` shows any script call, or shows no native call for an expected phase.

A second, short run with `sv_native_tick 0` must put every phase on the fallback and make no native calls.

## Collision mirror

`game/fc_trace_mirror.gd` copies the static bodies under the map's collision root once into a native BVH (`GSSimTraceMirror`). A bot's sight and wall ray then costs about a microsecond instead of a physics-server query under the shared ray lock.

- Players' native motors collide against it too, on the server and the predicting client alike (the cvar is replicated), except near anything it does not hold.
- Moving bodies (AnimatableBody3D, the `trace_dynamic` group) are re-posed once a tick. With `sv_trace_mirror_movers`, FC pushes their transforms in one batch (`update_movers`) and the motor collides against them (a lift carries, a door blocks). At 0, or with a gs-sim older than the batch, the mirror re-poses itself and a player near a mover asks the space.
- The mirror holds the map's world and nothing else: a weapon drop or a toy (RigidBody3D) does not block a bot's line, as Source's world trace ignores entities.

## Mirror suites

| Suite | What it holds |
|---|---|
| `headless_trace_mirror` | Seeded rays (`intersect_ray`), box hulls (`cast_motion`) and points (`intersect_point`) on box, pit, an imported deathmatch map, a surf map and cp-orange-x3. Every ray agrees on hit or miss, fraction within 1e-3 and normal within 1 degree; every hull contact lies in Godot's safe/unsafe bracket (1e-3 slack); every point agrees on solid or open. Prints microseconds per ray. |
| `headless_motor_mirror` | Bodies at the map's spawns run seeded random commands and scripted bot-like ones, the whole tick native, against the space and the mirror. Each map prints how many bodies part and, for the first, the tick, both states and the command. Then: two mirrors built apart from one map tick to the bit; the client follows the replicated cvar; anything the mirror does not hold sends a body back to the space; movers carry and block on the mirror as on the space; microseconds per tick of 31 bodies on cp-orange-x3. |

Imported maps skip when not linked. Both suites skip without gs-sim's mirror (and `headless_motor_mirror` without gs-player-controller's trace-world seam, level 53).
