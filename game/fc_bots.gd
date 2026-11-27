extends "fc_bots_world.gd"

const FcNativePhases := preload("fc_native_phases.gd")

## What a bot does with a tick, as the same two commands a client sends: gs-bot's brain,
## fed from this game. One brain for every bot Fatal Contact has, solo and on a server.
##
## [b]Commands, not a second simulation.[/b] A bot is an [FcPlayer] like anybody else and
## moves through the same controller, shoots through the same arsenal and is hit by the same
## lag-compensated trace; all this decides is what it would have pressed. That keeps a bot
## from ever doing something a player could not -- no walking through walls, no shot the
## arsenal would refuse -- and keeps the tick order exactly what it is for people.
##
## [b]Solo used to be a test fixture.[/b] The offline client drove its bots with the
## `headless_match` aimbot: face the nearest player through any wall, hold the trigger under
## 40 m, no reaction and no aim error. A first play test on Windows died twelve times in ninety
## seconds to it, killed from 30 to 40 m within a second, while the brain a server ran (sight,
## reaction, aim error, range, strafing) was never met by anybody playing solo. Both now ask
## [GSBotBrain], so `bot_difficulty` means the same thing in both.
##
## [b]What the brain is told[/b] ([World], a [GSBotWorld]): every player as a
## [GSBotContact], the combat trace's line of sight, the map's spawns as places to roam, a
## route between them over the horde's navigation graph (built-in maps; an imported map has
## none, and is walked straight), how fast the held weapon's projectile flies (so a rocket
## is led), a sound for every shot fired (from [signal FcPlayer.used]) and who hit whom
## (from [signal FcGame.hit_confirmed]). Nothing else, so it cannot see through a wall.
##
## [b]A grenade is four commands, not a button.[/b] Fatal Contact has no throw key: a frag is slot 5,
## drawn, held to cook and released. When the brain says [member GSBotIntent.throw], [Mind]
## switches to the throwable, holds the trigger for [constant COOK_SEC], lets go along the
## view the brain chose, and switches back to what it held -- the same presses a person makes.
##
## [b]Deterministic per bot[/b]: the brain's randomness is seeded from the bot's id, and its
## clock is the game's tick, so two runs of the same inputs play the same bots. Not on an
## imported map, whose routes start when its background bake lands ([method World._nav_for_map]).
##
## [b]Ramps are ridden.[/b] On a combat surf map with a surf cache the routes cross ride edges
## between the platforms and walk through the map's teleports, and a bot whose route reaches a
## ride hands its legs to the surf pilot until it lands, aiming and shooting as before
## ([code]fc_surf.gd[/code], loaded only on a shell with gs-bot 4 and
## gs-player-controller 3).


## The world on [param game], made the first time a bot asks.
static func world_for(game: Object) -> World:
	if game.has_meta(WORLD_META):
		var held: Variant = game.get_meta(WORLD_META)
		if held is World:
			return held
	var made := World.new(game)
	game.set_meta(WORLD_META, made)
	return made


## [move, fire] for [param bot] this tick.
## Ticks between thinks that give [param hz] thinks a second at [param tick_rate] (never under 1).
static func every_for_hz(hz: float, tick_rate: int) -> int:
	return maxi(1, roundi(float(tick_rate) / maxf(hz, 0.001)))


static func think(game: Object, bot: FcPlayer, mind: Mind, tick: int, tick_rate: float) -> Array:
	var early := think_begin(game, bot, mind, tick, tick_rate)
	if not early.is_empty():
		return early
	var t_brain := Time.get_ticks_usec()
	mind.t_intent = mind.brain.think(mind.t_me, mind.t_world, mind.t_world.now())
	FcFrameProbe.add(&"bot_brain", t_brain)
	return think_finish(game, bot, mind, tick, tick_rate)


## [method _tick_world], for FcBotCoast's begin pass.
static func world_this_tick(game: Object, tick: int) -> World:
	return _tick_world(game, tick)


## The game's world, the think rate and the world's knobs, once a tick however many bots ask (31 calls a tick at 32
## bots were 31 meta lookups, player counts and tier tests); a tick below 0 or another game sets them again.
static func _tick_world(game: Object, tick: int) -> World:
	if tick >= 0 and tick == _begun_tick and _begun_game == game.get_instance_id() and _begun_world != null:
		var held: World = _begun_world.get_ref()
		if held != null:
			return held
	var world := world_for(game)
	# Counted once a tick for every bot (player_ids is a new array each call).
	var players := world.player_count(tick)
	_every = think_every if think_every > 0 else (2 if players > AUTO_STAGGER_ABOVE else 1)
	_tier_on = tiers.applies(players)
	world.near_reach = think_near
	world.sight_far = sight_far_now()
	world.sight_far_reuse = sight_far_reuse
	world.tiers = tiers
	_begun_tick = tick
	_begun_game = game.get_instance_id()
	_begun_world = weakref(world)
	return world

static var _begun_tick: int = -1
static var _begun_game: int = 0
## Weak: a static World would outlive its game and be freed in script teardown at exit (headless_net aborted, 134).
static var _begun_world: WeakRef = null


