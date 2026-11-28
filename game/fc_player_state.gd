@tool
extends Node3D

const Roles := preload("fc_weapon_roles.gd")
const FcFrameProbe := preload("fc_frame_probe.gd")
const FcHullGrid := preload("fc_hull_grid.gd")
const FcFlashlight := preload("fc_flashlight.gd")
const FcPlayerTunables := preload("fc_player_tunables.gd")
const FcAvatars := preload("fc_avatars.gd")
const FcTeamBodies := preload("fc_team_bodies.gd")
const FcContent := preload("fc_content.gd")
const FcKillPov := preload("fc_kill_pov.gd")
const FcAttach := preload("fc_attach.gd")
const TagRules := preload("fc_name_tag_rules.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcLadderMode := preload("../maps/fc_ladder_mode.gd")
const FcMapMechanics := preload("../maps/fc_map_mechanics.gd")
const FcSolidBody := preload("fc_solid_body.gd")
const FcWeaponIcons := preload("fc_weapon_icons.gd")
const FcSpriteWeapon := preload("fc_sprite_weapon.gd")
const FcRecoilView := preload("fc_recoil_view.gd")

## One player: movement, weapons, health and hitboxes, assembled. [b]This is the piece every one of
## the addons says belongs in the game.[/b] gs-player-controller does not know about gs-combat;
## gs-combat does not know about gs-match; none of them knows about the others' node layout.

const CHANNEL := "arena.player"

## Died. Carries the damage, so a caller has the killer and the weapon.
signal died(damage: GSDamage)

## Fired a shot. Before it is resolved, so a client can draw a tracer immediately.
signal used(outcome: GSWeaponOutcome)

## A beacon on this player sent out a ripple: once a second while it is on, and once the
## moment it comes on. Client side, from [method present]; the client plays the ping here.
signal beacon_pulsed(at: Vector3)

## Spawned or respawned.
signal spawned(at: Transform3D)

## How the collision and tracing backends are chosen.
enum Mode {
	## Analytic geometry from [FcMap]. A dedicated server, and every test. Not a degraded mode:
	## it is exact, it needs no physics space, and — the part that matters — it gives the same
	## answer on a client replaying a tick and a server that ran it.
	HEADLESS,
	## Godot physics. A client, and a listen server.
	PHYSICS,
}

@export_group("Identity")

## Stable id. A gs-server session id in a real deployment; an index in a test. The same value is
## the scoreboard key, the combat entity id and the damage attribution, which is what stops three id
## spaces having to be mapped onto each other at every seam.
@export var player_id: int = 0

@export var display_name: String = "Player"

@export var team: int = 0

var mode: Mode = Mode.HEADLESS

var controller: GSFpsController = null
var arsenal: GSWeaponArsenal = null
## Run as the player dies, while the arsenal still gives up its weapon; the game sets it.
var before_death: Callable = Callable()

## fc-weapons' rig over [member arsenal]: the bash, the view model, the shot effects
## and the replication counter. See [method _build_rig].
var weapons: AwWeaponRig = null

## The game's aim and hip-size numbers, handed to every rig built here; null keeps the addon's own.
var ads_rules: AwAdsRules = null

## Somebody else's gun, in their hand. Client side, on every player but the local one.
var held: AwWorldModel = null
var _held_sprite: FcSpriteWeapon = null

## What a MIRROR knows of this player's weapon: written from the snapshot by
## `FcPlayerNet`, read by [method _present_held]. A simulated player — the authority's,
## an offline bot — is read off its own rig instead, and leaves these alone.
var mirrored: bool = false
var mirror_weapon: StringName = &""
var mirror_fire_seq: int = 0
var mirror_fire_kind: int = 0
var mirror_switching: bool = false
var mirror_charge: float = 0.0
## The knife throw's wind-up as the figure and the view model show it: 0 to 1 while winding, below 0 when not. Written
## by whoever knows it: the server's game for a player it simulates (gs-weapon's `charge_of`), the snapshot for a
## mirror (`net_charge`), the HUD's meter for the followed player on a client.
var windup: float = -1.0
var _windup_was: float = -1.0
var mirror_reloading: bool = false
## The held gun's fitting as `net_fitted` carries it (`GSWeaponAttachments.encode`), 0 for none.
var mirror_fitted: int = 0
## The fitting code [member held] last drew, and whether it had a suppressor on (-1: not drawn yet).
var _held_fitted: int = -1
var _held_suppressed: bool = false
## [method _held_code_cached]'s last answer and the held slot, definition and attachments catalogue it was for.
var _held_code: int = 0
var _held_code_slot: GSWeaponSlot = null
var _held_code_def: GSWeaponDef = null
var _held_code_cat: GSWeaponAttachments = null
var _mode_click_audio: AudioStreamPlayer3D = null
var health: GSHealth = null
var hitboxes: GSHitboxSet = null

## Where the eyes are, and where shots start.
var view: Node3D = null

## The local player's camera. Null on a server, on a remote player, and headless.
var camera: Camera3D = null

## The view kick of the local player's shots, added to the camera only (see [FcRecoilView]).
var recoil_view := FcRecoilView.new()

## The view to draw this frame, (yaw, pitch) in degrees, or null for the simulated state's. Set
## every frame by the client from `GSFpsSampler.look_now()`. A frame with no tick in it would not
## turn: at 144 Hz against 64 ticks most frames have none (`headless_view`).
var view_now: Variant = null

## Added to where the local player is drawn this frame: what is left of the last
## prediction corrections, easing to zero (`GSNetPredictor.visual_offset`). Without it a
## correction moves the eye in one frame.
var drawn_offset: Vector3 = Vector3.ZERO

## How far through the current tick this frame is drawn (usually 0..1, -1 to 2 just after a slip),
## or NAN for the engine's physics fraction. Set every frame by a connected client from gs-net's
## `GSNetClock.render_alpha`.
var drawn_alpha: float = NAN

## Whether [method present] draws this body between its ticks: a player this machine simulates and
## somebody else watches -- an offline bot. Set by the client. An offline bot was drawn where its
## last tick left it and stood still on most frames at 144 Hz (`headless_feel`).
var interpolate_body: bool = false

## The yaw this player started its last tick with, for [member interpolate_body]: the
## controller's render state blends the position and leaves the angles at the tick's.
var _yaw_before_tick: float = 0.0

## Where this player was two ticks back, for a frame drawn before the controller's previous
## tick (a [member drawn_alpha] below 0, after a physics frame that ran two ticks). The
## controller keeps only its last two states. NAN until a tick has run since the last spawn.
var _position_two_back: Vector3 = Vector3(NAN, NAN, NAN)

## Whether this player is holding the aim (right mouse). Client side, presentation only:
## the view model eases the weapon up and the camera zooms; nothing the server simulates.
var aim_held: bool = false

## The aim, as the weapon command carries it to the server: [constant GSWeaponCommand.BUTTON_USER_0],
## which no addon reads. The client sets it beside [member aim_held]; it changes nothing
## the simulation does and exists for one medal, No Scope ([member aiming]).
const BUTTON_AIM := GSWeaponCommand.BUTTON_USER_0

## The aim on the movement command (the launch has its first user bit): the motor's
## [code]aim_button[/code], so an aimed player walks at [code]sv_ads_speed_mult[/code] on both ends.
const MOVE_BUTTON_AIM := FcPlayerTunables.AIM_BUTTON

## Whether the command this player last simulated held the aim. Both ends; the server's
## is what [code]FcAwards[/code] reads. A claim, like every button: a client can say
## it was not aiming when it was, which earns a medal and nothing else (docs/client.md).
var aiming: bool = false

## A bar over somebody else's head for a few seconds after they are hurt, the way the
## genre shows that a shot landed. Client side; built on first need.
var _health_tag: GSHealthTag = null
var _last_health: float = -1.0
var _hurt_age: float = 999.0
## What the tag was last given ([method _present_health_tag]); an unchanged, settled tag is not told again.
var _tag_told: bool = false
var _tag_frac: float = -1.0
var _tag_bar: bool = false
var _tag_named: bool = false
var _tag_name: String = ""
var _tag_friend: bool = false
var _tag_tone: Color = Color(0, 0, 0, 0)
var _tag_scale: float = 1.0
## Seconds since the cursor was last on this body (999 = never), for an enemy's hover tag to linger and fade; and the opacity the tag was told.
var _hover_age: float = 999.0
var _tag_opacity: float = 1.0
## The scale the tag is drawn at this frame: [member _tag_scale] after [method TagRules.distance_scale]'s limits on its size on screen.
var _tag_draw_scale: float = 1.0
## Where [method _place_health_tag] left the tag (as read back) and the eye it faced then; [member _tag_placed] false = place it again.
var _tag_xf := Transform3D()
var _tag_eye := Vector3.ZERO
var _tag_placed := false
## What a remote body's held gun was last told ([method _present_held]); re-told when it changes and every HELD_RETELL frames.
var _held_told: int = 0
var _held_told_id: StringName = &""
var _held_told_state: int = -1
var _held_told_charge: float = 0.0
const HELD_RETELL := 8
const HEALTH_TAG_SEC := 3.0

## The meshes a body break hid, so a respawn can draw them again. Client side.
var _broken: Array[MeshInstance3D] = []
var _severed: bool = false

## This player's body went down as a ragdoll (or was hidden by the server's style), so a
## respawn has to draw it again. Client side.
var _fell: bool = false
## When the body last went down, and whether this client has since seen the player dead: a mirror's
## death arrives by snapshot, often after the KILL, and mending on the stale alive flag stood the
## figure back up to play its own death fall, a second body.
var _down_at_ms: int = 0
var _down_seen_dead: bool = true
const DOWN_GRACE_MS := 1500

## Draws a box avatar's own body in first person ([method present_own_body]).
var _first_person: GSPlayerFirstPersonBody = null
## How much of your own body shows in first person (GSPlayerViewRules.BODY_*), from the client.
var own_body_mode: int = 0

## Third person: the camera behind and over the shoulder of the eye, kept out of the level by
## gs-core's probe, and the whole body drawn. The client sets it from the view key under the
## server's `mp_forceview`; presentation only, the simulation does not know.
var third_person: bool = false

## Layers the third-person camera stops against (the level and props). Set by the client.
var third_person_mask: int = 1

var _tp_probe: GSCameraProbe = null

## The third-person camera's place behind the eye, in the view's own axes: right, up, back.
const THIRD_PERSON_OFFSET := Vector3(0.45, 0.35, 2.6)

## The camera's own field of view, before an aim zooms it. Written by
## [method set_field_of_view] so a zoom always scales the player's setting, never itself.
var _base_fov: float = 75.0

## A displacement added to the camera this frame, and a roll. Written by the client.
var camera_offset: Vector3 = Vector3.ZERO
var camera_roll: float = 0.0

## The camera's motion cues: the landing dip, the strafe and slide roll, the wall-run lean and the
## widening with speed.
var camera_motion: GSFpsViewMotion = null

## The aim's zoom this frame, from the view model: [method present] multiplies the lens by it.
var _aim_fov_scale: float = 1.0
## What the camera takes of the aim zoom: all of it with the full-screen scope, none with the scope lens, which zooms in its own camera.
var _view_fov_scale: float = 1.0
## The scoped breath's turn of the view in degrees (x yaw, y pitch), presentation only; the aim the server reads never has it.
var _scope_breath := Vector2.ZERO

## What a remote player is drawn as. Null on the local player, who sees their own eyes.
var body_mesh: Node3D = null

## The person drawn in [member body_mesh]: gs-player-char's people, the family's one style for
## players, bots and NPCs, coloured from [member avatar] by `FcAvatars.look_of`. Null on a
## server, and for the capsule a build without the people's art falls back to.
var figure: GSHumanoidFigure = null

## What this player looks like, as a gs-user-avatar document; null is the stock figure. Set on a
## server from the identity layer and carried to every client in JOIN, so a member who dressed on
## the site is that figure on every screen.
var avatar: GSAvatar = null

## An administrator's `blind`: this player's own screen is blacked out. [b]Set on the server and
## replicated to the OWNER ONLY[/b] (`FcPlayerNet.net_blind`).
var blinded: bool = false

## The achievement this player is nearest to, for the HUD's challenge bar: an index into
## `FcAwards.catalogue()` (-1: none), and how far along it they are. Set by FcProgress on
## the server, replicated to the owner alone.
var challenge: int = -1
var challenge_value: int = 0

## The app's points (the site's per-app currency) for the HUD: whether the app has them on for this
## player and the balance. Set on the server from the site's signed grant (fc_app_wiring.gd) and
## replicated to the owner alone (`FcPlayerNet.net_app_points`); never earned or spent here.
var app_points_on: bool = false
var app_points: int = 0

## An administrator's `beacon`: a pulsing ring and a column over this player that every client
## draws, and a ping every client hears, until it is turned off. Set on the server and replicated to
## everybody (`FcPlayerNet.net_beacon`), who each draw it in [method present].
var beacon: bool = false

## Whether to draw the spawn-protection bubble round this player. The server decides it (protected and
## `spawn_protection_bubble`) and replicates it (`FcPlayerNet.net_protected`).
var protected_view: bool = false

## The bubble node while one is drawn. See [method _present_bubble].
var protection_bubble: GSSpawnBubble3D = null

## The marker [member beacon] draws, while it does. Client side; built and freed by
## [method present].
var beacon_marker: GSFxBeacon = null

## Whether this player's flashlight is on. The server decides it ([method switch_flashlight]) and
## replicates it ([member FcPlayerNet.net_flashlight]); everyone draws the beam from it.
var flashlight: bool = false
## Whether the map's starting state has been applied to [member flashlight] yet.
var flashlight_ready: bool = false
var flashlight_charge: float = 1.0
var _flashlight_held: bool = false
## The flashlight config the switch obeys; set only where the game decides (offline, the server).
var flashlight_cfg: GSFlashlightConfig = null
var flashlight_map: String = ""

## The movement this player was built with, before any class scaled it. See [method
## apply_class_movement]. Captured on the first application rather than at build time, so a game
## that never uses classes never builds one.
var _class_base: ClassBase = null


## The numbers a class scales, as they were before it scaled them (`GSPlayerClassApply.to_movement` reads only `max_speed` and `jump_height`
## from its base). [b]Not a duplicate of the tunables[/b]: 31 `GSFpsTunables.duplicate()` calls at a round start were most of the spawn
## signal. A new scaled field in gs-player-class is a field added here.
class ClassBase extends RefCounted:
	var max_speed := 0.0
	var jump_height := 0.0

## Swimming, in an imported map's water.
var swim := GSFpsSwimMode.new()

## Climbing, on an imported map's ladders. Registered beside [member swim], after it, in
## that order everywhere: the order is the id.
var ladder := FcLadderMode.new()

var _map: FcMap = null
## The crouch scale the hitboxes were last fitted to (-1: refit); the fit is a pure function of it.
var _fit_k := -1.0
var _combat: GSCombatManager = null
var _hand: Node3D = null
var _seen_fire_seq: int = 0
var _command := GSWeaponCommand.new()
## A late shot's own aim (yaw, pitch), used for one tick in place of the current view; NAN x means none.
var late_fire_aim := Vector2(NAN, 0.0)
## The weapon a client's firing command says it fired with (FcNetCommand.weapon, [method FcContent.weapon_index]), settled in hand
## before this tick's weapon tick judges the shot; 0 for none. Set on the authority only, used for one tick.
var fire_weapon: int = 0
## Ticks a server's switch may trail the client's and still be settled for the client's shot (FcPlayerBody._settle_fired_weapon); 0 settles only a switch
## run for the whole deploy here. About the input copies' reach under loss.
var fire_settle_slack_ticks: int = 8
## Shots whose weapon was settled in hand that way; a server's diagnostic.
var fire_settled: int = 0
var _switch_seen_tick: int = -1
var _tick_rate: int = FcContent.TICK_RATE

## A [GSFpsController] that collides against analytic geometry rather than physics. `_make_body` is
## gs-player-controller's documented seam for exactly this, and using it is what lets the same
## [FcPlayer] run on a dedicated server with no physics space and in a client with one.
class HeadlessController extends GSFpsController:
	var flat_body: GSFpsBody = null

	func _make_body() -> GSFpsBody:
		return flat_body

## The other players' standing hulls this player's sweeps stop at (`Array[AABB]`, its own left out;
## empty while `mp_solidplayers` is 0). Set by the game that holds the player ([method
## FcGame.solid_hulls_for]); unset, nobody is solid to this player.
var solid_hulls_fn: Callable = Callable()

## The tick [method simulate_tick] is running, replays included: where a predicting client
## places the remotes it collides with ([method FcGame.solid_hulls_for]), and the clock the
## jail's gate is asked on ([method game_tick]).
var _hull_tick: int = -1

## The game tick this player was last simulated on, -1 before the first: the server's tick, and on a
## predicting client the same number, replays included. Unlike [code]GSFpsState.tick[/code] (per
## machine, not replicated) it is equal on both ends, so the jail's gate is asked on it.
func game_tick() -> int:
	return _hull_tick

## gs-sim's hull world ([method FcGame._begin_hull_world]) this player is filed in as [member hull_slot] while the players' loop runs; a death or a spawn is written to it.
var hull_world: Object = null
var hull_slot: int = -1
## The movement body [member hull_world] was last given to, its slot, and whether the body took it.
var _hull_body: GSFpsBody = null
var _hull_body_slot: int = -1
var _hull_body_ok := false

const MOVEMENT_RULES: PackedStringArray = FcPlayerTunables.MOVEMENT_RULES
const BODY_RULES := FcPlayerTunables.BODY_RULES
const SURF_TUNABLES := FcPlayerTunables.SURF_TUNABLES

## How far under an imported map's bounds a player is counted as out of it, metres.
const FALL_OUT_DEPTH := 10.0

var _max_health := 100.0
var _max_armour := 100.0
var _regen := 0.0
var _fall_out_depth := FALL_OUT_DEPTH

## One unit of the engine the combat surf maps come from, in metres.
const GENRE_UNIT := 0.01905

## What a server set for the body pose, kept so a body made later wears it.
var _body_rules: Dictionary = {}

## Poses every drawn body (the person's own in third person, and everyone else's) while it wall
## runs: a [GSFpsViewMotion] used only for [method GSFpsViewMotion.body_roll] and `body_yaw`.
var body_motion: GSFpsViewMotion = null

## How many arsenal slots a player has: the pack's five.
const MAX_SLOTS := AwWeaponIds.SLOT_THROWN ## the highest slot either layout uses

## The shared weapon table, built once for the whole process. Validated on first use rather than per
## player, and loudly: a catalogue with a duplicate id hands somebody the wrong weapon and nothing
## reports it.
static var _shared_catalogue: GSWeaponCatalogue = null
static var _shared_generation := -1
## Whether every behaviour script of [member _shared_catalogue] is loaded (see [method warm_catalogue_step]).
static var _shared_warm := false

## How far behind the eye your own body is drawn in first person, in metres: far enough that the
## chest under a hidden neck stays out of the near plane.
const FIRST_PERSON_BACK := 0.18
## The same with only the legs drawn: nothing above the belly reaches the near plane, and further back the feet leave the view.
const FIRST_PERSON_BACK_LEGS := 0.0

## Extra metres the body trails behind as the view tips past 60 degrees down, full at 85:
## straight down, the open hips (the cut where the belly bone is gone) would fill the screen.
@export var first_person_look_down_back: float = 0.45
## cl_fp_look_down_back: a value of 0 or more replaces the export for every player on this client.
static var look_down_back_override: float = -1.0

## Whether [method present_lod] may thin out the bodies nobody is looking at.
static var present_lod_enabled: bool = true

## The server's players' loop without the per-player calls that change nothing: the surf rides follow the map once a tick
## instead of once per player, and the map mechanics leave the node where the controller put it unless they moved the
## state. Off runs the long way; the results are the same. `tools/scale128.gd --leanab` flips it for an in-process A/B.
static var lean_tick: bool = true

## Probe only (`tools/client_cost.gd`): when true a remote body is not presented at all, to measure what presenting them costs.
static var present_remote_paused: bool = false

## Probe only: parts of a remote body's presentation switched off to find what each costs (bit 1 the figure's animation, 2 the held
## gun's update, 4 the held gun's own per-frame process, 8 the pose/tag/beacon rest). 0 in the game.
static var present_ablate: int = 0

## `cl_held_equips`: most remote bodies that build a new held gun in one frame (0: no limit). A
## respawn wave changes a dozen bodies' guns at once, and each build instances a model, so the
## rest wait a frame or two holding the old one instead of one frame taking all of them.
static var held_equips_per_frame: int = 2
static var _held_equip_frame: int = -1
static var _held_equips_used: int = 0

## Whether one more remote body may build its held gun this frame, and counts it.
static func held_equip_allowed() -> bool:
	if held_equips_per_frame <= 0:
		return true
	var frame := Engine.get_process_frames()
	if frame != _held_equip_frame:
		_held_equip_frame = frame
		_held_equips_used = 0
	if _held_equips_used >= held_equips_per_frame:
		return false
	_held_equips_used += 1
	return true

## A held gun stops drawing past this many metres (0: no limit), its attachments too. In a browser
## [constant WEB_HELD_DRAW_RANGE]: there a gun is a few pixels, and each one is several draw calls a frame
## (body, parts, attachments), which a browser's WebGL pays for far more than a native driver does.
const WEB_HELD_DRAW_RANGE := 30.0
static var held_draw_range: float = WEB_HELD_DRAW_RANGE if GSPlatform.is_web() else 0.0
## Whether a held gun casts a shadow. Not in a browser: the sun's shadow pass draws every gun a second time,
## and the body holding it still casts its own.
static var held_shadows: bool = not GSPlatform.is_web()

## `cl_figure_draw_range`: the figure's draw range (gs-player-char 27 reads it live), mirrored here for the per-frame
## test that hides a gun and crest past it. 0: drawn at every distance.
static var figure_draw_range: float = GSHumanoidFigure.DRAW_RANGE
## `cl_figure_lift_range`'s default: past it, or out of view, a remote body stands on the floor only on the frames its
## clip steps (a 64-player crowd cast a floor ray per body per frame).
const FIGURE_LIFT_RANGE := 22.0
## `cl_figure_lift_range`, handed to the figure when the console's variables are made (a bench sets it before that).
static var figure_lift_range: float = FIGURE_LIFT_RANGE

## `cl_remote_lod_frustum`: judge "out of sight" by the camera's real frustum instead of the cone below.
static var lod_frustum: bool = true

## `cl_remote_occlusion`: a body inside the frustum but behind the level's solid world (chest, head and knee rays all
## blocked, refreshed every [constant OCCLUSION_RECHECK_MSEC]) counts as out of sight. Source's dormant/PVS cull, done
## with three rays per body per refresh. Drawing only: the tick and the hitboxes are never touched.
static var occlusion_enabled: bool = true
const OCCLUSION_RECHECK_MSEC := 100
var _occluded: bool = false
var _occlusion_next_msec: int = 0

## `cl_remote_lod_every`: frames between presents of a body out of sight (1 turns the off-screen thinning off).
## In a browser [constant WEB_LOD_OFF_EVERY]: an unseen body's pose matters only to the killcam and a glance back.
const WEB_LOD_OFF_EVERY := 8
static var lod_off_every: int = WEB_LOD_OFF_EVERY if GSPlatform.is_web() else 4

## A remote body nearer than this (metres) is always drawn in full.
const LOD_NEAR := 6.0
## A body further than this cosine off the view axis is out of sight (about 78 degrees).
const LOD_CONE := 0.2
## Frames between presents of a body out of sight.
const LOD_EVERY := 4
## Metres round a body's chest that count as it for the frustum test (a body, its gun, the swing of an arm).
const LOD_RADIUS := 1.6

## Past these distances (metres) a body is drawn every second / fourth frame even in plain view:
## at 45 m a player is a few dozen pixels and 5 fps of animation is not seen.
const LOD_FAR := 45.0
const LOD_FARTHEST := 90.0

## `cl_remote_anim_gate`: thin remote bodies by game time as well as by frame count. A body in view past [constant ANIM_GATE_NEAR] steps its clip at most every [constant ANIM_GATE_DT], past [constant ANIM_GATE_FAR] (and in the
## LOD_FAR tiers) every [constant ANIM_GATE_FAR_DT]; a thinned one waits its minimum time. Only the skeleton's clip is stepped less often: the body is still moved and turned every frame, and hitboxes follow the stance, not the bones.
static var anim_gate_enabled: bool = true
const ANIM_GATE_NEAR := 8.0
const ANIM_GATE_DT := 1.0 / 30.0
const ANIM_GATE_FAR := 20.0
const ANIM_GATE_FAR_DT := 1.0 / 20.0
## A body nobody can see (out of the frustum past LOD_NEAR) steps its clip at most 10 times a second: only its
## shadow could show the pose, and it is presented in full the frame it comes into view.
const ANIM_GATE_OFF_DT := 1.0 / 10.0
## Minimum game seconds between presents of a thinned body: out of sight, past LOD_FAR, past LOD_FARTHEST.
const LOD_OFF_DT := 1.0 / 30.0
## In a browser a gated body also steps its clip only every [constant WEB_ANIM_GATE_EVERY]th time it is presented: there
## the frame is longer than [constant ANIM_GATE_DT] already, so the time gate alone never skips, and each step re-skins the
## body, which WebGL pays for heavily. Native keeps 1 (the time gate alone).
const WEB_ANIM_GATE_EVERY := 2
static var anim_gate_every: int = WEB_ANIM_GATE_EVERY if GSPlatform.is_web() else 1
const LOD_FAR_DT := 1.0 / 45.0
const LOD_FARTHEST_DT := 1.0 / 30.0

## `cl_remote_still_anim_hz`: a remote body standing still (no speed, the same yaw, pitch, crouch and shots as last present, for [constant STILL_AFTER_SEC]) past [constant ANIM_GATE_NEAR] steps its
## clip at most this many times a second: Source's cached SetupBones, where unchanged inputs reuse last frame's bones. Only an idle loop is thinned; any change wakes it the same present, with the
## skipped time carried. 0 turns it off.
static var still_anim_hz: float = 10.0
## Seconds a body must stay still before it is thinned, so the blend into the idle (a stop, a landing) plays at full rate.
const STILL_AFTER_SEC := 0.4
## Below this speed squared (m/s) a body counts as standing.
const STILL_SPEED2 := 0.0025
## `cl_remote_pose_skip`: a remote body whose drawn yaw and lean did not change keeps its placement instead of being
## written again (1, the default); 0 writes it every present.
static var pose_skip_enabled: bool = true
## Degrees of wall-run lean or turn below which the lean counts as eased out.
const POSE_SETTLED_DEG := 1e-3

## `cl_remote_lod_scale`: every LOD and animation-gate distance above (all but [constant LOD_NEAR]) times this; under 1 thins
## nearer bodies. Must be above 0.
static var lod_scale: float = 1.0
## `cl_remote_lod_crowd`: above this many players the distances are also times [member lod_crowd_scale] (0: never). At 64 a
## frame presents a few dozen bodies in view, and a body 30 m off is a few dozen pixels whose clip at 20 Hz nobody tells apart.
static var lod_crowd_players: int = 32
## `cl_remote_lod_crowd_scale`: the distance factor above [member lod_crowd_players] players (1: as few). Must be above 0.
static var lod_crowd_scale: float = 0.67
## The squared tier distances this frame, from [method set_lod_crowd] (the constants times the scales).
static var _lod_far2: float = LOD_FAR * LOD_FAR
static var _lod_farthest2: float = LOD_FARTHEST * LOD_FARTHEST
static var _anim_far2: float = ANIM_GATE_FAR * ANIM_GATE_FAR
static var _anim_near2: float = ANIM_GATE_NEAR * ANIM_GATE_NEAR

## The distance factor for [param players] in the game: [member lod_scale], times [member lod_crowd_scale] in a crowd.
static func lod_distance_scale(players: int) -> float:
	var s := lod_scale
	if lod_crowd_players > 0 and players > lod_crowd_players:
		s *= lod_crowd_scale
	return s

## Sets this frame's tier distances for a game of [param players]; the client calls it once a frame before the presents.
static func set_lod_crowd(players: int) -> void:
	var s := lod_distance_scale(players)
	var s2 := s * s
	_lod_far2 = LOD_FAR * LOD_FAR * s2
	_lod_farthest2 = LOD_FARTHEST * LOD_FARTHEST * s2
	_anim_far2 = ANIM_GATE_FAR * ANIM_GATE_FAR * s2
	_anim_near2 = ANIM_GATE_NEAR * ANIM_GATE_NEAR * s2

## `cl_remote_lod_native`: judge every remote body's tier, beyond-figure bit and need for an occluder ray in one gs-sim call per
## frame ([method classify_crowd]) instead of per body in script. The answers are the script's to the bit; off, or with no
## `GSSimPresentLod` in the library, [method present_lod] judges each body itself.
static var present_native: bool = true
static var _crowd_lod: RefCounted = null
static var _crowd_positions := PackedVector3Array()
static var _crowd_planes: Array[Plane] = []
## `cl_remote_present_native`: with [member present_native], thin the whole crowd in the same gs-sim object
## ([method present_crowd]): it keeps every body's frame count between frames and hands back only the bodies to present, so a
## skipped body costs no script call at all. Off, or with an older library, each body thins itself ([method present_lod_coded]).
static var present_schedule_native: bool = true
## One id per body of the last [method classify_crowd]: its instance id, 0 for the viewer's own (never thinned).
static var _crowd_ids := PackedInt64Array()
static var _crowd_hidden := PackedInt32Array()
## Whether the native object holds this crowd's thinning: false after a frame thinned in script, so the next native frame
## starts every body afresh rather than from counts and bits the script has since moved on from.
static var _crowd_scheduled := false

## One code per body of [param bodies] (see `gs_sim_present`: tier in the low three bits, [constant CODE_BEYOND_FIGURE],
## [constant CODE_OCCLUSION]) judged from [param eye] along [param forward], from this frame's tier distances, or an empty
## array when the native pass is off or absent. Call [method set_lod_crowd] first.
static func classify_crowd(bodies: Array, eye: Vector3, forward: Vector3, frustum: Array) -> PackedInt32Array:
	if not present_native or not present_lod_enabled:
		return PackedInt32Array()
	if _crowd_lod == null:
		if not GSSim.has(&"present"):
			return PackedInt32Array()
		_crowd_lod = ClassDB.instantiate(&"GSSimPresentLod")
	var n := bodies.size()
	_crowd_positions.resize(n)
	_crowd_ids.resize(n)
	for i in n:
		var body: Node3D = bodies[i]
		_crowd_positions[i] = body.global_position
		_crowd_ids[i] = 0 if body.get(&"camera") != null else body.get_instance_id()
	_crowd_planes.assign(frustum)
	var range2 := figure_draw_range * figure_draw_range if figure_draw_range > 0.0 else 0.0
	return _crowd_lod.classify(_crowd_positions, eye, forward, _crowd_planes, PackedFloat64Array([
		LOD_NEAR * LOD_NEAR, LOD_CONE, LOD_RADIUS, _lod_farthest2, _lod_far2, _anim_far2, _anim_near2, range2,
		1.0 if lod_frustum and not frustum.is_empty() else 0.0, 1.0 if occlusion_enabled else 0.0]))

## Presents this frame's crowd by the codes [method classify_crowd] just made for the same [param bodies], thinned in gs-sim exactly as each
## body's [method present_lod_coded] would. Returns false, having presented nothing, when the native thinning is off or absent or remote
## bodies are paused: the caller then presents per body.
static func present_crowd(bodies: Array, delta: float, eye: Vector3) -> bool:
	if not present_schedule_native or present_remote_paused or _crowd_lod == null or not _crowd_lod.has_method(&"schedule") \
			or _crowd_ids.size() != bodies.size():
		forget_crowd()
		return false
	if not _crowd_scheduled:
		_crowd_lod.reset()
		_crowd_scheduled = true
	_crowd_hidden.clear()
	for i: int in _crowd_lod.occlusion_candidates():
		if _crowd_ids[i] != 0 and bodies[i]._behind_world(eye):
			_crowd_hidden.append(i)
	var rows: PackedFloat64Array = _crowd_lod.schedule(_crowd_ids, _crowd_hidden, delta, PackedFloat64Array([
		lod_off_every, LOD_OFF_DT, LOD_FARTHEST_DT, LOD_FAR_DT, ANIM_GATE_OFF_DT, ANIM_GATE_FAR_DT, ANIM_GATE_DT,
		1.0 if anim_gate_enabled else 0.0]))
	for bit: int in _crowd_lod.beyond_changes():
		var b = bodies[bit >> 1]
		b._set_beyond_figure(b.figure != null and (bit & 1) != 0)
	for bit: int in _crowd_lod.held_changes():
		bodies[bit >> 1]._set_held_lod((bit & 1) != 0)
	var r := 0
	while r < rows.size():
		var b = bodies[int(rows[r])]
		var anim := rows[r + 2]
		if not is_nan(anim):
			b._anim_min_dt = anim
		b.present(rows[r + 1])
		r += 3
	return true

## Marks the native thinning stale: the next [method present_crowd] starts every body afresh.
static func forget_crowd() -> void:
	_crowd_scheduled = false

## Drops the native judge and its scratch arrays (a suite's exit, a library reload).
static func release_crowd() -> void:
	_crowd_lod = null
	_crowd_scheduled = false
	_crowd_positions = PackedVector3Array()
	_crowd_planes = []
	_crowd_ids = PackedInt64Array()

## Whether this body's present is being held back by the thinning right now (a frame or more owed).
func lod_held() -> bool:
	if _crowd_scheduled and _crowd_lod != null:
		var slot: PackedFloat64Array = _crowd_lod.slot_state(get_instance_id())
		if not slot.is_empty():
			return slot[0] > 0.0
	return _lod_frames > 0

## Tells the native thinning to hand this body its held-gun and figure-range bits again: the figure or gun they act on was
## just rebuilt. The script path needs nothing (it sets both on every present).
func _refresh_crowd_bits() -> void:
	if _crowd_scheduled and _crowd_lod != null and _crowd_lod.has_method(&"refresh"):
		_crowd_lod.refresh(get_instance_id())

const CODE_BEYOND_FIGURE := 8
const CODE_OCCLUSION := 16

var _figure_motion: Dictionary = {}
var _anim_min_dt: float = 0.0
var _anim_owed: float = 0.0
## Per-body head start (game seconds) on the first gated step, so that bodies gated on the same frame
## (a round start) do not all step their clips together on one frame.
var _anim_phase: float = -1.0
## Presents since the clip last stepped under the gate (-1: not gated yet; the first count is per body, see [member _anim_phase]).
var _anim_frames: int = -1
var _held_thin: bool = false
## What the still test compared last present (yaw, pitch, crouch, mode as x/y/z/w), the shot count, and how long it has held.
var _still_key: Vector4 = Vector4(NAN, NAN, NAN, NAN)
var _still_seq: int = -1
var _still_for: float = 0.0
## A remote body past [constant GSHumanoidFigure.DRAW_RANGE] from the eye: its figure is culled there, so
## what hangs off it (gun, held sprite, crest, spawn bubble) is hidden too rather than floating alone.
var beyond_figure: bool = false
var _crest: Node3D = null
var _lod_frames: int = 0
var _lod_delta: float = 0.0

var _figure_fire_seq: int = 0
## The weapon the figure's hold was last set for, and that hold (-1 until set).
var _figure_hold_id: StringName = &""
var _figure_hold_kind: int = -1

## How a stair tread's rise reaches the eye: the time constant of an exponential, seconds.
## The step is the simulation's at once; only the view eases (as `GSFpsView.smooth_step_up` does in
## gs-player-controller's camera; this game writes its own in `present`). `headless_feel` measures it.
var step_smooth_time: float = 0.05

## The part of recent stair steps not yet shown, metres: subtracted from the eye, easing to 0.
var _step_offset: float = 0.0
## The tick whose step is being drawn, its rise if it was a stair step (else 0), and how much
## of that rise this frame's interpolation has already drawn.
var _step_tick: int = -1
var _step_rise: float = 0.0
var _step_drawn: float = 0.0

## A landing the eye has not reached yet: its impact (0 for none) and the tick it came on.
var _landing_impact: float = 0.0
var _landing_tick: int = -1

## How far a watched gun kicks per kind of use. The real recoil is on an outcome that does
## not travel, so a watcher's is approximate on purpose — the same numbers the pack gives
## its own watchers, kept here because the pack's copy is private to it.
const WATCHED_RECOIL := {
	AwWeaponNet.KIND_SWING: Vector2(1.2, 0.0),
	AwWeaponNet.KIND_SPAWN: Vector2(2.0, 0.0),
	AwWeaponNet.KIND_THROW: Vector2(2.0, 0.0),
	AwWeaponNet.KIND_BEAM: Vector2(0.05, 0.0),
}

## Where [method attachment]'s hand is, in the body's frame. -Z is the way they face.
const HAND_POSITION := Vector3(0.26, 1.12, -0.34)
