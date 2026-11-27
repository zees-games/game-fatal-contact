The FC server tick runs in six phases. Each phase has a gs-sim (Rust) path and a GDScript fallback. `sv_native_tick` is the master switch for all of them (`game/fc_native_phases.gd`).

| Phase | Cvars the master writes |
|---|---|
| players | `sv_native_players`, `sv_native_slots`, `fc_post_head_native` |
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

## Players phase

`game/fc_native_tick.gd` steps gs-sim's `GSSimServerTick` once per tick, after the batched players' loop. It holds the struct-of-arrays player table later phases read instead of asking each player per field: the roster in order (the hull world's slots), each row's motor part from the motor batch's resident row, and its origin from the hull world's feet.

- The loop hands it the motor batch (`GSFpsMotorBatch.use_native`) and its idle posture rows (`run_rows`, bit-identical to `GSSimPlayerPost`), so nothing is computed twice.
- A library that is present but lacks the class, a method or the API level is reported loudly once, never skipped in silence.

`sv_native_players` (`game/fc_game_players_call.gd`) hands the loop's two passes to gs-player-controller as one call, in the same order, so the states and edges are the same:

| Callback | Runs |
|---|---|
| `_pc_pre` | Pass one's part before the controller: input, tick start, the body's delta (-1 leaves the row out). |
| `_pc_live` | Before a row finishes: is the player still alive. The first call also runs the volume marks over every prepared row. |
| `_pc_post` | `_finish_batched_player`'s part after the controller. |

`fc_post_head_native` (gs-sim `GSSimServerTick` API 5): before the first `_pc_post`, and again after a row's move reruns the later rows, one `post_head` call answers every row's volume skip and hitbox height scale from the resident motor rows (`FcPlayer.post_head_input` hands it the slot, the mark and reach gate and the crouch ratio). `tick_post_head` takes a row only when its end feet are the state's, and the skip only when the marks were asked before the row was built; otherwise it runs the script. `headless_mechanics_native_parity` checks both answers against the script with `post_head_verify`.

With the fine probe on, the per-player laps (`pl_*`, `pp_*`, `po_*`) still record; the controller's own `c_*` laps are inside the one call, so only `p_controller` covers them.

The loop's motor edges are derived in one call (`GSSimTickEvents`, or the script) and dispatched in roster order (`FcNativeTick.dispatch_events`). From gs-player-controller 54 a controller's end_tick holds its surface, modifier and simulated signals in its row, and `game/fc_tick_rows.gd` emits them row by row.