## The part of [method think] before the brain runs, on the main thread: the commands of a tick the bot coasts (or
## of no game), else an empty array with [member Mind.t_me] and [member Mind.t_world] set for the brain.
static func think_begin(game: Object, bot: FcPlayer, mind: Mind, tick: int, tick_rate: float) -> Array:
	if game == null or bot == null:
		return [GSFpsCommand.new(), GSWeaponCommand.new()]

	var t_gate := FcFrameProbe.lap_start()
	var world := _tick_world(game, tick)
	if coasts_now(world, bot, mind, tick):
		t_gate = FcFrameProbe.lap(&"bt_gate", t_gate)
		var moved := _coast(mind, tick)
		var t_move := FcFrameProbe.lap(&"bt_coast_move", t_gate)
		var coasted := _recoil_comp(bot, mind, moved, tick, tick_rate)
		FcFrameProbe.lap(&"bt_coast_recoil", t_move)
		FcFrameProbe.lap(&"bt_coast", t_gate)
		return coasted
	FcFrameProbe.lap(&"bt_gate", t_gate)
	return think_setup(game, bot, mind, tick, tick_rate, world)


## Whether [param bot] sits this tick out on the commands it has (see [method _coasts]); [param world] is this tick's
## ([method _tick_world]).
static func coasts_now(world: World, bot: FcPlayer, mind: Mind, tick: int) -> bool:
	return (_every > 1 or _tier_on) and _coasts(mind, tick, world, bot.player_id)


## [method think_begin] for a bot that does not coast this tick: the world refreshed, the brain made or kept, and
## [member Mind.t_me] and [member Mind.t_world] set (an empty array), or still commands while no brain slot is free.
static func think_setup(game: Object, bot: FcPlayer, mind: Mind, tick: int, tick_rate: float, world: World) -> Array:
	var t_refresh := Time.get_ticks_usec()
	world.refresh(tick, tick_rate)
	FcFrameProbe.add(&"bot_refresh", t_refresh)
	var t_setup := FcFrameProbe.lap_start()

	var pool := world.personas_for(personas_mode)
	t_setup = FcFrameProbe.lap(&"bt_personas", t_setup)
	# A brain a caller made itself (persona_epoch -1) is never replaced.
	if mind.brain != null and mind.persona_epoch >= 0 and mind.persona_epoch != world.persona_epoch:
		mind.brain = null
	if mind.brain == null:
		if not _take_brain_slot(world, tick):
			FcFrameProbe.lap(&"bt_setup", t_setup)
			return [GSFpsCommand.new(), GSWeaponCommand.new()]
		var t_new := FcFrameProbe.lap_start()
		var bot_seed := mind.seed if mind.seed != 0 else bot.player_id
		var base := GSBotSettings.of(game)
		mind.persona = world.deal_persona(pool, bot.player_id) if pool != null else null
		mind.settings = GSBotSettings.derived(base, mind.persona, bot_seed) if mind.persona != null else null
		mind.persona_bias = mind.persona.role_bias() if mind.persona != null else Vector3.ZERO
		mind.persona_epoch = world.persona_epoch
		mind.brain = FcBotBrain.new(bot_seed, mind.settings if mind.settings != null else base)
		# The bot's trick gates follow the motor: 1.18 times the minimum, as the old 6.5 was of 5.5.
		var body_tunables: Variant = bot.controller.get("tunables") if bot.controller != null else null
		if body_tunables is GSFpsTunables:
			mind.brain.tricks.slide_speed = body_tunables.slide_min_speed * 1.18
			mind.brain.tricks.wall_run_speed = body_tunables.wall_run_min_speed * 1.17
		FcFrameProbe.lap(&"bt_brain_new", t_new)
	world.brains[bot.player_id] = mind.brain
	if mind.settings != null:
		var _resynced := mind.settings.sync()

	var me := world.contact(bot.player_id)
	# A team job in a flag mode, kept until the bot changes team (assign is a lookup after the first); the
	# persona's lean puts holders on defence and hunters on attack.
	if world.objective != null and world.objective.active and me.team > 0:
		var _role := world.objective.assign(bot.player_id, me.team, mind.brain.settings.profile, mind.persona_bias)
	# The body's view carries last tick's recoil correction; the brain steers from the view it meant, or it would walk
	# the correction back out (smoothing and the turn limit) and the bullets drift off again.
	if mind.recoil_comp != Vector2.ZERO and bot.controller != null:
		me.view_yaw = bot.controller.state.yaw + mind.recoil_comp.x
		me.view_pitch = bot.controller.state.pitch + mind.recoil_comp.y
	# A teleport carries the bot further in a tick than anything walks or flies, and its route was
	# laid from where it stood: walked on, the old corners lead it off the pad it landed on. The
	# brain is told as it is when a ride ends, and plans from here (a ride the pilot has is not cut).
	if mind.ride == null and mind.last_position != Vector3.INF and me.position.distance_to(mind.last_position) > TELEPORT_JUMP:
		mind.brain.ride_ended(true)
	mind.last_position = me.position
	mind.t_me = me
	mind.t_world = world
	FcFrameProbe.lap(&"bt_setup", t_setup)
	return []


## A full server's bots all join on one tick, and 31 brains built together were about 12 ms of tick 1 (bt_brain_new).
## Past brains_per_tick this tick the bot stands still (false) and is built on a later one.
static func _take_brain_slot(world: World, tick: int) -> bool:
	if world.brains_tick != tick:
		world.brains_tick = tick
		world.brains_made = 0
	if brains_per_tick > 0 and world.brains_made >= brains_per_tick:
		return false
	world.brains_made += 1
	return true


## gs-bot 0.1.32: a bot stuck on an island with no way off (a surf map with no ride cache) goes back to a spawn. The brain reports again every bot_stranded_sec if that did not free it. Returns whether it respawned.
static func unstrand(game: Object, bot: FcPlayer, mind: Mind, intent: GSBotIntent) -> bool:
	if intent == null or not intent.stranded or game == null or not game.has_method(&"respawn_player"):
		return false
	mind.ride = null
	game.call(&"respawn_player", bot.player_id)
	if mind.brain != null:
		mind.brain.ride_ended(true)
	return true


