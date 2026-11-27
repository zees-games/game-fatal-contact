@tool
extends Node

## State and signals of [FcGame], split out so the game file holds its behaviour.

const KillPov := preload("fc_kill_pov.gd")
const FcAmbience := preload("fc_ambience.gd")
const FcWeaponDropWiring := preload("fc_weapon_drop_wiring.gd")
const FcConfig := preload("fc_config.gd")
const FcMapIo := preload("fc_map_io.gd")
const FcContent := preload("fc_content.gd")
const FcBotLoadouts := preload("fc_bot_loadouts.gd")
const FcEffects := preload("fc_effects.gd")
const FcHorde := preload("fc_horde.gd")
const FcLoadoutIdentity := preload("fc_loadout_identity.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcPaths := preload("fc_paths.gd")
const FcSolidBody := preload("fc_solid_body.gd")
const FcMode := preload("fc_mode.gd")
const FcModes := preload("fc_modes.gd")
const FcObjectives := preload("fc_objectives.gd")
const FcPlayer := preload("fc_player.gd")
const FcPlayerStack := preload("fc_player_stack.gd")
const FcProgress := preload("fc_progress.gd")
const FcStats := preload("fc_stats.gd")
const FcProjectiles := preload("fc_projectiles.gd")
const FcGrenades := preload("fc_grenades.gd")
const FcRocketJump := preload("fc_rocket_jump.gd")
const FcAttach := preload("fc_attach.gd")
const FcDrops := preload("fc_drops.gd")
const FcJailView := preload("fc_jail_view.gd")
const FcProps := preload("fc_props.gd")
const FcSpectate := preload("fc_spectate.gd")
const FcAwards := preload("fc_awards.gd")


const CHANNEL := "arena"
const SERVICE := &"arena_game"

## How far from the origin the netcode quantises positions over, in metres.
##
## [b]Both ends must use the same number, and there is therefore exactly one.[/b] A
## quantised position is an integer over this range, so a server encoding against 128
## and a client decoding against 256 do not produce a rounding error — they produce a
## DIFFERENT POSITION, for every entity, on every snapshot. The symptom is a client
## that connects, adopts its player alive with full health, and then finds itself
## somewhere the world is not: sky in every direction, a HUD reading zero, and not one
## error anywhere.
##
## That is what happened here the first time the two were written separately, in two
## files, a hundred lines apart. This constant exists so there is nothing to keep in
## step.
##
## 512, since the imported combat surf maps: they reach 312 m from the origin
## (`surf_110b_austinpowers`), and a position past the extent is CLAMPED rather than
## wrapped, so at the old 128 every player on the far half of one was pinned to a wall of
## the quantiser in every snapshot — alive on the server, stuck on every client. Two more
## bits a position axis at 1 cm, for every map.
const NET_WORLD_EXTENT := 512.0

## How long a remote body takes to ease back onto its snapshot blend after the buffer ran
## dry and gs-net extrapolated it (`GSNetConfig.resume_ease_sec`, gs-net's 0.12 default).
## The server rewinds a shot to the blend, never to the eased body (the offset is the
## client's and is not sent), so every frame drawn off the blend is a frame where the
## crosshair and the hitbox disagree. At 0.12 s `headless_hitreg_chaos` missed 1 tap of
## 173 on the 2-snapshot buffer; at 0.06 s none, and the worst on-screen pop grew 3 mm
## (0.109 to 0.112 m) with the ease frames halved (docs/netcode.md, "Lag compensation").
const CLIENT_RESUME_EASE_SEC := 0.06

## The range of tick rates Fatal Contact is tuned and tested for (`sv_tickrate`, `fc_tick_rate`).
## Tick counts in the code (THROWER_GRACE_TICKS, flashlight HOLD_TICKS, COLLISION_LAG_MAX_SEC) are seconds; see docs/netcode.md "Tick rate".
const MIN_TICK_RATE := 20
const MAX_TICK_RATE := 128

## Snapshots a second aimed at; the rate sent is [method snapshot_rate_for] the tick rate.
const NET_SNAPSHOT_RATE := 32

## The one tick rate (declared in FcContent to avoid a preload cycle): project.godot's physics rate, FcConfig.tick_rate (solo) and every default below read this. 66 divides into a 33 Hz snapshot.
const DEFAULT_TICK_RATE := FcContent.TICK_RATE


## A player was killed. After the scoreboard and the feed have seen it.
signal player_killed(entry: GSKillFeed.Entry)

## A player was put back into the world.
signal player_spawned(player: FcPlayer)

## A player exists. Fired by [method add_player], on every machine that has one.
##
## [b]Distinct from [signal player_spawned], and a client needs this one.[/b]
## `player_spawned` fires from `_on_respawn_due`, which is gs-match's, which runs on
## the AUTHORITY — so on a mirroring client it never fires at all. A client that waited
## for it to find its own player waited for ever: the HUD still bound by id and worked,
## the scoreboard worked, and there was no camera and no world, because both hang off
## the local player.
##
## That is this family's commonest shape with the ends swapped — a value consumed by a
## client and produced by nobody on the client's path — and it is the same bug
## game-airdrift shipped, one signal over.
signal player_added(player: FcPlayer)

signal match_state_changed(from: GSMatch.State, to: GSMatch.State)

## A combat entity that is NOT a player was killed.
##
## [b]This exists because the scoreboard used to get a row for one.[/b] gs-combat
## knows only entity ids; anything a game layer registers with it — a monster, a
## breakable, a turret — arrives at `_on_entity_killed` looking exactly like a player.
## The old handler passed the id to `GSMatch.report_kill` regardless, which creates a
## scoreboard record keyed on a number no player has ever had, and it would have shown
## up as a phantom name at the bottom of the board with a death against it.
##
## [FcHorde] is the listener. A game with no monsters connects nothing and nothing
## is emitted.
signal non_player_killed(entity_id: int, damage: GSDamage)

## The world was replaced. After everything is rebuilt and every player is back in it.
## A client hangs its renderer off this: the meshes it was drawing belonged to the old
## map and the nodes they came from are gone by the time this fires.
signal map_changed(map: FcMap)

## The server owner changed how Fatal Contact moves (`fc_slide*`, `fc_launch*`). The
## bridge sends it to every client; see [member movement_rules].
signal movement_rules_changed(rules: Dictionary)

## The jail's gate was pressed, or its rules changed (the authority's; a client applying the
## server's state does not emit it). The bridge sends it to every client.
signal jail_changed

## A client learned which mode is being played. Client side; the HUD shows its banner.
signal mode_shown(shown: FcMode)

@export_group("Simulation")

@export_range(1, 240, 1) var tick_rate: int = DEFAULT_TICK_RATE

@export_group("Rules")

## Kills to win. Zero uses the ruleset's own. Gun game ignores it: its limit is its list.
##
## [b]These four are the server's say over the mode's numbers[/b], and they are read in two
## places: [method _build_match], for every match this game builds (each map change builds
## one), and [method apply_match_limits], for the match being played. The module's
## `fc_scorelimit`, `fc_timelimit`, `fc_warmup` and `fc_minplayers` cvars write
## them through the latter. Writing only the live match lost the value at the next map
## change; writing only these exports changed nothing until then, and `fc_scorelimit` did
## neither for as long as it existed.
@export_range(0, 200, 1) var score_limit: int = 25

## The match's length in seconds. Zero uses the ruleset's own.
@export_range(0.0, 3600.0, 30.0) var time_limit_sec: float = 600.0

## Warmup in seconds. Negative uses the ruleset's own; zero is no warmup.
@export_range(-1.0, 600.0, 1.0) var warmup_sec: float = -1.0

## Seconds everyone stands frozen at their spawn before a round goes live (`mp_freezetime`).
## Negative uses the ruleset's own; zero is no freeze.
@export_range(-1.0, 60.0, 0.5) var freeze_sec: float = -1.0

## Players needed before a round starts. Zero uses the ruleset's own.
@export_range(0, 64, 1) var min_players: int = 0

@export_group("Mode")

## What is being played. Null means [member mode_id] decides.
## [b]Assign before [method setup].[/b] It builds the match rules, the teams and the
## damage rules, and none of them is re-read afterwards.
@export var mode: FcMode = null

## Which mode to use when [member mode] is null. See [FcModes].
@export var mode_id: StringName = &"ffa"

## Whether this instance decides who dies.
##
## A client runs the same [FcGame] with this off: it simulates, it traces for
## effects, and it applies nothing.
@export var is_authority: bool = true

## A client only: the sides the server announced (player id -> team), from `FcEvents.Kind.TEAM`.
## [method FcGame.team_of] answers from it on a client, because the client's own match assigns
## sides by its own join order and knows nothing of a menu switch or a rebalance.
var replicated_teams: Dictionary = {}

## Analytic geometry, or Godot physics. See [enum FcPlayer.Mode].
@export var headless: bool = true

@export_group("Progression")

## Count statistics, award achievements and keep leaderboards.
##
## [b]Authority only, and the guard is not a saving.[/b] A mirroring client runs the
## same [FcGame], sees the same kills replicated to it, and counting them there
## would credit every player on the server a second time in a place the server never
## reads — and, worse, would let a modified client award itself achievements. The
## numbers belong to whoever decides who died.
@export var track_progress: bool = true

## Where lifetime stat totals persist (a user:// JSON file). Empty keeps none, so a suite is the same on every run; the server and the offline client set it.
@export var stats_file: String = ""

## Where achievement progress persists; empty uses the tracker's default user:// store. A suite points it at a throwaway directory.
@export var progress_dir: String = ""

@export_group("Service")

@export var register_service: bool = true

@export var service_scope: StringName = &""

var map: FcMap = null
var match_node: GSMatch = null
## Every world object this game has a combat entity id for. See [GSEntityTable].
##
## [b]Monsters only, today.[/b] A player's entity id in this game IS their gs-server
## session id, and seven things depend on that identity — gs-match's scoreboard keys,
## gs-effects' per-entity scales, gs-stats rows, gs-spectate, the player-stack
## roster, the kill feed on the wire, and the client that rebuilds one from two ints.
## [FcHorde] carries the full reasoning and what converting the other half would
## take; the short version is that gs-effects is keyed from both spaces at once, so
## the two halves cannot move separately.
##
## What the table already buys is the half that was wrong: monster ids used to be
## derived from engine instance ids and could collide with each other in silence.
var entities := GSEntityTable.new()

var combat: GSCombatManager = null

## Whether a player's client is still behind its loading cover: `func(player_id: int) -> bool`.
## The server module fills it from its [GSGameRoster]; unset (offline, a suite, a bot) nobody
## is loading. See [method can_be_harmed].
var loading_fn: Callable = Callable()
var loadouts: GSLoadoutManager = null

## The loadout menu's server half (gs-loadout's `GSLoadoutCommand`): the `/loadout` command
## the B menu sends, its `loadout_menu` notice, and the owner's `mp_loadout_*` cvars, which the
## module binds. Solo the client asks it directly. Untyped and loaded by path because a host with
## a gs-loadout older than API 2 has no such class, and this script must still parse there
## (`requires.floor.json`); null on such a host, and the B menu is then not offered.
var loadout_command: Object = null

## The kits bots draw at each spawn (`cfg/game/game-fatal-contact/bot_loadout/`, narrowed by `sv_bot_loadouts`);
## loaded on the first bot spawn. See [method apply_loadout].
var bot_loadouts: FcBotLoadouts = null

## Rockets in flight. Built alongside the combat manager, because it traces against
## the same world and resolves through the same rules.
var projectiles: FcProjectiles = null

## Flash, smoke and incendiary effects; null off the authority or below fc_weapons level 3.
## A utility grenade's smoke, fire or blind, across map changes (the grenades object is rebuilt per map).
signal grenade_effect(info: Dictionary)

var grenades: FcGrenades = null
## `sv_grenade_*`, kept across maps so a cvar bound once survives a rebuild. Also how the projectile layer bounces
## a fused grenade (fc-weapons level 27), on the server and on a client flying its copy.
var grenades_rules := _fc_grenade_rules()
## `sv_rocket_*` (fc-weapons' `AwRocketRules`, level 27; null below): the single-missile launcher's tube and blast
## and the Rocketjump warhead. Kept across maps, like the grenade rules.
var rocket_rules: RefCounted = FcRocketJump.make_rules()
## The jail glass rule (`sv_glass_block_*`), kept across maps; takes the cell of each map as it loads and is inert on one without.
var glass_rules := GSMapGlassSight.new()
## `sv_grenade_utility`: whether the utility grenades can be picked in a loadout.
var utility_grenades := false

## What a critical kill drops: points and a health pack. Rebuilt with the combat layer on a
## map change, like the projectiles; its rules live here in [member drop_rules] so a map
## change keeps what the server owner set.
var drops: FcDrops = null

## Weapons lying in the world (thrown with the drop key, or left by the dead): gs-weapon's layer
## under [member weapon_drop_rules], whose cvars are the server owner's and outlive a map change.
var weapon_drops: GSWeaponDrops = null
var weapon_drop_rules: GSWeaponDropRules = GSWeaponDropRules.new()
## Thrown knives (GSWeaponKnives, gs-weapon), and their server rules: one dictionary for the game's life, so cvars outlive a map.
var knives: GSWeaponKnives = null
## The throw winds up while the aim key is held (`fc_knife_throw_charge`, on by default; gs-weapon's own default is off).
var knife_rules: Dictionary = GSWeaponKnives.DEFAULT_RULES.merged({"charge": true, "charge_sec": 1.0}, true)


## The converted map's doors, lifts and buttons, or null for a map without any (it then costs nothing per tick).
var map_io: Node = null
## The use key's reach and cooldown for map buttons: one for the game's life, so the owner's cvars outlive a map.
var map_use: GSMapUse = GSMapUse.new()
var drop_held: Dictionary = {}
## Per player: whether the use key was down last tick, for its rising edge.
var use_held: Dictionary = {}


## The player-class def that overrides drop rules for [param id], or null.
func weapon_drop_class_of(id: int) -> GSPlayerClassDef:
	return FcWeaponDropWiring.class_def_of(self, id)

## Kills since each player last died. Authority side; a client counts its own from KILL.
var streaks: Dictionary = {}

## Streak -> what reaching it gives: `heal` (full health), `armour`, `haste`,
## `empowered` (more damage, a while). Set by `fc_streak_rewards` as "3:heal,5:haste";
## empty gives nothing. Applied on the kill that reaches the streak, server side.
var streak_rewards: Dictionary = {}

## A random-every-spawn loadout was handed to [param player_id]; [param text] names it. Authority side.
signal loadout_rolled(player_id: int, text: String)

## Whether a spawn roll of a random loadout prints "Random loadout: ..." on screen (`fc_loadout_roll_text`, off).
## The roll is still made and given; only the text is left out.
var loadout_roll_text: bool = false

## Somebody reached a streak with a reward. Server side; the module announces it.
signal streak_reward(player_id: int, streak: int, reward: String)

## A player's damage landed on something: a player or a monster. Authority side, once per
## damage event (a shotgun's pellets are several); the bridge sums a tick's into one HIT
## for the attacker, and an offline client draws it straight from here. [param point] is
## where it landed, [param amount] what it took off health and armour together.
##
## [b]The hit marker is drawn from this and nothing else.[/b] A client that flashed on
## its own predicted shot drew hits the server then refused (a lag-compensated miss, a
## protected spawn); the marker would say "hit" about a shot that did nothing.
signal hit_confirmed(attacker: int, victim: int, amount: float, point: Vector3, headshot: bool, lethal: bool)

## What one kill earned: its medals ([enum FcAwards.Medal]), its points, and the
## killer's streak now. Authority side, after [signal player_killed] for the same kill.
## A head stomp landed (authority side): who, on whom, the downward speed, where, and the sound and
## effect ids to present. The stat event gs-stats counts; [constant FcStats.STOMPS] listens.
signal stomped(attacker: int, victim: int, fall_speed: float, point: Vector3, sound: StringName, effect: StringName)

## What one kill earned, see below.
signal medals_awarded(killer: int, victim: int, medals: Array, points: int, streak: int)

## The medal rules' memory. Authority side; reset at each round's start.
var medals := FcAwards.MedalBook.new()

## The server owner's drop rules (`fc_drop_*`), applied to every drops layer built.
var drop_rules := {
	"points": 5, "point_value": 1, "health": 0.0, "any_kill": false, "life": 10.0,
	"packs": true, "pack_health": 50.0, "pack_ammo": 50.0, "pack_respawn": 20.0,
}

## The server owner's capture-the-flag rules (`fc_ctf_*`), read by the flag layer when it is built and each round.
var ctf_rules := GSObjectiveCtfRules.new()

## The flag indicator, server cvars sent to clients with the flag state: `fc_ctf_indicator` (a small team-coloured flag icon and distance over each flag, default on) and `fc_ctf_indicator_seethrough` (the icon shows through walls, default on).
var ctf_view := {"indicator": true, "see_through": true}

## A line the server announces about the flag (taken, dropped, returned, captured).
signal ctf_announced(text: String)

## A flag changed hands on this end's screen (what: taken, dropped, returned, captured; team is the flag's team; by is the id of the player who carried it, 0 when nobody). Raised by the flag view from what it draws, so it fires on a client and offline too, not only where the server announces.
signal ctf_seen(what: StringName, team: int, by: int)

## The jail's gate and button, drawn. Null on a headless end and on a map without a jail.
var jail_view: Node3D = null

## The server owner's jail rules (`fc_jail*`), applied to the map's jail when a map loads and
## when one changes: whether it is on, seconds the gate stays open and seconds it then stays shut.
var jail_rules := {"enabled": true, "open": 10.0, "cooldown": 20.0}

## What the packs were last placed with, so a rule change that is not about them does not put
## every pack back (which would restart its respawn timer). See [method apply_drop_rules].
var _packs_placed_with: Array = []

## Statistics, achievements and boards. Null when [member track_progress] is off or
## this instance is not the authority.
var progress: FcProgress = null

## Monsters. Null unless the mode asks for them and this instance is the authority.
##
## [b]Authority only, and unpredicted.[/b] A brain runs a behaviour tree against a
## blackboard with lifetimes on it, which is not something two machines reproduce from
## the same inputs — gs-npc says so and gs-props says the same thing about rigid
## bodies. A client sees monsters because they are replicated, never because it
## simulated them.
var horde: FcHorde = null

## The server's tunables; the server scene replaces it with the layered one.
var config := FcConfig.new()

## Binds [member config] to cvars and the workbench; set by the server scene.
var config_binder: GSGameConfigBinder = null
## The flashlight's config and binder ([FcFlashlight]), made by [method FcGame.flashlight_conf].
var flashlight_config: GSFlashlightConfig = null
var flashlight_binder: GSGameConfigBinder = null
## The workbench the server scene built; [FcModule] starts it once the cvars it offers exist.
var workbench: GSGameWorkbench = null

## How good the monsters are, server-wide, on top of each kind's character.
##
## [b]On the game rather than on the horde, because the horde does not outlive a mode
## change[/b] and an operator who set `npc_skill hard` would otherwise get normal monsters
## back at the next map. The module binds it to `npc_skill`, `npc_reaction_scale` and
## `npc_reaction_min`; the horde attaches it to each spawner it builds.
var npc_skill: GSNpcAiSkill = GSNpcAiSkill.new()

## Records and harvests players' surf rides once [method start_ride_recording] has run.
var surf_rides: RefCounted = null

## Records where players stand and how they aim, and weights the bots' roaming by it; set by [method start_demo_stats].
var demo_stats: RefCounted = null

## Whether the monsters' learned map traffic is kept on disk across restarts.
##
## [b]Off unless a server turns it on[/b] — [FcModule] does, which only a real server
## loads. Every suite builds an FcGame, and one that saved would have each run's bots
## train the next run's monsters: a suite whose results depend on how often it has run.
var persist_npc_heat: bool = false

## Physics props. Null unless the mode asks for them and this instance is the authority.
var props: FcProps = null

## The map's toys (gs-props' [GSPropBodyBox]): loose ones only here, beach balls, footballs,
## barrels and tyres, which a person walks through and pushes and a shot sends rolling but which
## stop no shot and hold nobody up, so they are never cover, a ledge or a launch in a
## deathmatch. Built from [member FcMap.toys] on both ends in the same order, simulated by
## the authority, posed from snapshots on a client (`fc_toy_net.gd`). Null before a map.
var toys: GSPropBodyBox = null

## gs-props' `sv_toys*`, bound by the module REPLICATED and followed by a client.
var toy_rules: GSPropBodyRules = GSPropBodyRules.new()

## The map's toys are about to go (a map change), on both ends: what the bridge releases their
## entities on. And built, which is what a client's bridge pairs them on.
signal toys_clearing()
signal toys_built()

## A toy made a sound, on whichever end draws it: what the presentation plays.
signal toy_sound(id: StringName, at: Vector3, strength: float)

## A headless authority's copy of the level in the physics space, for the toys to land on:
## nothing else here asks the physics space about a built-in map (see [FcProps]).
var _toy_level: Node3D = null

## Status effects: burning, empowered, haste, spawn protection, slowed.
##
## Built in every mode, because spawn protection is one of them and every mode has
## that. gs-effects' whole integration is one line — `resolver.adjust` — which
## gs-combat has offered since it was written and nothing here had ever filled.
var effects: FcEffects = null

## What the round is about, in a mode that is about something. Null in a deathmatch.
var objectives: FcObjectives = null

## Where a dead player looks. Built in every mode, because every mode kills people.
var spectate: FcSpectate = null

## Who is in the session, which side, what class, where they enter, and the physics.
##
## [b]Built last and binds to everything else.[/b] It adds no authority: gs-match still
## decides the round and gs-combat still decides damage. What it does is keep one set
## of records in step with them, so a scoreboard, a spectator camera, a class screen and
## a spawn selector read the same thing rather than four dictionaries that agree until
## somebody reconnects. See [FcPlayerStack].
var player_stack: FcPlayerStack = null

## player id -> [FcPlayer].
var _players: Dictionary = {}
var _round_frozen_ids: Dictionary = {}
## What the last whole `_sync_round_freeze` held everybody to: a respawn under the same answer syncs only its own player.
var _round_frozen_want := false
var _freeze_overridden := false

## A team mode on a map that tags no spawn for both sides cuts the map's spawns into two halves by
## position (`FcMap.split_spawns_for_teams`), so each team spawns in its own half. False keeps
## the old fallback: both teams share one pool. `fc_team_spawn_split`; read when a map loads.
var team_spawn_split: bool = true

## Lag compensation: how far back the server will rewind the other players for a shot,
## in milliseconds (`fc_max_unlag_ms`; 0 judges every shot against the present).
##
## [b]It never rewound at all before 2026-10-09.[/b] `resolve_shot` was called with no
## view tick, so a player on a 120 ms round trip had to lead every target by the lead,
## the flight time and the interpolation delay together -- about 280 ms at 64 ticks --
## and a shot at somebody exactly under the crosshair missed. Now each command carries
## how far behind it the client drew everybody ([member FcNetCommand.view_lag_q]),
## and the shot is traced against where the other players were then. 1000 by default
## (it was 500, which covers a 250 ms round trip and clamped a player joining from
## another continent at 300-400 ms): every millisecond more is a millisecond a low-ping
## player can be shot around a corner they already left, but that only happens when the
## shooter really is that far behind, and refusing them is worse. UNLAG_HISTORY holds 2 s.
var max_unlag_ms: float = 1000.0:
	set(value):
		max_unlag_ms = maxf(value, 0.0)
		if combat != null and combat.config != null:
			combat.config.max_rewind_ms = max_unlag_ms
			combat.config.lag_compensation = max_unlag_ms > 0.0
		# A client collides with the same limit (collision_lag), so it travels in RULES.
		if is_authority and float(movement_rules.get("max_unlag_ms", -1.0)) != max_unlag_ms:
			call(&"set_movement_rules", {"max_unlag_ms": max_unlag_ms})  # defined in the derived FcGame

## Seconds a semi-auto press made during a weapon's cooldown stays queued (`sv_fire_buffer`): 0 drops it, negative
## keeps it until the cooldown ends. Sent in RULES because the client predicts the same arsenal.
var fire_buffer_seconds: float = 0.15:
	set(value):
		fire_buffer_seconds = value
		for player in call(&"players"):  # defined in the derived FcGame
			player.arsenal.fire_buffer_seconds = value
		if is_authority and float(movement_rules.get("fire_buffer", -9.0)) != value:
			call(&"set_movement_rules", {"fire_buffer": value})

## The least ticks of position history kept per player for a rewind (two seconds at 64 ticks); see [method unlag_history].
const UNLAG_HISTORY := 128

## Seconds of position history kept per player: the ring is this long at ANY tick rate (132 slots at 66, 258 at 128).
const UNLAG_SECONDS := 2.0

## The most time back a mover collides with the others, in seconds (32 ticks at 66): inside both the
## server's ring and a client's interpolation buffer, so both ends always find the same answer. The same
## seconds at any tick rate; [method FcGame.collision_lag] converts to ticks.
const COLLISION_LAG_MAX_SEC := 0.485

## A jump this far in one tick (metres) is a teleport or respawn: nothing rewinds across it.
const TELEPORT_CUT := 10.0

## id -> [PackedVector3Array positions, PackedInt32Array ticks, PackedFloat32Array crouch fractions], a ring per player.
var _unlag: Dictionary = {}
## id -> the position a rewind moved a player from, until it is restored.
var _unlag_moved: Dictionary = {}
## id -> true for a player whose hit zones a rewind fitted to the crouch it had then, until it is restored.
var _unlag_refit: Dictionary = {}
## The shooter, whom a rewind leaves where they are.
var _unlag_shooter: int = 0
## Flies simulated bullets when `sv_ballistics` is on; null without gs-weapon's ballistics rules.
var bullet_bridge: GSWeaponBulletBridge = null
## Draws their tracers (client side of a local or listen game).
var tracers: GSWeaponTracers = null
## Client side: flies the server's announced bullets for drawing only; nothing here decides a hit.
var bullet_mirrors: GSWeaponBullets = null
## Server bullet id -> the local id in [member bullet_mirrors].
var _mirror_ids: Dictionary = {}

## Movement keys changed from [method FcPlayer.fc_tunables]' defaults, key -> number.
##
## [b]Kept, and applied to every player who arrives later[/b], because a rule that only
## reached the players present when it was set is a rule the next joiner does not have —
## and a client and server that disagree about a slide mispredict every slide.
var movement_rules: Dictionary = {}

## The spawn points built from the map, so a map change can take them away again.
##
## Held rather than found by walking the children: this node's children are the match,
## the combat manager, the loadouts, the progress node, every player AND every spawn
## point, and a teardown that filtered them by type would free a spawn point a host
## project had added itself.
var _spawn_points: Array[GSSpawnPoint] = []

## An imported map's solid, in the tree on every machine (see `FcMap.movement_body`).
## Held so a map change can take it away again; null on a built-in map.
var _world_collision: Node3D = null

var _tick: int = 0
## Player id to the tick of their last spawn and last shot, for the instant loadout swap.
var _spawned_tick: Dictionary = {}
var _fired_tick: Dictionary = {}

## Player id -> where their spawn protection started, for `spawn_protection_move_feet`.
var _protect_anchor: Dictionary = {}

const FEET_TO_METRES := 0.3048
var _registered_name: StringName = &""

## The tick each (player, hurt volume) pair is next hurt on, kept after the player leaves
## the volume until it passes. See
## [method _hurt_from_map].
var _hurt_due: Dictionary = {}

## What [method follow_server_cvars] follows; null on a server and offline.
var _cvar_source: Object = null

## What a dead body does, and which death reactions the server allows: gs-player-char's
## `sv_ragdoll*` cvars. Bound by the module on the server (REPLICATED) and followed through the
## client link on a client, which is the end that draws the bodies. One for the life of the
## game, not per map, so a map change keeps the server's setting.
var ragdoll_rules: GSPlayerRagdollRules = GSPlayerRagdollRules.new()

## Whether a player may switch to third person: gs-player-controller's `mp_forceview`. Bound
## by the module (REPLICATED) and followed by the client, which is the end with a camera.
var view_rules: GSPlayerViewRules = GSPlayerViewRules.new()

## gs-mobile's touch, aim assist and auto-fire cvars (`sv_mobile_*`, `sv_aim_assist*`, `sv_autofire*`): bound by the
## module (REPLICATED), followed by the client's overlay. Auto-fire is allowed here, so a touch player starts with it.
var mobile_rules: GSMobileRules = _make_mobile_rules()


static func _make_mobile_rules() -> GSMobileRules:
	var rules := GSMobileRules.new()
	rules.autofire = GSMobileRules.ALLOWED
	return rules


## The ambience cvars (`fc_ambient*`): bound by the module (REPLICATED), followed by a client through its link.
var ambient_rules: GSAmbienceRules = FcAmbience.make_rules()

## `snd_shot_*`: gs-audio's layered shots and room-aware tails (all on). Bound by the module, followed by the client.
var shot_rules := GSShotRules.new()

## Who a spectator may watch and whether they may fly a free camera: gs-spectate's
## `mp_forcecamera`, `mp_freeroam` and `mp_freeroam_speed`. Bound by the module (REPLICATED) and
## followed by the client, which is the end that flies the camera. One object for the life of
## the game, shared with [FcSpectate]'s manager, so a cvar change reaches the rules in use
## and a map change keeps the operator's setting.
var spectate_rules: GSSpectatorRules = GSSpectatorRules.new()

## Whether players and bots are solid to each other: gs-player-controller's
## `mp_solidplayers` (1 by default). Bound by the module (REPLICATED) and followed by the
## client, because a client predicts its own player against the others' hulls. Fatal Contact's
## movement is analytic, so the hulls are boxes in each player's movement body
## ([method solid_hulls_for], `fc_solid_body.gd`), not the physics capsule the other
## games give a body.
var body_rules: GSPlayerBodyRules = GSPlayerBodyRules.new()

## `(other_id, mover_id, tick) -> Vector3 or null`: where [param other_id]'s hull stands when
## a networked player moves on [param tick]: where that player's client drew them, on both
## ends (`FcNetBridge.remote_feet`). Null, or unset, is where the other stands now.
var remote_feet_fn: Callable = Callable()

## `(mover_id) -> bool`: whether [member remote_feet_fn] could answer other than now for that mover (`FcNetBridge.remote_lags`). Unset: assume it could.
var remote_lags_fn: Callable = Callable()

## `(other_id, shooter_id, view_tick) -> Vector3 or null`: where [param other_id] stood on the
## shooter's screen for a hitscan shot rewound to [param view_tick], blended between the two
## snapshots the shooter's command named (`FcNetBridge.shot_feet`). Null, or unset: the
## server's own ring at that tick ([method FcGame.unlag_position_at]).
var shot_feet_fn: Callable = Callable()
## `(other_id, shooter_id, view_tick) -> float`: [param other_id]'s crouch over the same bracket as [member shot_feet_fn]
## (`FcNetBridge.shot_crouch`); below 0, or unset: the server's own ring ([method FcGame.unlag_crouch_at]).
var shot_crouch_fn: Callable = Callable()
## Set while a hitscan shot of this tick is traced, so [member shot_feet_fn] is asked; a bullet's
## or a projectile's rewind is not the click's.
var _unlag_shot := false

## `sv_shot_bracket_max_span`: the widest pair of snapshot ticks, shared or one target's own, a hitscan shot is blended across (or run ahead from); a wider one is refused, counted and logged, and the shot rewinds to the ring. 0: no limit.
## 32 ticks holds a far target's quarter-rate samples (8 ticks) with two snapshots lost in a row; the ring keeps 128.
var shot_bracket_max_span: int = 32
## `sv_shot_ease_max`: the largest resume ease, in metres, a firing command may say it drew a target off its samples by (FcNetCommand.view_targets); a larger one is refused, counted and logged. 0: no limit.
## 3 m: a body extrapolated the client's whole `max_extrapolation_sec` (0.25 s) at a full run (6 m/s) while it ran back the other way; no honest ease is larger (0.97 m measured, headless_hitreg_far), and the unlag window already lets a shot name any tick in it.
var shot_ease_max: float = 3.0
## `cl_shot_view_cone_deg`: a firing command names a target's own sample pair (FcNetCommand.view_targets) only for players within this many degrees of the aim; 0 names every one drawn off the shared pair.
var shot_view_cone_deg: float = 10.0
## `sv_native_shots`: 1 walks hitscan pellets (walls, ricochets, bodies, hitbox shapes) in GameSpice Sim's `GSSimShots` and applies its event rows (fc_native_shots.gd); 0 runs gs-combat's script tracer, the specification. Without the library the script runs and an error is logged once.
var native_shots: int = 1
## `sv_shot_rewind_log_sec`: how often, in seconds, the server logs [member shot_rewind_counts] when a fallback or refusal grew since the last line; 0 never.
var shot_rewind_log_sec: float = 30.0
## How each hitscan rewind stood a target, by key: target (its own pair, blended), target_ahead (its own pair, run on past the newer), target_held (past the extrapolation limit, held at the newer), bracket (the shared pair), ring (the server's own tick),
## eased (a target's own pair with the client's resume ease added), refused_ease (over [member shot_ease_max]), held (a repeated command: its pairs no longer name what was drawn), refused_span (over [member shot_bracket_max_span]), refused_view (the view tick outside the pair), unrecorded (no ring entry: not rewound, logged), bullet (a bullet's or projectile's rewind, the ring).
var shot_rewind_counts: Dictionary = {}

## Adds one to [member shot_rewind_counts] under [param key].
func count_shot_rewind(key: StringName) -> void:
	shot_rewind_counts[key] = int(shot_rewind_counts.get(key, 0)) + 1

## Player [param id]'s feet in the rewind ring at [param view_tick], counted as a hitscan shot's ring or a bullet's; null, counted unrecorded, when the ring has none there
## (a respawn or teleport since): the body is traced where it stands now, and the `sv_shot_rewind_log_sec` line says so.
func ring_feet(id: int, view_tick: float) -> Variant:
	var then: Variant = call(&"unlag_position_at", id, view_tick)
	count_shot_rewind(&"unrecorded" if then == null else (&"ring" if _unlag_shot else &"bullet"))
	return then

## Which pairs of players stop at each other (gs-team's `GSTeamBlockRules`: `mp_teamblock`,
## `mp_enemyblock`, `!block` / `!noblock`); null until [method make_noblock] or a client's
## `add_noblock` sets it. Feeds [member body_rules] `pair_fn`; the same answer on every machine,
## or the client rubber-bands.
var block_rules: Object = null

## gs-game's wiring of [member block_rules]: its cfg layers, cvars and chat commands.
var noblock: GSGameNoblock = null

## Whether a module has bound [member noblock]'s cvars and commands (they cannot be bound twice).
var noblock_bound := false

## The view model's motion amounts: fc-weapons' `mp_vm_*` cvars. Bound by the module
## (REPLICATED) and followed by the client, which is the end that draws the hands. The
## client's view model is handed this object, so one cvar change reaches the sway.
var feel_rules: AwViewFeel = AwViewFeel.new()

## Aim-down-sights and hip-size numbers (`aw_ads_rules`, REPLICATED): the server's cfg over fc-weapons' defaults. One per game, shared by every rig and the view model.
var ads_rules: AwAdsRules = AwAdsRules.load_config()

## Whether a death leaves a real weapon in the world, so the client skips its look-alike prop.
func drops_weapon_on_death() -> bool:
	return weapon_drops != null and weapon_drop_rules.enabled and weapon_drop_rules.on_death


## "3:heal,5:haste" -> {3: "heal", 5: "haste"}. Unparseable pairs are skipped.
static func parse_streak_rewards(text: String) -> Dictionary:
	var out := {}
	for pair in text.split(",", false):
		var bits := pair.strip_edges().split(":")
		if bits.size() == 2 and bits[0].is_valid_int() and int(bits[0]) > 0:
			out[int(bits[0])] = bits[1].strip_edges()
	return out


## `AwGrenadeRules` with FC's own stop rules as the defaults of `sv_grenade_rest_speed` (1.2 m/s) and
## `sv_grenade_max_bounces` (12): what `FcProjectiles` always did. Set by name, since both fields are level 27.
static func _fc_grenade_rules() -> AwGrenadeRules:
	var rules := AwGrenadeRules.new()
	rules.set(&"rest_speed", FcProjectiles.REST_SPEED)
	rules.set(&"max_bounces", float(FcProjectiles.MAX_BOUNCES))
	return rules


## Re-applies `sv_rocket_*` to the shared weapon and attachment catalogues: on bind and on every change.
func apply_rocket_rules() -> void:
	FcRocketJump.apply_rules(rocket_rules, FcPlayer.weapon_catalogue(), FcAttach.catalogue())
