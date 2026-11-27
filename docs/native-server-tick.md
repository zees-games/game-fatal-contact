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

## Shots phase

`game/fc_native_shots.gd` walks walls, sheets, ricochets, bodies and the hitbox shapes in `GSSimShots` and applies the event rows exactly as `GSPelletTracer._step_body` would. Everything is read where it stands once per shot.

- A pellet goes to the script tracer when the switch is off, the library is missing, a hitbox set is laid out other than player root > set > box, or a pane is on its line.
- A posed unlag rewind (`game/fc_game_unlag.gd`, `sv_native_unlag`) moves no node: it hands each target's rewound feet and crouch fit to the tracer with `pose`. Only a pellet sent to the script makes the game move the nodes (`materialize_fn`), once a shot. The zones fit the present crouch, so a target that crouched since would otherwise be traced a standing head too short.

## Shots suite

`headless_native_shots` compares the damage rows (victim, amounts, group, limb, point, direction, distance, context), impacts, wall passes and ricochets of the native and script tracers, to the bit:

- fans of pellets over a standing target and a crouch-fitted one;
- a wood wall with bodies behind it, two walls in a row, a grazing metal wall, a one-sided sheet, a breakable pane (handed to the script);
- seeded shotgun spreads, and a strafing, crouching target rewound by lag compensation to fractional view ticks.

For `sv_native_unlag`, `GSSimUnlagRing` and the script rings are fed one history (a near target strafing and crouching, a far one at 70 m that teleports half-way) and must answer the same feet and crouch at every view a ping from 0 to 900 ms names: before the history, across the cut, between ticks. Fans rewound from each hit and miss alike. Last, the defaults (both switches 1, the rewind posing the native tracer) against the specification (both 0, nodes moved, script tracer) give the same rows; a posed shot a pane sends to the script moves the nodes late, alike.