## The part of [method think] after the brain ran, on the main thread: the bot's commands from [member Mind.t_intent].
## [param row] >= 0: [method finish_all] already steered the intent ([method _finish_begin]) and wrote its row of
## [member _rows_stick], [member _rows_move] and [member _rows_fire] (gs-sim's GSSimBotFinish), copied here for [method _write].
static func think_finish(_game: Object, bot: FcPlayer, mind: Mind, tick: int, tick_rate: float, row: int = -1) -> Array:
	var made := _out_pair(mind)
	var move: GSFpsCommand = made[0]
	var fire: GSWeaponCommand = made[1]
	_clear(move, fire)
	var world: World = mind.t_world
	var me: GSBotContact = mind.t_me
	var intent: GSBotIntent = mind.t_intent
	mind.t_me = null
	if mind.brain != null:
		FcNativePhases.tally(FcNativePhases.BOTS, mind.brain.aim.is_native())
	mind.t_world = null
	mind.t_intent = null
	var t_after := Time.get_ticks_usec()
	var t_lap := FcFrameProbe.lap_start()
	if row < 0:
		_finish_begin(_game, bot, mind, intent, world, tick, tick_rate)
		t_lap = FcFrameProbe.lap(&"ba_surf", t_lap)
		_write(intent, move, fire)
	else:
		move.yaw = intent.yaw
		move.pitch = intent.pitch
		move.move = _rows_stick[row]
		move.buttons = _rows_move[row]
		fire.yaw = intent.yaw
		fire.pitch = intent.pitch
		fire.buttons = _rows_fire[row]
	t_lap = FcFrameProbe.lap(&"ba_write", t_lap)
	_throw(bot, mind, intent, move, fire, tick, tick_rate)
	# Only a bot that drew a kit switches; one on the default loadout plays as it always has.
	if bot.has_meta(&"bot_loadout"):
		_choose_gun(bot, mind, world, me, intent, fire, tick)
	t_lap = FcFrameProbe.lap(&"ba_throw", t_lap)
	move.sanitise()
	fire.sanitise()
	FcFrameProbe.lap(&"ba_sanitise", t_lap)
	FcFrameProbe.add(&"bot_after", t_after)
	var t_tail := FcFrameProbe.lap_start()
	_schedule_beat(bot, mind, world, me, intent, move, fire, tick, tick_rate)
	mind.last_think_tick = tick
	# Copied into the bot's own pair, never handed out (a coast returns copies of it), so no two new commands a think.
	mind.last_move = _keep_move(mind.last_move, move)
	mind.last_fire = _keep_fire(mind.last_fire, fire)
	if mind.coasting and _tier_on:
		# A tiered coast repeats only held buttons: a jump or a weapon switch is pressed on the think tick, then let go.
		mind.last_move.buttons &= _COAST_MOVE if intent.state != &"dead" else 0
		mind.last_fire.buttons &= _COAST_FIRE if intent.state != &"dead" else 0
	made = _recoil_comp(bot, mind, made, tick, tick_rate)
	FcFrameProbe.lap(&"ba_tail", t_tail)
	return made


## The bot's next beat (its tier's period, or a coast over the ticks until it) and how far its view turns this tick:
## a coast spreads the brain's turn over the beat, a think after coasted ticks is held to one tick's turn.
static func _schedule_beat(bot: FcPlayer, mind: Mind, world: World, me: GSBotContact, intent: GSBotIntent,
		move: GSFpsCommand, fire: GSWeaponCommand, tick: int, tick_rate: float) -> void:
	world.woken.erase(bot.player_id)
	if _tier_on and tiers.is_on():
		mind.far = false
		var engaged := intent.target_id >= 0 and not world.brains.has(intent.target_id)
		# every here is the coast's length: to the bot's next beat at its tier's period.
		# Idle: no target, or dead (a bot fighting a bot is neither); a seen idle bot thins to tiers.idle_view_every.
		var idle := intent.target_id < 0
		# Body tiers (on above tiers.body_above players, bot_tier_body_every_near/far; 1 is off): a coasting bot nobody sees, nears or fights moves every few ticks.
		_schedule_tiers(bot, mind, me.position, engaged, idle, tick, _tier_coastable(mind, intent))
	else:
		bot.body_every = 1
		mind.far = _every > 1 and _nobody_near(me, world)
		mind.every = _every if mind.far else 1
		# Only a think on the bot's own beat starts a coast, so the coast's steps count from it.
		mind.coasting = mind.far and (tick + mind.seed) % _every == 0 and _coastable(mind, intent, move, fire)
	if mind.coasting:
		# The brain turned for `every` ticks at once; spread over them, so no tick turns faster than bot_turn_rate.
		mind.view_to = Vector2(move.yaw, move.pitch)
		# From the view the body has, which a respawn or a teleport may have turned since the last command.
		var from := Vector2(me.view_yaw, me.view_pitch)
		mind.view_from = from
		move.yaw = from.x + _turn(from.x, mind.view_to.x) / float(mind.every)
		move.pitch = from.y + (mind.view_to.y - from.y) / float(mind.every)
	elif (_every > 1 or _tier_on) and mind.last_think_tick >= 0 and tick - mind.last_think_tick > 1:
		# A think after coasted ticks: the brain's turn limit is bot_turn_rate times the time since its last
		# think, so it turned for the whole gap at once (twice bot_turn_rate in one tick, the headless_bots
		# turn-rate failure). Held to one tick's turn from the body's view; the aim closes over the next ticks.
		var rate := mind.brain.settings.profile.turn_rate / tick_rate
		var body := Vector2(me.view_yaw, me.view_pitch)
		move.yaw = body.x + clampf(_turn(body.x, move.yaw), -rate, rate)
		move.pitch = body.y + clampf(move.pitch - body.y, -rate, rate)
		if mind.throw_stage in [THROW_DRAW, THROW_COOK, THROW_RELEASE]:
			# A throw that starts on this think froze the brain's whole-gap turn as the view it holds
			# until the grenade leaves; it holds the clamped view instead, so its first tick turns no faster.
			mind.throw_view = Vector2(move.yaw, move.pitch)
			fire.yaw = move.yaw
			fire.pitch = move.pitch

