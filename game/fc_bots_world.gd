extends "fc_bots_world_sight.gd"

const FcContent := preload("fc_content.gd")


const FcPlayer := preload("fc_player.gd")
const FcBotBrain := preload("fc_bot_brain.gd")
const FcHullGrid := preload("fc_hull_grid.gd")
const FcBotPvs := preload("fc_bot_pvs.gd")
const FcBotRows := preload("fc_bot_rows.gd")


## The behaviour of a weapon whose shot flies (a rocket, a bolt); every other one is led as
## hitscan. A path, because the pack names behaviours by path (see [GSWeaponDef]).
const PROJECTILE_BEHAVIOUR := "gs_weapon_projectile.gd"


## How long a bot cooks a grenade before letting go, seconds. Well inside the frag's 3 s fuse.
const COOK_SEC := 0.3
## The KOTH layout's hill (FcObjectives.build), the point the bots' team jobs gather round.
const HILL := &"hill"


## A bot looks at which gun to hold one tick in this many (see `FcBots._choose_gun`).
const GUN_CHECK_EVERY := 8
## The play style class (gs-bot's [GSBotStyle] table) of each FC weapon id; a pack's other weapons go by their tags
## in [method World._class_of]. Kept to gs-bot's class names, so the shipped table and `bot_style_weights` apply.
const STYLE_CLASS := {
	&"knife": &"melee",
	&"pistol": &"pistol", &"revolver": &"pistol", &"derringer": &"pistol", &"machine_pistol": &"smg",
	&"smg": &"smg", &"carbine": &"rifle", &"rifle": &"rifle", &"bullpup": &"rifle", &"battle_rifle": &"rifle", &"burst_rifle": &"rifle",
	&"shotgun": &"shotgun", &"drum_shotgun": &"shotgun", &"marksman": &"marksman", &"lmg": &"heavy",
	&"sniper": &"sniper", &"minigun": &"heavy", &"launcher": &"launcher", &"quad_launcher": &"launcher",
	&"grenade_launcher": &"launcher", &"beamer": &"heavy", &"charge_rifle": &"sniper",
	&"frag": &"throw", &"sticky": &"throw", &"flash": &"throw", &"smoke": &"throw", &"incendiary": &"throw",
}
## gs-bot API level of [code]GSBotContact.weapon_class[/code] and [code]magazine[/code] (weapon play styles). Below it the
## contact has neither and the bot plays the generic style, so [code]requires.floor.json[/code] keeps gs_bot at 26.
const STYLE_LEVEL := 32
## Metres inside which a scoped gun gives way to the sidearm.
const GUN_CLOSE := 10.0

## How long a throw may take from the switch to the switch back before it is given up, seconds.
const THROW_GIVE_UP_SEC := 2.5


## Where the world is kept on the game.
const WORLD_META := &"fc_bot_world"




## Height of the eye and of a target's chest above its feet, metres.
const EYE := 1.6
const CHEST := 1.25


## The chest a bot aims at on the avatar body in play: CHEST scaled from the 1.8 m body it was written for.
static func chest_height() -> float:
	return CHEST * FcPlayer.stand_height() / 1.8


## The eye of the avatar body in play.
static func eye_height() -> float:
	return FcPlayer.eye_height()


## One bot's memory between ticks. Kept by the caller, one per bot.
class Mind:
	extends RefCounted
	var brain: GSBotBrain = null
	var seed: int = 0
	## The throw in hand: 0 none, then [constant THROW_DRAW], [constant THROW_COOK],
	## [constant THROW_RELEASE], [constant THROW_BACK].
	var throw_stage: int = 0
	## The character dealt to this bot and its own settings derived from the game's, or null with `bot_personas off`.
	var persona: GSBotPersona = null
	var settings: GSBotSettings = null
	var persona_bias: Vector3 = Vector3.ZERO
	## [member World.persona_epoch] when the brain was made: a `bot_personas` change deals again.
	var persona_epoch: int = -1
	var throw_view: Vector2 = Vector2.ZERO
	var throw_back: int = 0
	var throw_at: int = 0
	var throw_cook_from: int = 0
	## The ride under way (gs-bot's GSBotSurfRide, untyped so an older shell still compiles this), or null.
	var ride: Variant = null
	## Where the bot was last tick, to see a teleport.
	var last_position: Vector3 = Vector3.INF
	## The commands of the last tick the brain thought, repeated on the ticks it coasts (see [constant THINK_EVERY]).
	var last_move: GSFpsCommand = null
	var last_fire: GSWeaponCommand = null
	var out: Array[Object] = []  # The [move, fire] pair handed out every tick with FcBots.reuse_commands (bot_native_think).
	## Whether nobody was within [member think_near] metres at the last think.
	var far: bool = false
	## The view the last think moved from and to, which the coast ticks walk along.
	var view_from: Vector2 = Vector2.ZERO
	var view_to: Vector2 = Vector2.ZERO
	## The (yaw, pitch) degrees the last command was turned against recoil by; the brain steers from the view without it.
	var recoil_comp: Vector2 = Vector2.ZERO
	## Whether the last think left the bot free to coast.
	var coasting: bool = false
	## Ticks from the last think to the next (1 = every tick): `_every` far from enemies, or to its tier's next beat.
	var every: int = 1
	## The tick of the last think, so a think that follows a coast knows its brain turned for several ticks at once.
	var last_think_tick: int = -1
	## Between [method think_begin] and [method think_finish] (see FcBotThreads): the body's contact, the world and what the brain decided.
	var t_me: GSBotContact = null
	var t_world: Object = null
	var t_intent: GSBotIntent = null


