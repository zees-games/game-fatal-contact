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

## Bots contact build

`game/fc_bot_contacts.gd` packs one record per player on the main thread (flags, team, pitch, health, then the `GSFpsState` columns as they are). gs-sim writes every per-tick `GSBotContact` field and the native sight scan's rows from them in one call. The loadout stays in script. `headless_botthreads` compares the result with `FcBots.World.refresh`'s script loop over randomized player states. Off, without the library (the web), or when the records do not fit, the script loop builds them.

| Mode | Cvar | What changes |
|---|---|---|
| delta | `bot_native_contacts_delta` | `fill_changed` writes only the fields that changed since the last tick. A tick the script loop built makes the next native build write every field again. |
| table | `bot_contact_table` | gs-bot 44, a gs-sim with `fill_table`. No contact object is written: packed columns become the world's `GSBotContactTable`, and an object is written from its row only when something reads it. |
| arms | `bot_native_contact_arms` | A gs-sim with `fill_arms`. The weapon in hand (`weapon_class`, `magazine`) is gathered as an interned class and two ints per player and written in one call, instead of one `_weapon_of` call and two property writes per player. |

## Bots coast

`bot_coast_native` (`game/fc_bot_coast.gd`, gs-sim's `GSSimBotCoast`): in `sb_begin`, every bot that sits the tick out gets its carried-on view and, while it fires, its recoil turn-back from one native call. The recoil row and its script preview are in `game/fc_bot_recoil.gd`. `headless_botthreads` compares 400 views and 400 recoil rows bit for bit, and the tiered match with the cvar 0 and 1.

## Bots perceive_all

`bot_native_think_mt` (`game/fc_bot_think_mt.gd`): each threaded brain hands the row its think would hand the native mind. Rays the minds have no cached answer for are cast on the main thread, and answers go back by index, so the thread count changes nothing.