## The part of [method think_finish] before the commands are written: a stranded bot respawned, the surf's steer.
static func _finish_begin(game: Object, bot: FcPlayer, mind: Mind, intent: GSBotIntent, world: World, tick: int, tick_rate: float) -> void:
	unstrand(game, bot, mind, intent)
	var surf := world.surf_at(tick)
	if surf != null:
		surf.call(&"steer", bot, mind, intent, tick, tick_rate)
	elif mind.ride != null:
		mind.ride = null


## [method think_finish] for the bots [param pending] indexes in [param players] and [param minds], into [param out]:
## every bot steered first, then one gs-sim call (GSSimBotFinish.write) makes all their sticks and buttons, which
## each bot's finish copies into its commands instead of [method _write]. [method finish_native] says whether it can.
static func finish_all(game: Object, players: Array, minds: Array, pending: Array[int], out: Array, tick: int, tick_rate: float) -> void:
	var n := pending.size()
	var t_after := Time.get_ticks_usec()
	var t_lap := FcFrameProbe.lap_start()
	_rows_in_stick.resize(n)
	_rows_in_bits.resize(n)
	for k in n:
		var i := pending[k]
		var mind: Mind = minds[i]
		var intent: GSBotIntent = mind.t_intent
		_finish_begin(game, players[i], mind, intent, mind.t_world, tick, tick_rate)
		_rows_in_stick[k] = intent.move
		_rows_in_bits[k] = _intent_bits(intent)
	t_lap = FcFrameProbe.lap(&"ba_surf", t_lap)
	var cols: Array = ClassDB.class_call_static(FINISH_CLASS, &"write", _rows_in_stick, _rows_in_bits, _finish_move_map, _finish_fire_map)
	_rows_stick = cols[0]
	_rows_move = cols[1]
	_rows_fire = cols[2]
	finished_native += n
	FcFrameProbe.lap(&"ba_write", t_lap)
	FcFrameProbe.add(&"bot_after", t_after)
	for k in n:
		var i := pending[k]
		out[i] = think_finish(game, players[i], minds[i], tick, tick_rate, k)


## [param intent]'s buttons as the bits GSSimBotFinish reads ([member _finish_move_map]'s order; gs-bot's GSBotIntentTable bits).
static func _intent_bits(intent: GSBotIntent) -> int:
	var b := 0
	if intent.fire:
		b |= 1
	if intent.crouch:
		b |= 2
	if intent.jump:
		b |= 4
	if intent.walk:
		b |= 8
	if intent.air_jump:
		b |= 16
	if intent.use:
		b |= 64
	return b


## Whether [method finish_all] runs: [member native_finish] on and the loaded gs-sim has GSSimBotFinish.
static func finish_native() -> bool:
	if not native_finish:
		return false
	if _finish_known < 0:
		_finish_known = 1 if ClassDB.class_exists(FINISH_CLASS) and ClassDB.class_has_method(FINISH_CLASS, &"write") else 0
	return _finish_known == 1


## [param from] copied into [param into] (as [method GSFpsCommand.duplicate_command] copies it), or a copy when there is none yet.
static func _keep_move(into: GSFpsCommand, from: GSFpsCommand) -> GSFpsCommand:
	if into == null:
		return from.duplicate_command()
	into.move = from.move
	into.yaw = from.yaw
	into.pitch = from.pitch
	into.buttons = from.buttons
	return into


## [param from] copied into [param into] (as [method GSWeaponCommand.duplicate_command] copies it), or a copy when there is none yet.
static func _keep_fire(into: GSWeaponCommand, from: GSWeaponCommand) -> GSWeaponCommand:
	if into == null:
		return from.duplicate_command()
	into.slot = from.slot
	into.buttons = from.buttons
	into.yaw = from.yaw
	into.pitch = from.pitch
	return into


## [method GSBotIntent.write_move] (air jump on BUTTON_USER_0) and [method GSBotIntent.write_fire] for this game's
## own command classes, typed: the generic writers find each button's constant by name on the command's script, six
## dynamic lookups and calls per bot per tick (ba_write, half of bot_after). headless_bots checks both write the same.
static func _write(intent: GSBotIntent, move: GSFpsCommand, fire: GSWeaponCommand) -> void:
	move.yaw = intent.yaw
	move.pitch = intent.pitch
	move.move = intent.move.limit_length(1.0)
	move.set_button(GSFpsCommand.BUTTON_CROUCH, intent.crouch)
	move.set_button(GSFpsCommand.BUTTON_JUMP, intent.jump)
	move.set_button(GSFpsCommand.BUTTON_WALK, intent.walk)
	move.set_button(GSFpsCommand.BUTTON_USER_0, intent.air_jump)
	fire.yaw = intent.yaw
	fire.pitch = intent.pitch
	fire.set_button(GSWeaponCommand.BUTTON_USE, intent.use)
	fire.set_button(GSWeaponCommand.BUTTON_ATTACK, intent.fire)


