extends Node

const FcTickBudget := preload("fc_tick_budget.gd")
const FcSimHost := preload("fc_sim_host.gd")
const FcHostConsole := preload("fc_host_console.gd")
const FcAvatars := preload("fc_avatars.gd")
const FcViewArms := preload("fc_view_arms.gd")
const FcBindings := preload("fc_bindings.gd")
const FcBots := preload("fc_bots.gd")
const FcBrowser := preload("fc_browser.gd")
## Loaded when a link is built ([method _build_netcode]), never preloaded: the extras pull dot-chat,
## dot-voice and the map sync client (about 50 scripts, ~9 MB of MEMORY_STATIC), and an offline
## game never builds them.
const FC_CLIENT_EXTRAS := "res://game/fc_client_extras.gd"
const FcEvents := preload("fc_events.gd")
const FcWeaponSkins := preload("fc_weapon_skins.gd")
const FcFrameProbe := preload("fc_frame_probe.gd")
const FcGame := preload("fc_game.gd")
const FcHud := preload("fc_hud.gd")
const FcHudGlance := preload("fc_hud_glance.gd")
const FcKillcamBodies := preload("fc_killcam_bodies.gd")
const FcKillcamShots := preload("fc_killcam_shots.gd")
const FcConfig := preload("fc_config.gd")
const FcContent := preload("fc_content.gd")
const FcMode := preload("fc_mode.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcMapLighting := preload("../maps/fc_map_lighting.gd")
const FcMenus := preload("fc_menus.gd")
const FcMaps := preload("fc_maps.gd")
const FcModes := preload("fc_modes.gd")
const FcNetBridge := preload("fc_net_bridge.gd")
const FcPaths := preload("fc_paths.gd")
const FcProjectileView := preload("fc_projectile_view.gd")
const FcPlayer := preload("fc_player.gd")
const FcTeamBodies := preload("fc_team_bodies.gd")
const FcPresentation := preload("fc_presentation.gd")
const FcWeaponIcons := preload("fc_weapon_icons.gd")
const FcSpriteWeapon := preload("fc_sprite_weapon.gd")

## A playable game-fatal-contact: one local player, a camera, a HUD, menus and the keys.
##
## [b]Separate from [FcGame], which is the simulation and runs headless.[/b] A
## dedicated server never loads this. That split is the reason `headless_match` can play
## a whole deathmatch with no renderer and no window, and it is the reason this file is
## the only one in the project that mentions a `Camera3D` or an `InputEvent`.
##
## Until this existed, game-fatal-contact was the reference game with nothing to sit down at:
## `FcNetBridge` ran, `headless_net` drove it, and there was no camera rig, no input
## sampling, no renderer and no sound. Everything here is modelled on `G2GClient`,
## which is the one in this family proven over a real socket and in a browser.
##
## [codeblock]
## WASD          move                Space   jump (hold; auto-hop is on)
## Ctrl          crouch              Mouse1  fire
## R             reload              1..4    weapon slots  (wheel cycles)
## Tab (hold)    scoreboard          Esc     release the mouse, then the menu
## H             help
## [/codeblock]

const CHANNEL := "arena.client"

## The player pressed Leave on the Escape menu.
##
## [b]Announced, and acted on by dot-menu's stock Leave[/b] ([member DotMenu.leave_on_its_own],
## set in [FcMenus]): connected, it disconnects the client link, and the shell that loaded
## this client goes back to its own menu on the disconnect; solo on a desktop it quits. This
## signal is for an embedder that wants to know. Until 2026-10-11 nothing listened to it and
## the button did nothing.
signal leave_requested()

## The level and the local player's camera exist, so the frame shows the game and not an
## empty room. A shell that knows the contract (dot-server-deploy's `_watch_game_ready`)
## keeps its loading screen up until this, then draws every material once under it so the
## shaders compile there rather than at the first shot; see [method warm_up_items]. Emitted
## again after each map change. Nothing here depends on anyone listening.
signal ready_to_show()

## dot-game's platform layer: the load gate and its cover (held until the level, the local
## body and the camera exist, then the weapon materials drawn once under it), the browser
## filesystem flush, and [signal DotGameClient.input_blocked_changed] for the sampler. Not its
## settings, menu, console, pointer or board: Fatal Contact's are [FcMenus] and
## [FcPresentation], see [method _build_platform]. The root keeps `ready_to_show` and
## `warm_up_items` only because it declares its own signal (the gate then leaves it alone) and
## because a shell older than the gate asks the root's methods, not the gate.
var platform: DotGameClient = null
var gate: DotLoadGate

## Field of view, horizontal at 4:3. Fatal Contact shooter's number, not Godot's.
const FIELD_OF_VIEW := 100.0

var game: FcGame = null
var player: FcPlayer = null
var hud: FcHud = null
## The Escape menu, its pages and the Tab board: dot-menu's ([FcMenus]).
var game_menu: DotMenu = null
## The Tab board's rows from dot-match. See [FcMenus.Board].
var board: FcMenus.Board = null
## The match summary opened the Tab board (rather than a held Tab), so the client closes it.
var _summary_board_open: bool = false
## The final killcam ([DotKillcamHost]): records every frame, plays before the summary.
var killcam: DotKillcamHost = null
## The shots that final killcam replays (flash, tracer, spark), recorded beside the bodies.
var killcam_shots: FcKillcamShots = null

## The kill view: the killer's replayed eye, in place of the death camera ([DotKillViewClient]).
var killview: DotKillViewClient = null

## Solo only: the server half of the kill view, run in this process (a connected game has the bridge's).
var solo_killview: DotKillViewSolo = null
var winner_reveal: DotWinnerReveal = null
var _reveal_hid: Dictionary = {}
var _seen_match_state: int = -1
## When the kill-cam last recorded the bodies (microseconds), for the `cl_killcam_hz` cap.
var _killcam_recorded: int = 0
## Applies dot-menu's stock settings this game does not apply itself: the window, V-Sync,
## the frame cap and render scale.
var applier: DotMenuApplier = null
var net: DotNetManager = null
var bridge: FcNetBridge = null
var link: Node = null

## Chat, voice and map changes: the client halves of what [FcServices] and
## [FcMapDirector] run on the server.
##
## [b]Null offline, deliberately.[/b] All three are about a server that is telling this
## client something, and an offline game has nobody to be told by. Building them anyway
## would open a microphone in a single-player match.
## An `fc_client_extras.gd`, typed as Node so the client does not compile it (see
## [constant FC_CLIENT_EXTRAS]).
var extras: Node = null

## Play alone even when a link is available. `--offline`.
@export var force_offline: bool = false

## How many bots to add when playing offline. Zero is an empty arena. `bot_quota` at the
## console changes it while playing (people + bots, as on a server); `-- --bots N` at launch.
@export_range(0, 1, 1, "or_greater") var offline_bots: int = 3

var _offline := true
## Null leaves the engine cap where a tool set it (tools/timescale_probe.gd --legacy).
var _tick_budget: FcTickBudget = FcTickBudget.new()
## `--sim_host 1`: the solo game as a loopback server process this client joined, else null.
var _sim_host: FcSimHost = null
## The console of that process; null in every other session.
var host_console: FcHostConsole = null
var _solo_binder: DotGameConfigBinder = null
var _workbench: Node = null
## Asks a server whether this player may edit it (sv_workbench_remote); null offline.
var _workbench_remote: DotGameWorkbenchRemoteClient = null
## The profile rows the server broadcasts (an admin's edit reaches every client); null offline.
var _profile_link: DotNetProfileLink = null
var _profile_runtime: DotProfileRuntime = null
var _workbench_open := false
var _sampler: DotFpsSampler = null
## Refuses the sights for a moment after the local player is hit (sv_unscope_hit).
var _aim_break := DotFpsAimBreak.new()
var _hit_wobble_applied := Vector2.ZERO
## Degrees of a wall-run attach turn not yet applied to the view.
var _view_turn_left := 0.0
const VIEW_TURN_RATE := 22.0
var _fire := DotWeaponCommand.new()

## A weapon slot the player asked for this tick, or 0 for "no change". Cleared once
## sent — see [method _read_fire].
var _wanted_slot: int = 0

## dot-mobile's overlay ([code]fc_touch.gd[/code]); built on every client, shown only on touch.
var _touch: RefCounted = null
## The light on the eye and the other players' beams (dot-flashlight); the server owns on/off.
var flash: DotFlashlight = null
var flash_crowd: DotFlashlightCrowd = null
var _flash_ticks := 0
var _flash_msec := -100000
var _flash_seen: Array = []
## Each player's beam as last drawn (player_id -> lit), so unlit bodies skip the muzzle and aim reads.
var _flash_lit_was: Dictionary = {}

## What the server last said was left on the clock, in seconds. Negative for "no
## limit", which is what `DotMatch.seconds_remaining` returns and what the HUD reads as
## "show the state name instead".
var _match_seconds_remaining: float = -1.0

## Seconds since the last position report. See `_process`.
var _report_timer: float = 0.0

## Whether the cursor is waiting for a click before it can be captured. Web only.
var _awaiting_click := false

## Who [member player] should be, whether or not that player exists yet.
##
## [b]HELLO names you and JOIN creates you, in that order.[/b] A client that resolved
## the player here and never tried again holds null for the whole session — and the
## list of what that breaks is the interesting part: the HUD binds by id and works, the
## camera follows the entity and works, movement works because `DotFpsSampler.sample`
## polls the `InputMap` rather than reading events, and *everything below the
## `player == null` guard in `_unhandled_input` does not*. A client that connects,
## draws, shows a live HUD and walks around, with a dead mouse and a dead keyboard.
## g2gfast shipped exactly that and a person had to report it.
var _watch_id: int = -1

## The spectator's free camera while roaming, and the mouse motion not yet turned into a look.
var _free_cam: DotSpectatorFreeCam = null
var _roam_look: Vector2 = Vector2.ZERO

## Bots this client drives, offline only. Session id -> the bot's body.
var _bots: Dictionary = {}

## Their minds (FcBots.Mind), by session id: the same brain a server's bots run.
var _bot_minds: Dictionary = {}

## Names offline bots from dot-bot's pool, and keeps their number.
var _bot_roster := DotBotRoster.new()

## The next offline bot's session id.
var _next_bot_id: int = 100

## The meshes of the map currently drawn. Replaced on a map change.
var _level: Node3D = null
## The map [member _level] was drawn from, so an announcement of the same map need not draw it again.
var _level_map: FcMap = null
var _level_busy := false
## A menu map change is under way ([method change_from_menu]): one physics tick a frame until it is done.
var _changing := false
## A menu map change on the sim host: the server builds first, so the client's frames are traced from its announcement ([method _on_map_changed]).
var _trace_hosted_change := false
## The killer's screens whose spares setup still has to build, one a frame (`KillPovView.mount`).
var _pov_spares: Array[Node] = []
## The stock figure models read on loader threads from the start of setup (`_request_figures`).
var _figure_loads: PackedStringArray = []

## The map's sun and environment (`FcMapLighting.build`), replaced with the level.
var _lighting: Node3D = null

## dot-browser's client half, and the screen over it.
var browser: FcBrowser = null

## Settings, audio, effects and the console. Everything that belongs to the person at the
## keyboard rather than to the match.
var presentation: FcPresentation = null

## Weapon model files still to read into AwModelCache under the gate (_prewarm_models); next < 0 until started.
var _model_paths: Array = []
var _model_paths_next := -1
## Next weapon whose drop bodies are parked again after a map change ([method _repool_drops]); < 0 when idle.
var _repool_next := -1
var _frame_at_usec := 0
## State of the load-gate warm-up, see [method _prewarm_tick]; empty when idle.
var _warm := {}
## The weapon views a web client builds after the cover drops ([method _late_views_tick]); empty when none are left.
var _late_views := {}
## Shot effects, charge balls and muzzle flashes built under the cover for every other player's hand
## ([method _fill_fx_pool]). A child of the client, so a map change keeps what is still parked.
var fx_pool: AwFxPool = null

## Microseconds of CPU each [method _prewarm_tick] phase spent in its own ticks (load timeline only).
var _warm_work_usec := {}

## Whether this client believes it is holding a prop.
##
## [b]A belief, not a fact, and the distinction is the whole reason props are not
## predicted.[/b] The server decides whether a grab happened; this is only what the
## next press of the same key should ask for. A rigid body's contact solver is not
## reproducible across machines, so a client that tracked a held prop's position
## locally would be corrected on every snapshot.
var _holding: bool = false

## The last `FcEvents.PropAct` a key asked the prop tool for, or -1. Noted before the
## request goes anywhere, so a suite with no server can see which key did what.
var last_prop_asked: int = -1

## The local player's hands, under their camera. Built on adoption.
var view_model: AwViewModel = null
var view_arms: Node3D = null
var _sprite_view: FcSpriteWeapon = null

## Every rocket and grenade in the air, drawn.
var projectile_view: FcProjectileView = null

## Where the dead lie: dot-player-char's ragdolls, built from each KILL's death (the server's
## pick) under [member FcGame.ragdoll_rules]. Client side.
var ragdolls: DotPlayerRagdolls = null

## The projectile layer whose detonations are being heard, so a new one is noticed.
var _heard_projectiles: RefCounted = null

## The slot in hand and the one before it, for Q. Read off the arsenal each tick, because
## the server decides what is in hand and a client that kept its own idea would switch
## "back" to a weapon the server already took away.
var _held_slot: int = 0
var _last_slot: int = 0
