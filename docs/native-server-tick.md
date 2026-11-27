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

## Snapshot batch pull

`game/fc_net_pull_batch.gd` pulls every player's movement and weapons in one `GSSimFpsNetPullBatch.pull` call a tick, writing what `GSSimFpsNetPack.pull` and `GSSimFpsWeaponNet.pull` write per player. The bridge runs it once the game has ticked. A player it leaves out (no library, a cvar off, a declaration or rig only the script handles) pulls alone in `_net_simulate`.

| Cvar | 1 | 0 |
|---|---|---|
| `sv_net_pull_batch` | One gs-sim call for every player. | Each player pulls alone. |
| `sv_net_pull_apply_native` | gs-sim writes the answers onto the nets (`pull_apply`), no script per field. | `_apply` writes them. |
| `sv_net_pull_rest_native` | `GSSimNetRest.pull_rest_rows` pulls the rest (exact copy, health, challenge, beacon, carry, relevance, aim); the script finishes owned players (`FcNetPullBatch.rest_owned`). | Each player's `_pull_rest`. |
| `sv_native_snapshots` | gs-sim's `GSSimNetCore` builds snapshots on worker threads, so a release build without gs-net's C++ library is still native. | gs-net's GDScript path. |

## Snapshot suites

| Suite | What it holds |
|---|---|
| `headless_native_snapshot_parity` | Two servers in lockstep with the same seeded round of bots, one native and one GDScript. Every payload each fake client is sent is compared byte for byte, tick by tick: 6 and 31 players, a map change, bots and clients joining and leaving, acks two snapshots late, distance interest. Every player's pulled fields are compared too, with `OWNED` bots handed to fake clients so the owner's exact copy and carry mask are pulled. |
| `headless_netpull_batch_parity` | Seeded movement, held values, wire widths (one only the script handles), the hold on and off, arsenals, rigs and wind-ups, over bots and people (seeds as `headless_netpull_native_parity` and `headless_netpull_weapons_parity`). Each lane compares every player's snapshot state bytes (`GSNetBehaviour._encode`), and the batch runs twice: `pull_apply` and the script. |