## bot_native_finish: with bot_threads on, the threaded bots' sticks and buttons come from one gs-sim call a tick
## ([method finish_all]); off, or without GSSimBotFinish, each bot's [method _write]. headless_botthreads plays both to the bit.
static var native_finish := true
## Rows [method finish_all] wrote through gs-sim, for the suite.
static var finished_native := 0
## bot_par_route: with bot_threads on, a worker's route asks the nav mesh and the navigation server without the world
## lock once par_begin has built the mesh's lazy answers (gs-bot's GSBotNav.warm_queries) and the map's links are done;
## off, or on a map with no mesh, each route waits on the lock. headless_botthreads plays both to the bit.
static var par_route := true
## Ticks whose worker routes skipped the lock, for the suite.
static var routed_free := 0
const FINISH_CLASS := &"GSSimBotFinish"
## Per intent bit (fire, crouch, jump, walk, air jump, throw, use, stranded), the command bit it sets: [method _write]'s buttons.
static var _finish_move_map := PackedInt32Array([0, GSFpsCommand.BUTTON_CROUCH, GSFpsCommand.BUTTON_JUMP, GSFpsCommand.BUTTON_WALK, GSFpsCommand.BUTTON_USER_0, 0, 0, 0])
static var _finish_fire_map := PackedInt32Array([GSWeaponCommand.BUTTON_ATTACK, 0, 0, 0, 0, 0, GSWeaponCommand.BUTTON_USE, 0])
static var _finish_known := -1
## [method finish_all]'s columns, kept from tick to tick: in (the brains' sticks and bits) and out (gs-sim's).
static var _rows_in_stick := PackedVector2Array()
static var _rows_in_bits := PackedInt32Array()
static var _rows_stick := PackedVector2Array()
static var _rows_move := PackedInt32Array()
static var _rows_fire := PackedInt32Array()

## Off only for tests that measure the bots without the correction (headless_bot_hitreg).
static var recoil_compensation := true
## bot_native_think: every bot hands out one pair of commands of its own, overwritten every tick (Mind.out), instead
## of two new commands and an array a tick; 0 makes new ones. headless_botthreads plays both to the same digests.
static var reuse_commands := true

## bot_brains_per_tick: brains built on one tick at most; a bot past it stands still until a later tick builds its own. 0 = no limit.
static var brains_per_tick := 4

## Whether the think tiers come from [code]GSBotThinkTier.schedule[/code] (gs-bot API 27) or, on a host's gs-bot 26
## (the live shell's pin), from period, until_beat and body_period, which answer the same. headless_botthreads plays both.
static var tier_schedule := GSAddonApi.build_level("gs_bot") >= 27
## Whether [code]GSBotBrain[/code] has phase timers (gs-bot API 29) for the sim host's SIM_HOST_PHASES line.
static var brain_phases := GSAddonApi.build_level("gs_bot") >= 29
## Whether brains on worker threads time too (gs-bot API 40: a clock per brain, [code]GSBotBrain.merge_phases[/code]
## after the join), so the brain phases stay on with bot threads.
static var brain_merge := GSAddonApi.build_level("gs_bot") >= 40

## bot_recoil_control: the share of the recoil a bot pulls its aim back against, 0..1; below 0 (the default, -1)
## by difficulty from [constant RECOIL_CONTROL]. A whole share made every bot's burst a laser no person matches.
static var recoil_control := -1.0
## Weapon id -> recoil seed, for [method _recoil_seed].
static var _recoil_seeds: Dictionary = {}
const RECOIL_CONTROL := {"easy": 0.3, "medium": 0.55, "hard": 0.75, "nightmare": 0.9}


## The share of the recoil [param mind]'s bot pulls back against.
static func recoil_share(mind: Mind) -> float:
	if recoil_control >= 0.0:
		return clampf(recoil_control, 0.0, 1.0)
	var preset := GSBotProfile.DEFAULT_PRESET
	if mind != null and mind.brain != null and mind.brain.settings != null and mind.brain.settings.profile != null:
		preset = mind.brain.settings.profile.preset_name
	return float(RECOIL_CONTROL.get(preset, RECOIL_CONTROL[GSBotProfile.DEFAULT_PRESET]))


## The commands with the aim turned against the recoil the next shot will carry. The weapon offsets each bullet by
## the kick left from the shots before it (gs-weapon's recoil rules); a player pulls the view back against it, but
## a bot's view is its command, so held on a target the bullets walked off it: most of a held burst missed a
## target dead on the crosshair (headless_bot_hitreg). Only the trigger-down tick is turned, and the stored
## last commands the coast repeats are not, so the correction never compounds.
static func _recoil_comp(bot: FcPlayer, mind: Mind, cmds: Array, tick: int, tick_rate: float) -> Array:
	mind.recoil_comp = Vector2.ZERO
	if not recoil_compensation:
		return cmds
	var fire: GSWeaponCommand = cmds[1]
	if bot == null or bot.arsenal == null or not fire.is_pressed(GSWeaponCommand.BUTTON_ATTACK):
		return cmds
	var row := recoil_row(bot, recoil_share(mind))
	return recoil_turn(mind, cmds, recoil_preview(row, tick, tick_rate) if not row.is_empty() else Vector2.ZERO)


## [param cmds] with the view turned back by [param offset] (pitch up, yaw left), kept in [member Mind.recoil_comp].
static func recoil_turn(mind: Mind, cmds: Array, offset: Vector2) -> Array:
	if offset == Vector2.ZERO:
		return cmds
	var move: GSFpsCommand = cmds[0]
	move.pitch -= offset.x
	move.yaw -= offset.y
	mind.recoil_comp = Vector2(offset.y, offset.x)
	return cmds