## Ticks between rebuilds of a contact's loadout (see [method World._loadout_of]).
const LOADOUT_EVERY := 4


## Think-rate staggering (cvar `bot_think_every`, `bot_think_near`). A bot with no enemy within [member think_near] metres, no target, no ride, no throw, a plain walk and nothing pressed runs its brain one tick in
## [member think_every], offset by its id so the thinkers spread over the ticks, and repeats its last commands in between; 1 turns it off. Far from a fight a brain only picks a waypoint and walks it; the nearby enemy gets every tick.
static var think_every: int = 0
## Players above which `think_every` 0 (auto) staggers by two: up to a 16-player match every bot thinks every tick.
const AUTO_STAGGER_ABOVE := 16
## The stagger in force this tick (1 = none): `think_every`, or what auto picks for the player count.
static var _every: int = 1
static var think_near: float = 30.0
## Sight LOD (cvars `bot_sight_far`, `bot_sight_far_reuse`; gs-bot's GSBotWorld.sight_far): a body farther than this that a
## bot did not see stays unseen for `sight_far_reuse` s before the next ray; never its target, never a "seen". 0 is off; 20 m (A/B on staging02, 31 bots: bot_los -45%, bot_brain -26%).
static var sight_far: float = 20.0
static var sight_far_reuse: float = 0.15
## 1 when a native bot mind (gs_sim's GSSimBotMind) holds sight without the sight LOD (no `sight_cached_far`), 0 when not; -1 unknown.
static var _sight_lod_split := -1


## The sight LOD distance the brains get this tick: [member sight_far], or 0 (off) on a gs_sim whose bot mind has no sight LOD. A brain with a native mind perceives and caches sight there without the LOD, while a brain in script
## (every brain on a worker thread when gs_sim cannot think there, cvar `bot_threads`) holds far bodies unseen: the two would see different bots and play a different match (dm-morpheus at 16 bots, threads 0 vs 4).
static func sight_far_now() -> float:
	if _sight_lod_split < 0:
		_sight_lod_split = 1 if ClassDB.class_exists(&"GSSimBotMind") and not ClassDB.class_has_method(&"GSSimBotMind", &"sight_cached_far") else 0
	if _sight_lod_split == 1 and GSBotAim.native_enabled:
		return 0.0
	return sight_far


## Think-rate tiers (cvars `bot_tier_*`): above [member GSBotThinkTier.above] players a bot that fights a person,
## was hurt by one, is near or in view of one, or is among the nearest to one thinks every tick; the rest every 2-4
## ticks and coast between, fighting included. Server-side commands only: the motor and prediction are untouched.
static var tiers := _make_tiers()
static func _make_tiers() -> GSBotThinkTier:
	var t := GSBotThinkTier.new()
	# A bot fighting a person beyond 25 m and out of every view cone thinks every other tick.
	t.engaged_far_every = 2
	return t


## The fewest ticks between thinks while the tiers are on (cvars `bot_tier_floor`, `bot_tier_floor_engaged`). 1, the default: the tiers alone decide. 3 and 2: a bot the tiers would have think every tick thinks at 22 Hz at 66
## (one fighting a person at 33 Hz) and coasts between with the view carried on; a bot a person hurt still thinks on the next tick. Off by default: the windowed bench gained 2 percent of the tick, inside its noise, and it changes how fast a bot reacts.
static var think_floor: int = 1
static var think_floor_engaged: int = 1


