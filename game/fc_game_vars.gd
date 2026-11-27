@tool
extends "fc_game_state.gd"

const FcFlashlight := preload("fc_flashlight.gd")
const FcFrameProbe := preload("fc_frame_probe.gd")
const FcHullGrid := preload("fc_hull_grid.gd")
const FcNativeTick := preload("fc_native_tick.gd")
const FcShotStats := preload("fc_shot_stats.gd")
const HULL_NEAR_SQ := 144.0

## Beyond this a hull cannot touch one tick's sweep (top speed times a tick, plus both radii, with room to spare).
const HULL_REACH_SQ := 16.0

## The kill view (gs-replay's `mp_killview*`): on in this game. Bound by the module (REPLICATED), followed by the client.
var killview_rules: GSKillViewRules = _make_killview_rules()

## `sv_falldamage*`: landing hard hurts, except on a surf map (ramps land fast by design).
## On here, off in gs-combat's default; the server applies it, a client never does.
var fall_rules: GSFallDamageRules = make_fall_rules()

## Landing on a head (`sv_stomp*`, the cfg `stomp_*` keys); the numbers are copied from [member config] each tick.
var stomp := GSStomp.new()
var _pre_vy: Dictionary[int, float] = {}
## Where each player's saved loadouts are filed (a stable key when they have one).
var loadout_identity := FcLoadoutIdentity.new()

## Movement-dependent spread, recoil patterns and the spread crosshair (gs-game's opt-in; sv_spread_*, sv_recoil_*, on here).
var combat_feel: GSGameCombatFeel = _make_combat_feel()

## Shots fired against damage applied, per shooter (bots and players): the counter behind `fc_shot_stats`.
var shot_stats := FcShotStats.new()

## Ammo profiles (`cfg/game/game-fatal-contact/ammo`): what each gun's round can penetrate, read by the hitscan behaviour.
var ammo_types: GSWeaponAmmoTypes = _load_ammo_types()

const LOADOUT_COMMAND_SCRIPT := "res://addons/gs_loadout/integrations/gs_loadout_command.gd"

## A client behind a loading cover sets this and calls [method build_map_io_async], so the movers are not one long frame.
var defer_map_io := false

## Server bot session ids start here; stats and progress never count them.
const BOT_SESSION_BASE := 900_000_000

## Rules about what a death and a body look like, carried in the same set as the
## movement ones (RULES) because a client draws them and the server owner sets them:
## `break_mode` 0 none / 1 limbs / 2 explode, `break_limbs`, `break_criticals_only`, and
## `fp_body` (your own body in first person). Defaults in [constant SHOW_DEFAULTS].
##
## `surf` and `surf_air_accelerate` ride the same set because a client PREDICTS with them:
## `surf` 1 plays a combat surf map with the genre's air control and 0 with Fatal Contact's own
## (`fc_surf`), `surf_air_accelerate` is that air control's `sv_airaccelerate`
## (`fc_surf_airaccelerate`). See [method map_movement].
##
## `nametags` and `hpbars` are the server's ceilings on when those tags draw (`mp_nametags`, `mp_hpbars`;
## masks of `fc_name_tag_rules.gd`, 1 = no limit).
##
## The tags' look is rules too (`mp_enemy_bar_mode`, `mp_enemy_name_mode`, `mp_hover_range`, `mp_hover_hold`, `mp_hover_fade`, `mp_team_bar_*`,
## `mp_show_team_names`, `mp_tag_fade_*`; see `fc_name_tag_rules.gd`).
##
## `fp_arms` is the arm set every first-person view draws (`fc_fp_arms`): 0 each player's own look, N one stock set.
##
## `team_avatars` forces each side's body in a team mode (`fc_team_avatars`, 1) and `team_tint` is how far it
## turns toward the side's colour (`fc_team_tint`); see fc_team_bodies.gd.
## `team_body_a` / `team_body_b` bind a registered body (index into `team_bodies`) to the first and second
## side, -1 the config order; the app's avatars settings set them (fc_app_wiring.gd).
##
## `killcam` is the final killcam's seconds (`mp_killcam_time`, 0 off): clients play it, and the
## authority adds it to the match's end ([method _override_rules]).
const SHOW_RULES: PackedStringArray = ["break_mode", "break_limbs", "break_criticals_only", "fp_body", "mode_index", "surf", "surf_air_accelerate", "killcam", "max_unlag_ms", "fire_buffer", "nametags", "hpbars", "fp_arms", "team_avatars", "team_tint", "team_body_a", "team_body_b", "enemy_bar_mode", "enemy_name_mode", "hover_range", "hover_hold", "hover_fade", "team_bar_offset_y", "team_bar_width", "team_bar_height", "team_bar_style", "show_team_names", "tag_fade_start", "tag_fade_end"]
const SHOW_DEFAULTS := {"break_mode": 1.0, "break_limbs": 1.0, "break_criticals_only": 1.0, "fp_body": 0.0, "surf": 1.0, "surf_air_accelerate": 150.0, "killcam": 7.0, "nametags": 1.0, "hpbars": 1.0, "fp_arms": 0.0, "team_avatars": 1.0, "team_tint": 0.65, "team_body_a": -1.0, "team_body_b": -1.0, "enemy_bar_mode": 0.0, "enemy_name_mode": 1.0, "hover_range": 80.0, "hover_hold": 0.35, "hover_fade": 0.25, "team_bar_offset_y": -0.3, "team_bar_width": 0.8, "team_bar_height": 0.065, "team_bar_style": 1.0, "show_team_names": 1.0, "tag_fade_start": 25.0, "tag_fade_end": 60.0}