## Degrees (pitch up, yaw left) the next bullet of [param bot]'s weapon is turned off its aim by recoil, as
## [method GSWeaponRecoilRules.apply] will work it out at [param tick]; zero with recoil patterns off.
static func next_recoil_offset(bot: FcPlayer, tick: int, tick_rate: float) -> Vector2:
	var row := recoil_row(bot, 1.0)
	return recoil_preview(row, tick, tick_rate) if not row.is_empty() else Vector2.ZERO


## The numbers [method recoil_preview] works [param bot]'s next recoil from, with [param taken] the share of it kept;
## empty with recoil patterns off. Raw, in gs-sim's [code]recoil_preview[/code] row order: rules.reset,
## b.recoil_recovery, rules.recovery, b.recoil_build, rules.build, b.recoil_build_max, b.recoil_pitch, rules.vertical,
## b.recoil_yaw, rules.horizontal, the camera share, rules.follow, the seed, the burst's last tick, n, ax, ay, taken.
static func recoil_row(bot: FcPlayer, taken: float) -> PackedFloat64Array:
	var rr := GSWeaponRecoilRules.of(bot.arsenal)
	var slot: GSWeaponSlot = bot.arsenal.current()
	if rr == null or slot == null or slot.behaviour == null or slot.behaviour.def == null:
		return PackedFloat64Array()
	var b := slot.behaviour.def.tuning as GSWeaponBallistics
	if b == null:
		return PackedFloat64Array()
	var state: Dictionary = slot.behaviour.state
	return PackedFloat64Array([rr.reset, b.recoil_recovery, rr.recovery, b.recoil_build, rr.build, b.recoil_build_max,
		b.recoil_pitch, rr.vertical, b.recoil_yaw, rr.horizontal, b.recoil_camera if b.recoil_camera >= 0.0 else rr.punch,
		rr.follow, _recoil_seed(b, slot.behaviour.def.id), int(state.get(&"recoil_tick", -1000000)),
		int(state.get(&"recoil_n", 0)), float(state.get(&"recoil_ax", 0.0)), float(state.get(&"recoil_ay", 0.0)), taken])


## Degrees (pitch up, yaw left) the next bullet is turned off its aim by recoil, as [method GSWeaponRecoilRules.apply]
## will work it out at [param tick] (without the posture), times the row's share: gs-sim's [code]GSSimBotCoast[/code]
## works the same to the bit (headless_botthreads compares them).
static func recoil_preview(r: PackedFloat64Array, tick: int, tick_rate: float) -> Vector2:
	var elapsed := maxf(float(tick - int(r[13])) / maxf(tick_rate, 1.0), 0.0)
	var n := int(r[14]) if elapsed <= r[0] else 0
	var residual := Vector2(r[15], r[16]) * exp(-r[1] * r[2] * elapsed)
	var grow := 1.0 + minf(r[3] * r[4] * float(n), r[5] * r[4])
	var kick := Vector2(r[6] * r[7] * grow, r[8] * r[9] * grow * GSWeaponRecoilRules.drift(int(r[12]), n))
	var share := r[10]
	return ((residual + kick) * (1.0 - share) + residual * share * r[11]) * r[17]


## [method GSWeaponRecoilRules.seed_for], with the hash of a weapon id kept: it is worked from the id's bytes on every
## call, and a coasting bot asks for it each tick it holds the trigger.
static func _recoil_seed(b: GSWeaponBallistics, id: StringName) -> int:
	if b.recoil_seed != 0:
		return b.recoil_seed
	var cached: Variant = _recoil_seeds.get(id)
	if cached == null:
		cached = GSWeaponRecoilRules.seed_for(b, id)
		_recoil_seeds[id] = cached
	return cached


## Degrees from [param a] to [param b] the short way round.
static func _turn(a: float, b: float) -> float:
	return fposmod(b - a + 180.0, 360.0) - 180.0


## The commands of a tick the brain sits out: the last ones, with the view carried on towards where the last think turned it.
static func _coast(mind: Mind, tick: int) -> Array:
	var step := tick - mind.last_think_tick
	var fraction := float(step + 1) / float(mind.every)
	return coast_pair(mind, mind.view_from.x + _turn(mind.view_from.x, mind.view_to.x) * fraction,
		mind.view_from.y + (mind.view_to.y - mind.view_from.y) * fraction)


## The coasting pair of [param mind]'s bot: its last commands with the view at [param yaw] and [param pitch], kept as
## its last move's too ([method _coast] works them here, [code]GSSimBotCoast[/code] for a whole tick in FcBotCoast).
static func coast_pair(mind: Mind, yaw: float, pitch: float) -> Array:
	var made := _out_pair(mind)
	var move := _keep_move(made[0], mind.last_move)
	move.yaw = yaw
	move.pitch = pitch
	mind.last_move.yaw = yaw
	mind.last_move.pitch = pitch
	made[1] = _keep_fire(made[1], mind.last_fire)
	return made


## The pair [param mind]'s bot hands out this tick: its own, overwritten every tick with [member reuse_commands],
## else two new commands (the commands' four fields each are all the pair carries; a consumer copies what it keeps).
static func _out_pair(mind: Mind) -> Array:
	if not reuse_commands:
		return [GSFpsCommand.new(), GSWeaponCommand.new()]
	if mind.out.is_empty():
		mind.out = [GSFpsCommand.new(), GSWeaponCommand.new()]
	return mind.out


## [param move] and [param fire] as new commands are.
static func _clear(move: GSFpsCommand, fire: GSWeaponCommand) -> void:
	move.move = Vector2.ZERO
	move.yaw = 0.0
	move.pitch = 0.0
	move.buttons = 0
	fire.slot = 0
	fire.buttons = 0
	fire.yaw = 0.0
	fire.pitch = 0.0