## Bot characters (cvar `bot_personas`): "" deals every persona in `cfg/game/game-fatal-contact/bot/` by weight, so each bot
## gets its own aim and lean to defend, attack or support; "id:weight,..." only those; "off" one shared bot_difficulty.
static var personas_mode: String = ""
const PERSONAS_OFF := "off"


## Whether tiers decide this tick (else the `bot_think_every` stagger does).
static var _tier_on: bool = false
const _COAST_FIRE := GSWeaponCommand.BUTTON_ATTACK | GSWeaponCommand.BUTTON_AIM
const _COAST_MOVE := GSFpsCommand.BUTTON_CROUCH | GSFpsCommand.BUTTON_WALK | GSFpsCommand.BUTTON_SPRINT


## Further than this in one tick is a teleport, metres (a fall at the 3500 u/s limit is under 1).
const TELEPORT_JUMP := 4.0
const THROW_DRAW := 1
const THROW_COOK := 2
const THROW_RELEASE := 3
const THROW_BACK := 4


## What the brain may know of this game.
class World:
	extends SightWorld

	var tick_rate: float = float(FcContent.TICK_RATE)
	## The map's PVS before each sight ray (cvar `fc_bot_pvs`), bound by [method refresh].
	var pvs := FcBotPvs.new()
	var _loadouts: Dictionary[int, Array] = {}
	## [constant STYLE_CLASS] by weapon definition, so a contact's class is one lookup a tick.
	var _classes: Dictionary[GSWeaponDef, StringName] = {}
	## Whether this build's gs-bot has play styles ([constant STYLE_LEVEL]); asked once per world, not per contact.
	var _styled: bool = GSAddonApi.build_level("gs_bot") >= STYLE_LEVEL
	var _waypoints_tick: int = -1
	var _waypoints_held := PackedVector3Array()
	var _contacts: Array[GSBotContact] = []
	## The native sight scan's table of [member _contacts], filled in [method refresh]'s loop (cvar `bot_native_think`).
	var _bot_rows := FcBotRows.new()
	## The contacts by id, kept from tick to tick and rewritten whole by [method refresh] (a brain keeps ids, never a contact).
	var _by_id: Dictionary[int, GSBotContact] = {}
	var _players: Dictionary[int, FcPlayer] = {}
	## Weapon ratings (def -> [method GSBotArms.rate]) of this tick: every loadout and drop list rates the same few definitions.
	var _rated: Dictionary[Object, float] = {}
	## The tick [method player_count] counted on, and its count.
	var _count_tick: int = -1
	var _count: int = 0
	## [method GSBotArms.rate] once a tick per definition (over [member _rated]), for every loadout and drop list here.
	var _rater: Callable = Callable()
	## The body tunables of this tick, looked up once for all contacts (the lookup walks every player).
	var _tunables: GSFpsTunables = null
	## Bots a person hurt since their last think: they think next tick whatever their tier.
	var woken: Dictionary[int, bool] = {}
	## [member FcBots.tiers], set by the thinking bot before [method refresh].
	var tiers: GSBotThinkTier = null
	## The personas bots are dealt from ([method personas_for]), the `bot_personas` text it was set for, and a count
	## bumped when that changes so every bot is dealt again.
	var _personas: GSBotPersonaPool = null
	var _personas_text: String = ""
	var persona_epoch: int = 0
	## The tick [member brains_made] counts brains built in ([member FcBots.brains_per_tick]).
	var brains_tick: int = -1
	var brains_made: int = 0
	var _persona_rng := RandomNumberGenerator.new()

	var _par_glass: bool = false
	## Which job (brain) the calling thread works on, for the log of its wall rays.
	func par_job(job: int) -> void:
		if _par_observe:
			_par_lock.lock()
			_par_job[OS.get_thread_caller_id()] = job
			_par_lock.unlock()

	## The pool for `bot_personas` [param mode], or null for "off". Loaded once from the `bot` profiles; a changed
	## mode sets the override, forgets who had what and bumps [member persona_epoch].
	func personas_for(mode: String) -> GSBotPersonaPool:
		if mode != _personas_text:
			_personas_text = mode
			persona_epoch += 1
			if _personas != null:
				_personas.set_override(mode if mode != PERSONAS_OFF else "")
				_personas.reset_assignments()
		if mode == PERSONAS_OFF:
			return null
		if _personas == null:
			_personas = GSBotPersonaPool.new()
			_persona_rng.seed = 0x5eed
			var n := _personas.load_from(GSProfileSet.create("gs-bot", "game-fatal-contact", GSBotPersona.KIND, GSBotPersona.schema()))
			_personas.set_override(mode)
			GSLog.info(CHANNEL, "bot personas loaded", {"personas": n, "override": mode})
		return _personas

	## The persona [param id] is dealt from [param pool].
	func deal_persona(pool: GSBotPersonaPool, id: int) -> GSBotPersona:
		return pool.deal(StringName(str(id)), _persona_rng)

	func _init(p_game: Object) -> void:
		game = p_game
		if game.has_signal(&"hit_confirmed"):
			game.connect(&"hit_confirmed", _on_hit)
		if game.has_signal(&"player_added"):
			game.connect(&"player_added", _hear_player)
		if game.has_signal(&"map_changed"):
			game.connect(&"map_changed", _on_map_changed)
		for p in game.call("players"):
			_hear_player(p)
		walkable_fn = _walkable_near
		# The lambdas hold the box, not self: a lambda on self in a field of self is a reference cycle.
		var box := _par_arsenal
		var rated := _rated
		_rater = func(def: Object) -> float:
			var held: Variant = rated.get(def)
			if held == null:
				held = GSBotArms.rate(def)
				rated[def] = held
			return held
		GSBotArms.wire(self, func() -> Variant: return p_game.get("weapon_drops"), func() -> Object: return box[0] if box[0] != null else _any_arsenal(p_game), _rater)

	## Players in the game on [param tick], counted once a tick however many bots ask.
	func player_count(tick: int) -> int:
		if tick != _count_tick or tick < 0:
			_count_tick = tick
			_count = (game.call(&"player_ids") as Array).size()
		return _count

	## Rebuilds the contacts once a tick, however many bots ask.
	func refresh(tick: int, rate: float) -> void:
		tick_rate = maxf(rate, 1.0)
		if tick == _tick:
			return
		_tick = tick
		pvs.bind(game)
		contacts_version = tick
		_contacts.clear()
		_players.clear()
		_rated.clear()
		_tunables = null
		var t_lap := FcFrameProbe.lap_start()
		var teams := _team_mode()
		var eye := FcPlayer.eye_height()
		var aim := CHEST * FcPlayer.stand_height() / 1.8
		var rows := _bot_rows.begin()
		for p: FcPlayer in game.call(&"players"):
			var c := _contact_of(p, tick, eye, aim, teams)
			_contacts.append(c)
			if rows:
				_bot_rows.add(c)
			_players[c.id] = p
		if _by_id.size() != _contacts.size():
			# Someone left: only this tick's players have a contact.
			_by_id.clear()
			for c: GSBotContact in _contacts:
				_by_id[c.id] = c
		_bot_rows.hand(self, tick)
		var t_obj := FcFrameProbe.lap_start()
		_objective_refresh(teams)
		FcFrameProbe.lap(&"brc_objective", t_obj)
		t_lap = FcFrameProbe.lap(&"br_contacts", t_lap)
		if tiers != null:
			_tier_begin()
		t_lap = FcFrameProbe.lap(&"br_tiers", t_lap)
		_near_refresh(_contacts, FcHullGrid.enabled)
		FcFrameProbe.lap(&"br_near", t_lap)

	## [param p]'s contact for this tick: last tick's object, every field written again, as a fresh one would be, without a
	## new object per player per tick.
	func _contact_of(p: FcPlayer, tick: int, eye: float, aim: float, teams: bool) -> GSBotContact:
		var c: GSBotContact = _by_id.get(p.player_id)
		if c == null:
			c = GSBotContact.new()
			c.id = p.player_id
			_by_id[c.id] = c
		c.eye_height = eye
		c.aim_height = aim
		c.alive = p.is_alive()
		c.team = p.team if teams else 0
		if p.controller != null:
			var state := p.controller.state
			c.position = state.position
			c.velocity = state.velocity
			c.view_yaw = state.yaw
			c.view_pitch = state.pitch
			_motion_of(c, state)
		else:
			c.position = p.global_position
			c.velocity = Vector3.ZERO
			c.view_yaw = NAN
			c.view_pitch = NAN
			c.grounded = true
			c.sliding = false
			c.wall_running = false
			c.air_jump_ready = false
		c.health = p.health.health / p.health.max_health if p.health != null and p.health.max_health > 0.0 else 1.0
		var t_c := FcFrameProbe.lap_start()
		c.loadout = _loadout_of(p, tick)
		t_c = FcFrameProbe.lap(&"brc_loadout", t_c)
		_weapon_of(c, p)
		FcFrameProbe.lap(&"brc_weapon", t_c)
		return c

	## The flags as the HUD shows them, or the hill, into [member GSBotWorld.objective], for the bots' team jobs (defend,
	## attack, support). Outside those modes the objective is empty and every bot roams as in a free-for-all.
	func _objective_refresh(teams: bool) -> void:
		var objectives: Variant = game.get("objectives") if teams else null
		var ctf: Variant = objectives.get("ctf") if objectives is Object else null
		if not (ctf is GSObjectiveCtf):
			var hill := _hill_of(objectives)
			if hill != null:
				if objective == null:
					objective = GSBotObjective.new()
				objective.set_point(hill.def.area.centre, hill.def.area.radius, hill.owner_team)
			elif objective != null:
				objective.clear_flags()
			return
		if objective == null:
			objective = GSBotObjective.new()
		var flags: Array[GSObjectiveFlag] = (ctf as GSObjectiveCtf).flags()
		for flag in flags:
			if flag == null or flag.def == null or flag.def.area == null:
				continue
			var team := flag.home_team()
			var capture := Vector3.INF
			for other in flags:
				if other != null and other != flag and other.home_team() != team:
					var area := other.capture_area_for(team, flags)
					if area != null:
						capture = area.centre
					break
			var carrier := -1
			if flag.state == GSObjectiveFlag.State.CARRIED and flag.carrier.is_valid_int():
				carrier = flag.carrier.to_int()
			objective.set_flag(team, flag.def.area.centre, flag.position(), carrier, int(flag.state), capture)

	## The hill of a hill mode, or null.
	func _hill_of(objectives: Variant) -> GSObjective:
		var manager: Variant = objectives.get("manager") if objectives is Object else null
		if not (manager is GSObjectiveManager):
			return null
		var hill := (manager as GSObjectiveManager).objective(HILL)
		return hill if hill != null and hill.def != null and hill.def.area != null else null

	## Hands the tiers the live people's eyes and views and the bots' positions (a person is a contact with no brain),
	## or empty lists when the tiers do not apply at this many contacts.
	func _tier_begin() -> void:
		var eyes := PackedVector3Array()
		var looks := PackedVector3Array()
		var ids := PackedInt32Array()
		var at := PackedVector3Array()
		if tiers.applies(_contacts.size()):
			for c: GSBotContact in _contacts:
				if brains.has(c.id):
					if c.alive:
						ids.append(c.id)
						at.append(c.position)
				elif c.alive:
					eyes.append(c.eye())
					looks.append(GSBotIntent.direction(c.view_yaw, c.view_pitch))
		tiers.begin(_contacts.size(), eyes, looks, ids, at)

	## What the player carries, rated: 33 slot reads and ratings per player for what only a pickup, a shot or a
	## reload changes. Kept until the arsenal's [code]revision()[/code] (gs-weapon API 51) or the arsenal itself
	## changes; an older gs-weapon falls back to one rebuild in [constant LOADOUT_EVERY] ticks (offset by id).
	func _loadout_of(p: FcPlayer, tick: int) -> Dictionary:
		var held: Variant = _loadouts.get(p.player_id)
		var arsenal: Object = p.arsenal
		# Kept for this arsenal (an entry of three is only written for one with revision()): no has_method a player a tick.
		if arsenal != null and held is Array and (held as Array).size() == 3 and (held as Array)[2] == arsenal.get_instance_id():
			if (held as Array)[0] == arsenal.call(&"revision"):
				return (held as Array)[1]
		if arsenal != null and arsenal.has_method(&"revision"):
			var rev: int = arsenal.call(&"revision")
			var id := arsenal.get_instance_id()
			if held is Array and (held as Array).size() == 3 and (held as Array)[0] == rev and (held as Array)[2] == id:
				return (held as Array)[1]
			var fresh := GSBotArms.loadout_of(arsenal, _rater)
			_loadouts[p.player_id] = [rev, fresh, id]
			return fresh
		if held is Array and (held as Array).size() == 2 and (tick + p.player_id) % LOADOUT_EVERY != 0 and tick >= (held as Array)[0] and tick - (held as Array)[0] < LOADOUT_EVERY:
			return (held as Array)[1]
		var made := GSBotArms.loadout_of(arsenal, _rater)
		_loadouts[p.player_id] = [tick, made]
		return made

	## The class of the weapon in hand and how full its magazine is, for the bot's play style.
	## Set by name: the fields exist from gs-bot [constant STYLE_LEVEL], and a host below it still parses this file.
	func _weapon_of(c: GSBotContact, p: FcPlayer) -> void:
		if not _styled:
			return
		var slot: GSWeaponSlot = p.arsenal.current() if p.arsenal != null else null
		if slot == null or slot.def == null:
			c.set(&"weapon_class", &"")
			c.set(&"magazine", -1.0)
			return
		var def := slot.def
		var klass: Variant = _classes.get(def)
		if klass == null:
			klass = _class_of(def)
			_classes[def] = klass
		c.set(&"weapon_class", klass)
		c.set(&"magazine", float(slot.magazine) / float(def.magazine) if def.magazine > 0 else -1.0)

	## A weapon's style class: its id (with or without a pack's `aw_` prefix) in [constant STYLE_CLASS], else its tags.
	static func _class_of(def: GSWeaponDef) -> StringName:
		var id := String(def.id)
		var known: Variant = STYLE_CLASS.get(StringName(id.trim_prefix("aw_")))
		if known != null:
			return known
		if def.tags.has(&"melee"):
			return &"melee"
		if def.tags.has(&"scoped"):
			return &"sniper"
		if def.tags.has(&"thrown") or def.tags.has(&"grenade"):
			return &"throw"
		return &"rifle" if def.tags.has(&"automatic") else &""

	## Arsenal of any player: its catalogue knows every weapon lying about.
	static func _any_arsenal(g: Object) -> Object:
		for p: FcPlayer in g.call("players"):
			return p.arsenal
		return null

	## What the bot's body is doing, and whether the game would honour an air-jump press now.
	func _motion_of(c: GSBotContact, state: GSFpsState) -> void:
		c.grounded = state.mode == GSFpsState.Mode.GROUND
		c.sliding = state.slide_time >= 0.0
		c.wall_running = state.wall_run_time >= 0.0
		if _tunables == null:
			_tunables = _body_tunables()
		var tunables := _tunables
		c.air_jump_ready = tunables.launch_enabled and state.launch_cooldown_left <= 0.0

	## The nearest map surface along a direction, for the walls a bot could run beside.
	## Gets the world ready for brains on other threads; false when the game's trace is one this cannot ask from them.
	## Starts what a worker would otherwise start (the imported map's mesh bake) on the calling thread first.
	func par_begin() -> bool:
		if _los_at != _tick:
			_los_bind()
		if _los_trace == null:
			return false
		_par_trace = _los_trace
		_par_observe = _par_trace.ray_observer.is_valid()
		_par_job.clear()
		_par_rays.clear()
		_par_arsenal[0] = _any_arsenal(game)
		_par_physics = false
		_par_space = null
		_par_trace_glass = _trace_glass(_par_trace)
		if _par_trace is GSTracePhysics:
			var bound: World3D = (_par_trace as GSTracePhysics)._world
			if bound == null:
				return false
			_par_space = bound.direct_space_state
			if _par_space == null:
				return false
			_par_physics = true
		elif not _par_trace is GSTraceFlat:
			return false
		# The jail glass rule applies on a map with a collision root, as _line_of_sight has it.
		_par_glass = false
		if _cell_root() != null:
			if _par_space == null:
				return false
			_par_glass = true
		var _nav_warm := _nav_for_map()
		var _surf_warm := surf_for_map()
		# The brain prunes both each think; once here, theirs find nothing to remove.
		prune_sight_blockers(now())
		var _heard := sounds_after(1 << 60, now())
		_sight_par = _sight_bind(true)
		# Each player's shot speed, once on main: a worker's projectile_speed reads it without a lock (it was the
		# top world query at 32 bots, 43 us a call waiting on _par_lock). Brains never switch guns while in par.
		_par_proj_speed.clear()
		for id: int in _players:
			_par_proj_speed[id] = _projectile_speed_of(_players[id])
		par = true
		return true

	func _los_par(from: Vector3, to: Vector3) -> bool:
		if _par_glass:
			_ray_lock.lock()
			var shut := _los_cell.blocks(_par_space, from, to)
			_ray_lock.unlock()
			if shut:
				return false
		if not _par_physics:
			return _par_trace.line_of_sight(from, to)
		var distance := from.distance_to(to)
		if distance <= 0.0001:
			return true
		var glass := _glass_of_trace()
		var base: int = _par_trace.collision_mask
		return _ray_par(from, from + (to - from) / distance * distance, (base & ~glass.glass_mask) if glass != null else base).is_empty()

	func now() -> float:
		return float(maxi(_tick, 0)) / tick_rate

	func contact(id: int) -> GSBotContact:
		return _by_id.get(id)

	func contacts() -> Array:
		return _contacts

	func contact_of(all: Array, id: int) -> GSBotContact:
		return _by_id.get(id) if is_same(all, _contacts) else GSBotWorld.find(all, id)

	func line_of_sight(from: Vector3, to: Vector3) -> bool:
		if par:
			if pvs.active != null and not pvs.open(from, to):
				return _pvs_ruled_out(from, to)
			return _los_par(from, to)
		var t_los := Time.get_ticks_usec()
		var seen := _pvs_ruled_out(from, to) if pvs.active != null and not pvs.open(from, to) else _line_of_sight(from, to)
		FcFrameProbe.add(&"bot_los", t_los)
		return seen

	## A sight the map's PVS ruled out: blocked; with `fc_bot_pvs_verify`, the ray's own answer, a clear one counted.
	func _pvs_ruled_out(from: Vector3, to: Vector3) -> bool:
		if not FcBotPvs.verify:
			return false
		var seen := _los_par(from, to) if par else _line_of_sight(from, to)
		FcBotPvs.ruled_out_but(seen)
		return seen

	func _line_of_sight(from: Vector3, to: Vector3) -> bool:
		if _los_at != _tick:
			_los_bind()
		# Bots inside the jail cell cannot see out through its glass; the trace itself ignores that layer for sight.
		var root := _cell_root()
		if root != null and _los_cell.blocks(root.get_world_3d().direct_space_state, from, to):
			return false
		if _los_ray != null:
			return _sight_ray(_los_ray, from, to)
		if _los_trace != null:
			return _los_trace.line_of_sight(from, to)
		return true

	func _on_map_changed(_map: Object) -> void:
		_los_at = -2
		_sight_at = -1
		_nav_at = -2
		_graph_at = -2
		_mask_at = -2

	## Whether a native mind may ask sight of gs-sim's [code]GSSimSightRay[/code] (when loaded) in place of
	## [method line_of_sight]; off: every ray goes through script (scale128 [code]--native-sight 0[/code]).
	static var native_sight: bool = true
	## The native ray (a GSSimSightRay), made once when the class is loaded; null: script only.
	var _sight_native: Object = null
	var _sight_tried: bool = false
	## [method sight_callable]'s answer while a tick's brains think on workers, bound by [method par_begin].
	var _sight_par: Callable = Callable()
	## [method sight_callable]'s answer on the main thread, bound once per tick ([member _sight_at]).
	var _sight_main: Callable = Callable()
	var _sight_at: int = -1

	## gs-bot's hook: the native ray's [code]clear[/code] when this world's sight is the one plain engine ray
	## [method _sight_ray] / [method _los_par] ask (a plain physics or glass trace; the jail glass rule goes with it),
	## bound to that ray's space, mask and exclusions; else [method line_of_sight]. The same answer to the bit.
	func sight_callable() -> Callable:
		if par:
			return _sight_par
		if _sight_at != _tick or not _sight_main.is_valid():
			_sight_at = _tick
			_sight_main = _sight_bind()
		return _sight_main

	## The native ray bound to this moment's trace, or [method line_of_sight] when the ray does not answer the same.
	func _sight_bind(for_par: bool = false) -> Callable:
		var script_sight := line_of_sight
		if not native_sight:
			return script_sight
		if not _sight_tried:
			_sight_tried = true
			if ClassDB.class_exists(&"GSSimSightRay"):
				_sight_native = ClassDB.instantiate(&"GSSimSightRay")
		if _sight_native == null:
			return script_sight
		# The jail glass rule, as _line_of_sight (main thread: the collision root's space) and _los_par
		# (par_begin's space) ask it: the native ray asks it too, for rays from inside the cell.
		if _los_at != _tick:
			_los_bind()
		var trace := _los_ray
		if trace == null:
			return script_sight
		var root := _cell_root()
		var cell: GSMapGlassSight = _los_cell if root != null else null
		var cell_space: PhysicsDirectSpaceState3D = null
		if cell != null:
			cell_space = _par_space if for_par else root.get_world_3d().direct_space_state
		var bound: World3D = trace._world
		var space: PhysicsDirectSpaceState3D = bound.direct_space_state if bound != null else null
		# GSSimSightRay is a native class only some builds have, so it is called by name, once a tick.
		_sight_native.call(&"bind", space, _sight_mask(trace), trace.exclude_rids, _ray_lock,
				cell_space, cell.glass_mask if cell != null else 0, cell.centre if cell != null else Vector3.ZERO,
				cell.radius if cell != null else 0.0, cell.radius + cell.margin if cell != null else 0.0)
		return Callable(_sight_native, &"clear")

	const SPAWN_THINNING := 25.0
	static func _near_any(points: PackedVector3Array, at: Vector3, within: float) -> bool:
		for point in points:
			if point.distance_to(at) < within:
				return true
		return false

	## Spawns and landings, repeated where people stand once the game has recorded enough of it.
	func waypoints() -> PackedVector3Array:
		if par:
			_par_lock.lock()
			var held := _waypoints()
			_par_lock.unlock()
			return held
		var t_lap := FcFrameProbe.lap_start()
		var points := _waypoints()
		FcFrameProbe.lap(&"bot_waypoints", t_lap)
		return points

	func _waypoints() -> PackedVector3Array:
		# Every replan asks (GSBotGoal's spots too); spawns and landings are gathered once per tick, the weighting keeps its own cache.
		if _waypoints_tick != _tick or _tick < 0:
			_waypoints_held = _places()
			_waypoints_tick = _tick
		var stats: Variant = game.get("demo_stats")
		return (stats as Object).call(&"weight_waypoints", _waypoints_held) if stats is Object else _waypoints_held

	func _places() -> PackedVector3Array:
		var out := PackedVector3Array()
		var map: Variant = game.get("map")
		var spawns: Array = (map as Object).get("spawns") if map is Object else []
		var surf := surf_for_map()
		for spawn: Transform3D in spawns:
			# A combat surf map has dozens of spawns on one platform (surf_snipers_island: 48); each as a waypoint outweighed the few landings and ramp starts a ride is taken from, and the bots never rode.
			# With ride edges linked, spawns closer than this to one kept are one place.
			if surf != null and out.size() > 0 and _near_any(out, spawn.origin, SPAWN_THINNING):
				continue
			out.append(spawn.origin)
		if surf != null:
			out.append_array(surf.call(&"landing_points"))
		return out

	## The nearest standable point of the mesh, for a bot that cannot free itself; INF off it.
	func _walkable_near(at: Vector3) -> Vector3:
		var nav := _nav_for_map()
		return nav.closest(at) if nav != null and nav.is_ready() else Vector3.INF

	## Whether an imported map's mesh is still baking or its edges still joining (each call steps that); false on a built-in map or once done.
	func is_route_pending() -> bool:
		if _nav == null or _nav_map != game.get("map"):
			return false
		return _nav.is_baking() or ((_joining or _nav.is_ready()) and not warm())

	## How fast the held weapon's shot flies, m/s; 0 for hitscan, a swing or a throw.
	func projectile_speed(shooter: GSBotContact) -> float:
		if par:
			# Filled by par_begin and only read while par is on: no lock.
			return _par_proj_speed.get(shooter.id, 0.0) if shooter != null else 0.0
		var t_lap := FcFrameProbe.lap_start()
		var speed := _projectile_speed(shooter)
		FcFrameProbe.lap(&"bot_proj_speed", t_lap)
		return speed

	func _projectile_speed(shooter: GSBotContact) -> float:
		return _projectile_speed_of(_players.get(shooter.id) if shooter != null else null)

	func _projectile_speed_of(p: FcPlayer) -> float:
		var def: GSWeaponDef = p.arsenal.current_def() if p != null and p.arsenal != null else null
		if def == null or not def.behaviour_path.ends_with(PROJECTILE_BEHAVIOUR) or not (def.tuning is GSWeaponBallistics):
			return 0.0
		return (def.tuning as GSWeaponBallistics).speed

	func _team_mode() -> bool:
		var mode: Variant = game.get("mode")
		return mode is Object and (mode as Object).has_method("is_team_mode") and bool((mode as Object).call("is_team_mode"))

	## Every shot is a sound; a swing or a throw is a quieter one.
	func _hear_player(p: Object) -> void:
		if not (p is FcPlayer) or p.has_meta(&"fc_bot_heard"):
			return
		p.set_meta(&"fc_bot_heard", true)
		var body := p as FcPlayer
		body.used.connect(func(outcome: GSWeaponOutcome) -> void:
			if outcome == null or not outcome.used:
				return
			var loud := 1.0 if not outcome.shots.is_empty() or not outcome.spawns.is_empty() else 0.3
			emit_sound(body.muzzle_position(), loud, body.player_id, now())
		)

	func _on_hit(attacker: int, victim: int, _amount: float, _point: Vector3, _headshot: bool, _lethal: bool) -> void:
		var brain: GSBotBrain = brains.get(victim)
		if brain == null:
			return
		if not brains.has(attacker):
			woken[victim] = true
		var from := contact(attacker)
		brain.hurt(from.eye() if from != null else Vector3.INF, now())