## The mode a client is told is being played, for its banner and its keys. A client's own
## [member mode] is whatever it was built with and is never replaced — logic reads it —
## so what it shows comes from here. On the authority it is the mode.
var shown_mode: FcMode = null

var _roster: Array[FcPlayer] = []
var _roster_ids := PackedInt64Array()
var _roster_dirty := true
## Roster index by player id, rebuilt with [member _roster].
var _roster_at: Dictionary[int, int] = {}
## [method _add_hulls_local]'s pair answers this tick, row-major by roster index: 0 unasked, 1 blocks, 2 passes.
var _pair_memo := PackedByteArray()
var _pair_memo_tick: int = -1
var _pair_memo_fn: Callable = Callable()
## Where the players stand, for [method solid_hulls_for] while the players' loop runs ([FcHullGrid]).
var _hull_grid := FcHullGrid.new()
## gs-sim's `GSSimHullWorld` for the players' loop ([method _begin_hull_world]), and its per-slot data.
var _hull_world: Object = null
var _hull_world_data := PackedFloat64Array()
## The players' motors ticked in runs of one native call ([method _tick_players_batched]), and each roster slot's row and commands.
var _motor_batch: GSFpsMotorBatch = null
var _batch_rows := PackedInt32Array()
var _batch_pairs: Array[Array] = []
## gs-sim's server tick (`sv_native_motor_state`): holds the batch's resident motor rows and the player table, stepped once a tick after the batched loop.
var _native_tick := FcNativeTick.new()
var _native_tick_on := false
## `sv_native_players`: gs-player-controller's batched call over every player's controller (null until first used, or
## without it), its controllers column, its three hooks (made once) and the tick's loop state they read.
var _ctl_batch: RefCounted = null
var _ctl_controllers: Array[GSFpsController] = []
var _ctl_tried := false
var _pc_pre_fn := Callable()
var _pc_live_fn := Callable()
var _pc_post_fn := Callable()
var _pc_ids: Array[int] = []
var _pc_commands: Dictionary = {}
var _pc_shots: Array[GSShot] = []
var _pc_hull_world: Object = null
var _pc_post_from: Object = null
var _pc_delta := 0.0
var _pc_knife := false
var _pc_surfing := false
var _pc_fine := false
var _pc_post_lane := false
var _pc_mark_due := false
## The batched loop's motor edges for every player ([member FcHullGrid.events]): one row per player's tick, derived and dispatched after the loop.
var _tick_events := GSFpsTickEvents.new()
## The batched loop's idle weapon ticks waiting on one gs-sim posture call ([method _flush_posts]): its
## `GSSimPlayerPost`, the input rows (10 floats each) and each one's player, id and move command.
var _post_native: Object = null
## Which batched players are clear of the map's volumes this tick (cvar fc_mechanics_native).
var _volume_pre := preload("fc_volume_prefilter.gd").new()
var _post_in := PackedFloat64Array()
var _post_players: Array[FcPlayer] = []
var _post_ids := PackedInt64Array()
var _post_moves: Array[GSFpsCommand] = []
## The idle weapons' batch ([member FcPlayer.weapon_idle_batch]): gs-sim's runner, its flat entries, each entry's player
## and each posted player's outcome.
var _idle_batch: Object = null
var _idle_entries: Array = []
var _idle_owners: Array[FcPlayer] = []
var _idle_outs: Array[GSWeaponOutcome] = []
var _demo_gated := false


## Rebuilds [member _roster] (the players in join order, and their ids) after a join or a leave.
func _ensure_roster() -> void:
	if not _roster_dirty:
		return
	_roster.clear()
	_roster_ids.resize(0)
	_roster_at.clear()
	for key: Variant in _players.keys():
		_roster_at[int(key)] = _roster.size()
		_roster.append(_players[key])
		_roster_ids.append(int(key))
	_roster_dirty = false
	_pair_memo_tick = -1
	_hull_grid.live = false
## The sorted ids of [member _players], rebuilt when somebody joins or leaves ([method player_ids]); empty means stale.
var _ids_cache: Array[int] = []

# --- Toys --------------------------------------------------------------------

## A toy's blast at its centre, m/s to a toy of up to 3 kg (gs-props' `blast`).
const TOY_BLAST_SPEED := 12.0

## The sprint rules start from this game's own tunables, so loading them (for `sv_sprint_shoot` and `sv_sprint_barrel`) leaves the speeds as they were.
static func _make_combat_feel() -> GSGameCombatFeel:
	var feel := GSGameCombatFeel.new(true, true)
	feel.sprint_defaults(FcPlayer.fc_tunables())
	return feel

static func _load_ammo_types() -> GSWeaponAmmoTypes:
	var types := GSWeaponAmmoTypes.new()
	var _n := types.load_set(GSWeaponAmmoTypes.make_set("", "game-fatal-contact"))
	return types

# --- Players ---------------------------------------------------------------

static func make_fall_rules() -> GSFallDamageRules:
	var rules := GSFallDamageRules.new()
	rules.enabled = true
	# Wall-runs and ramps make drops routine here: a higher threshold, a cap, and no lethal speed.
	rules.threshold = 16.0
	rules.scale = 3.0
	rules.max_damage = 50.0
	return rules

static func _make_killview_rules() -> GSKillViewRules:
	var rules := GSKillViewRules.new()
	rules.enabled = true
	return rules