## Whether a bot that just thought may sit out the next ticks: nothing in hand but a walk.
static func _coastable(mind: Mind, intent: GSBotIntent, move: GSFpsCommand, fire: GSWeaponCommand) -> bool:
	return mind.ride == null and mind.throw_stage == 0 and intent.target_id < 0 and intent.state != &"dead" \
		and move.buttons == 0 and fire.buttons == 0


## Whether a tiered bot that just thought may sit out the next ticks: no ride or throw. Its edge buttons are not
## repeated (see [method think_finish]), so a fight or a jump may coast; a dead bot coasts with nothing pressed.
static func _tier_coastable(mind: Mind, _intent: GSBotIntent) -> bool:
	return mind.ride == null and mind.throw_stage == 0


## A thought bot's think and body tiers: one [code]GSBotThinkTier.schedule[/code] (gs-bot API 27; native in gs-sim when
## loaded), or on a host's gs-bot 26 the three calls it replaced, which answer the same (headless_botthreads plays both).
static func _schedule_tiers(bot: FcPlayer, mind: Mind, at: Vector3, engaged: bool, idle: bool, tick: int, coastable: bool) -> void:
	var floor_every := think_floor_engaged if engaged else think_floor
	if tier_schedule:
		# Untyped: gs-bot 26 has no schedule, and a typed call would not parse there.
		var plan: Vector2i = tiers.call(&"schedule", bot.player_id, at, engaged, idle, tick, mind.seed, floor_every, coastable)
		mind.every = plan.x
		mind.coasting = plan.x > 1 and coastable
		bot.body_every = plan.y
	else:
		mind.every = GSBotThinkTier.until_beat(tick, mind.seed, maxi(tiers.period(bot.player_id, at, engaged, idle), floor_every))
		mind.coasting = mind.every > 1 and coastable
		bot.body_every = tiers.body_period(bot.player_id, at, engaged, idle) if mind.coasting else 1


## Whether this tick repeats the last commands rather than think. See [member think_every] and [member tiers].
static func _coasts(mind: Mind, tick: int, world: World, id: int) -> bool:
	if not mind.coasting or mind.every <= 1 or mind.last_move == null or mind.brain == null or mind.ride != null or mind.throw_stage != 0:
		return false
	if mind.last_think_tick < 0 or tick <= mind.last_think_tick or tick - mind.last_think_tick >= mind.every:
		return false
	return not world.woken.has(id)


## Whether no live enemy of [param me] is within [member think_near] metres.
static func _nobody_near(me: GSBotContact, world: World) -> bool:
	var near_sq := think_near * think_near
	var t := world.table()
	if world.near_cell > 0.0 and world.near_cell == think_near:
		var cx := int(floorf(me.position.x / think_near)) + 4096
		var cz := int(floorf(me.position.z / think_near)) + 4096
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var cell: Variant = world.near_cells.get((cx + dx) * 8192 + cz + dz)
				if cell == null:
					continue
				if t != null:
					for i: int in cell:
						if t.live_enemy(i, me) and t.positions[i].distance_squared_to(me.position) < near_sq:
							return false
					continue
				for item: GSBotContact in cell:
					if item.id != me.id and me.is_enemy(item) and item.position.distance_squared_to(me.position) < near_sq:
						return false
		return true
	if t != null:
		for i in t.size():
			if t.live_enemy(i, me) and t.positions[i].distance_squared_to(me.position) < near_sq:
				return false
		return true
	for item: GSBotContact in world.contacts():
		if item.alive and item.id != me.id and me.is_enemy(item) and item.position.distance_squared_to(me.position) < near_sq:
			return false
	return true


## Turns the brain's [member GSBotIntent.throw] into the presses a person makes: draw the
## throwable, cook it, let go along the view the brain chose, and draw what was held before.
## While a throw is under way it owns the trigger, the slot and the view; the legs stay the
## brain's.
static func _throw(bot: FcPlayer, mind: Mind, intent: GSBotIntent, move: GSFpsCommand, fire: GSWeaponCommand, tick: int, tick_rate: float) -> void:
	var arsenal := bot.arsenal
	if arsenal == null or not bot.is_alive():
		mind.throw_stage = 0
		return
	if mind.throw_stage == 0:
		if not intent.throw or not _has_throwable(arsenal):
			return
		mind.throw_stage = THROW_DRAW
		mind.throw_view = Vector2(intent.yaw, intent.pitch)
		mind.throw_back = arsenal.current_slot()
		mind.throw_at = tick

	var thrown := AwWeaponIds.thrown_slot()
	if tick - mind.throw_at > int(THROW_GIVE_UP_SEC * tick_rate) and mind.throw_stage < THROW_RELEASE:
		mind.throw_stage = THROW_RELEASE if mind.throw_stage == THROW_COOK else THROW_BACK

	fire.set_button(GSWeaponCommand.BUTTON_ATTACK, false)
	match mind.throw_stage:
		THROW_DRAW:
			fire.slot = thrown
			if arsenal.current_slot() == thrown and not arsenal.is_switching():
				mind.throw_stage = THROW_COOK
				mind.throw_cook_from = tick
				fire.set_button(GSWeaponCommand.BUTTON_ATTACK, true)
		THROW_COOK:
			fire.set_button(GSWeaponCommand.BUTTON_ATTACK, true)
			if tick - mind.throw_cook_from >= maxi(1, int(COOK_SEC * tick_rate)):
				mind.throw_stage = THROW_RELEASE
		THROW_RELEASE:
			# The trigger up on this tick is the throw.
			mind.throw_stage = THROW_BACK
		THROW_BACK:
			var back := mind.throw_back if mind.throw_back > 0 and mind.throw_back != thrown and arsenal.has_slot(mind.throw_back) else 0
			if back > 0 and arsenal.current_slot() != back:
				fire.slot = back
			if back == 0 or arsenal.current_slot() == back or tick - mind.throw_at > int(THROW_GIVE_UP_SEC * tick_rate) * 2:
				mind.throw_stage = 0

	if mind.throw_stage in [THROW_DRAW, THROW_COOK, THROW_RELEASE]:
		# Looking where the brain lobbed it until it is gone.
		for command: Object in [move, fire]:
			command.set(&"yaw", mind.throw_view.x)
			command.set(&"pitch", mind.throw_view.y)


