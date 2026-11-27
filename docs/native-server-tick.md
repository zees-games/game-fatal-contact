The FC server tick runs in six phases. Each phase has a gs-sim (Rust) path and a GDScript fallback. `sv_native_tick` is the master switch for all of them (`game/fc_native_phases.gd`).

| Phase | Cvars the master writes |
|---|---|
| players | `sv_native_players`, `sv_native_slots` |
| mirror | `sv_trace_mirror` |
| motor | `motor_native`, `sv_native_motor_state`, `motor_native_tick`, `motor_native_full`, `fc_hull_native`, `fc_posture_native`, `fc_mechanics_native`, `fc_tick_events`, `fc_pre_native`, `fc_knife_gate`, `fc_flush_idle_skip` |
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
- A bench (`--sim_bench_sec`) also prints `SIM_HOST_NATIVE <status> lanes=[pre=n/s knife=n/s flush=n/s] | end`, and the same line without `| end` once a window.

## Lanes

Lanes are pieces of the players' loop inside the motor phase. Each one counts native-or-skipped calls (n) against script calls (s). They are kept apart from `FC_NATIVE_TICK_CALLS`, where any script call fails the coverage suite: a lane's script side is normal play (a player holding the knife's aim key, a protected or firing player).

| Lane | Cvar | Counts | Parity suite |
|---|---|---|---|
| pre | `fc_pre_native` | one per batched tick: gs-sim `GSSimServerTick.pre` or the per-player script | `headless_pre_native_parity` |
| knife | `fc_knife_gate` | one per live player: an idle player's `GSWeaponKnives.input` and `charge_of` skipped, or both called | `headless_tick_gates_parity` |
| flush | `fc_flush_idle_skip` | one per flushed idle post: an unprotected player's empty outcome handled in place, or `_post_outcome` | `headless_tick_gates_parity` |

The knife and flush gates live in `game/fc_tick_gates.gd`. They are bit-exact skips, not native ports: the heavy per-player weapon work they sit beside belongs to gs_weapon and fc_weapons.

## Coverage suite

`examples/headless_native_tick_coverage` runs a dedicated server through a 31-bot CTF match on cp-orange-x3 with the master on. It fails if:

- any expected phase is on the GDScript path. Expected means the phases main has always run native, plus every phase the server reports as registered. A phase branch that lands is held to native without editing a list.
- `FC_NATIVE_TICK_CALLS` shows any script call, or shows no native call for an expected phase.

A second, short run with `sv_native_tick 0` must put every phase on the fallback and make no native calls.