## Draws the carried gun that suits the fight: one that reaches the target (`params.max_range`) and
## can still pay for a shot, the primary before the sidearm, the sidearm inside [constant GUN_CLOSE]
## when the primary is scoped. Only for a bot that drew a kit; checked one tick in [constant GUN_CHECK_EVERY].
static func _choose_gun(bot: FcPlayer, mind: Mind, world: World, me: GSBotContact, intent: GSBotIntent, fire: GSWeaponCommand, tick: int) -> void:
	if mind.throw_stage != 0 or fire.slot != 0 or (tick + mind.seed) % GUN_CHECK_EVERY != 0:
		return
	var arsenal := bot.arsenal
	if arsenal == null or me == null or arsenal.is_switching() or not bot.is_alive():
		return
	var dist := -1.0
	if intent.target_id >= 0:
		var target := world.contact(intent.target_id)
		if target != null:
			dist = target.position.distance_to(me.position)
	var want := gun_for(arsenal, dist)
	if want > 0 and want != arsenal.current_slot():
		fire.slot = want


## The slot of the gun to hold against a target [param dist] metres off (-1 for none), or 0 for no
## change: the held gun while it suits, else a suiting primary, a suiting sidearm, the longest reach.
static func gun_for(arsenal: GSWeaponArsenal, dist: float) -> int:
	var held := arsenal.current_slot()
	# With nobody to shoot, a bot holding its sidearm goes back to the primary.
	if _gun_suits(arsenal, held, dist) and (dist >= 0.0 or _gun_kind(held) != 2):
		return 0
	var best := 0
	var longest := 0
	for slot in arsenal.slots():
		var kind := _gun_kind(slot)
		if kind == 0 or not _can_pay(arsenal, slot):
			continue
		if _gun_suits(arsenal, slot, dist) and (best == 0 or kind < _gun_kind(best)):
			best = slot
		if longest == 0 or _gun_range(arsenal, slot) > _gun_range(arsenal, longest):
			longest = slot
	# Nothing reaches: the longest gun at least gets the bot into the fight.
	if best == 0:
		best = longest
	return 0 if best == held else best


## Whether the gun in [param slot] can shoot a target [param dist] metres off (-1 for none).
static func _gun_suits(arsenal: GSWeaponArsenal, slot: int, dist: float) -> bool:
	if _gun_kind(slot) == 0 or not _can_pay(arsenal, slot):
		return false
	if dist < 0.0:
		return true
	if dist > _gun_range(arsenal, slot):
		return false
	return dist >= GUN_CLOSE or not arsenal.slot_at(slot).def.has_tag(AwWeaponIds.TAG_SCOPED)


## 1 for a primary or heavy, 2 for a sidearm, 0 for what is not a gun (melee, throwables).
static func _gun_kind(slot: int) -> int:
	var rank := FcContent.give_rank(slot)
	if rank == 0 or rank == 3:
		return 0
	return 2 if rank == 2 else 1


## How far the gun in [param slot] reaches, metres; unbounded when the weapon does not say.
static func _gun_range(arsenal: GSWeaponArsenal, slot: int) -> float:
	var held := arsenal.slot_at(slot)
	if held == null or held.def == null:
		return 0.0
	return float(held.def.params.get(&"max_range", INF))


## Whether the weapon in [param slot] can pay for a shot, from its magazine or its reserve.
static func _can_pay(arsenal: GSWeaponArsenal, slot: int) -> bool:
	var held := arsenal.slot_at(slot)
	if held == null or held.def == null:
		return false
	var def := held.def
	if not def.uses_ammo() or def.infinite_reserve:
		return true
	if def.uses_magazine() and held.magazine >= def.cost_per_use:
		return true
	return arsenal.ammo().has(def.ammo_type, def.cost_per_use)


## Whether [param arsenal] holds a throwable it can pay for.
static func _has_throwable(arsenal: GSWeaponArsenal) -> bool:
	var slot := arsenal.slot_at(AwWeaponIds.thrown_slot())
	if slot == null or slot.def == null:
		return false
	var def := slot.def
	if not def.uses_ammo():
		return true
	if def.uses_magazine():
		return slot.magazine >= def.cost_per_use
	return def.infinite_reserve or arsenal.ammo().has(def.ammo_type, def.cost_per_use)


## Forgets a bot that left, so its brain is not told about hits any more.
static func forget(game: Object, id: int) -> void:
	if game != null and game.has_meta(WORLD_META):
		var held: Variant = game.get_meta(WORLD_META)
		if held is World:
			(held as World).brains.erase(id)
			(held as World)._loadouts.erase(id)
			(held as World).woken.erase(id)
			if (held as World).objective != null:
				(held as World).objective.release(id)
			if (held as World)._personas != null:
				(held as World)._personas.release(StringName(str(id)))
