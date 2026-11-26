## The engine switches among the server cvars: the bots' and motors' native and threaded paths, the hull grid
## and the bots' PVS pre-cull. Base of fc_module_cvars.gd, split out for the size gate.
extends "fc_nameplate_cvars.gd"

const FcPlayer := preload("fc_player.gd")
const FcBotBrain := preload("fc_bot_brain.gd")
const FcBotThreads := preload("fc_bot_threads.gd")
const FcPlayerStack := preload("fc_player_stack.gd")
const FcHullGrid := preload("fc_hull_grid.gd")
const FcNativeTick := preload("fc_native_tick.gd")
const FcContent := preload("fc_content.gd")
const FcBotPvs := preload("fc_bot_pvs.gd")
const FcBotRows := preload("fc_bot_rows.gd")
const FcBotContacts := preload("fc_bot_contacts.gd")
const FcSpawnPick := preload("fc_spawn_pick.gd")
const FcWeaponTickCvars := preload("fc_weapon_tick_cvars.gd")
const FcWeaponDropWiring := preload("fc_weapon_drop_wiring.gd")


## The native/threaded switches of the bot and motor engines.
func _add_bot_engine_cvars() -> void:
	add_cvar("bot_fast_sense", "1" if FcBotBrain.fast_sense else "0",
		"1: bots scan candidates by squared distance and cone cosine (same result, cheaper); 0: gs-bot's stock scan",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcBotBrain.fast_sense = new_value.to_float() >= 0.5)
	add_cvar("bot_threads", str(FcBotThreads.threads),
		"Threads that run the bots' brains in parallel (the main thread is one); 0 thinks one bot after another on the main thread",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(64.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcBotThreads.threads = maxi(0, int(new_value.to_float())))
	add_cvar("bot_native", "1" if GSBotWorld.native_enabled else "0",
		"1: the bots' sight scan runs in gs-sim when its library is installed (same result, cheaper); 0: in script. Without the library it is script either way",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			GSBotWorld.native_enabled = new_value.to_float() >= 0.5)
	# On by default (FcPlayerStack._static_init): with a gs-sim whose mind is worker_safe, native brains
	# stay native on bot_threads workers (gs-bot API 34 par_ready), and a 64-player sim host on staging02 spends
	# ~0.25 ms/tick less on bot_brain (nightly simhost-bot-native-glue-1). An older library thinks in script there.
	add_cvar("bot_native_brain", "1",
		"1: the bots' aim, fight step and perception run in gs-sim when its library has the bot mind (the same decisions to the bit, cheaper; on bot_threads workers too with a worker-safe library); 0: in script. Takes effect for bots added after the change",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcPlayerStack.set_brain_native(new_value.to_float() >= 0.5))
	# gs-bot 46/47, by name (an older gs-bot ignores them); both on by default in gs-bot, and the same to the bit.
	add_cvar("bot_native_pickup", "1",
		"1: a quiet bot chooses which weapon on the floor to walk to in gs-sim, over the drops packed once per tick, when its library has the choice (the same drop to the bit); 0: in script, reading the drops every time",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			(GSBotBrain as Script).set(&"native_pickup", new_value.to_float() >= 0.5))
	# gs-bot 49, by name (an older gs-bot ignores it); on by default in gs-bot, the same columns to the bit.
	add_cvar("bot_native_drops", "1",
		"1: the drops the bots read are packed once per tick in gs-sim, each weapon looked up once, when its library has the pack (the same table to the bit); 0: in script, every weapon looked up per drop",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			(GSBotWorld as Script).set(&"native_drops", new_value.to_float() >= 0.5))
	# gs-bot 50, by name (an older gs-bot ignores it); on by default in gs-bot, the same answer to the bit.
	add_cvar("bot_native_unstick", "1",
		"1: a bot's stuck watch (re-plan, hop, crouch-hop, side-step, the stranded report) steps in gs-sim when its library has it, the state kept in the mind (the same answer to the bit; the nudge's standable-point query stays in script); 0: in script",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			(GSBotUnstick as Script).set(&"native_enabled", new_value.to_float() >= 0.5))
	add_cvar("bot_native_act", "1",
		"1: a roaming bot's steer (walk, hold, drift, look, glance, turn and legs) runs in gs-sim when its library has it, the glance kept in the mind between thinks (the same moves to the bit); 0: in script",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			(GSBotBrain as Script).set(&"native_act", new_value.to_float() >= 0.5))
	add_cvar("bot_native_think", "1",
		"1: the bots' world hands gs-sim's sight scan its contact table, filled while the contacts are built (gs-bot 37; the same answers, one walk of the contacts fewer per tick), every bot hands out one pair of commands of its own, overwritten every tick, and the movement tricks run in gs-sim (gs-bot 39, the same choices); 0: gs-bot packs the contacts itself, every tick makes new commands and runs the tricks in script",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcBotRows.set_native_think(new_value.to_float() >= 0.5))
	add_cvar("bot_native_contacts", "1",
		"1: the bots' worlds build their contacts and sight rows in gs-sim when its library has them (GSSimBotContacts; the same contacts to the bit, one call a tick); 0, or without the library: the script loop",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcBotContacts.enabled = new_value.to_float() >= 0.5)
	_add_motor_engine_cvars()


## The players' movement, ragdoll, net-pack and controller switches, and the client's carry check.
func _add_motor_engine_cvars() -> void:
	add_cvar("motor_native", "1" if GSFpsPhysicsBody.native_enabled else "0",
		"1: the players' movement collision queries (sweep, rest contact, overlap) run in gs-sim when its library is installed (bit-identical to the script, so web and native clients still agree; cheaper); 0: in script. Without the library it is script either way",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			GSFpsPhysicsBody.native_enabled = new_value.to_float() >= 0.5)
	# By name: a no-op against a gs-player-char older than the switch.
	add_cvar("ragdoll_native", "0" if (GSPlayerRagdoll as Script).get(&"native_pose") == false else "1",
		"1: a skinned ragdoll's bones follow its parts in gs-sim when its library is installed (the same bone poses as the script, to the bit; cheaper); 0: in script. Client-side looks only; without the library it is script either way",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			(GSPlayerRagdoll as Script).set(&"native_pose", new_value.to_float() >= 0.5))
	# On by default (FcPlayerStack._static_init); Fatal Contact suites run it against the script's bits.
	add_cvar("motor_native_tick", "1",
		"1: a plain ground or air tick's start and end (ground check, friction, acceleration, gravity, collide-and-slide) run in gs-sim as one call each when its library has the motor tick (bit-identical to the script); 0: in script. Needs motor_native; without the library it is script either way",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			GSFpsMotor.native_tick = new_value.to_float() >= 0.5)
	add_cvar("motor_native_full", "1" if GSFpsMotor.native_full else "0",
		"1: with motor_native_tick, the whole tick (jumps, slides, launches, dashes, wall runs and wall jumps too) runs in gs-sim as one call when its library has it (bit-identical to the script); 0: only the start and end",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			GSFpsMotor.native_full = new_value.to_float() >= 0.5)
	# By name: a no-op against a gs-player-controller older than API 38.
	add_cvar("net_pack_native", "0" if (GSFpsNetSync as Script).get(&"native_pack") == false else "1",
		"1: the server packs each player's replicated flags, timers and stamina in gs-sim when its library is installed (the same integers as the script, to the bit; cheaper); 0: in script. Without the library it is script either way",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			(GSFpsNetSync as Script).set(&"native_pack", new_value.to_float() >= 0.5))
	# The controller's direct reads: FcPlayer.body_delta's state columns and, by name (gs-player-controller 44),
	# GSFpsController.direct_getters for its collider sizing. A no-op on builds without either.
	add_cvar("ctl_native", "1" if FcPlayer.body_cols else "0",
		"1: each player's controller reads its packed state columns and engine getters directly (the same values; cheaper per player per tick); 0: through the properties",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			var on := new_value.to_float() >= 0.5
			FcPlayer.body_cols = on and GSAddonApi.build_level("gs_player_controller") >= 36
			(GSFpsController as Script).set(&"direct_getters", on))

	add_cvar("net_carry_fast", "1" if FcContent.carry_fast else "0",
		"1: a client checks its own carried weapons against the received set in one pass, and not at all while its arsenal is unchanged since the set last matched (the same arsenal either way); 0: the full give/take pass every frame",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcContent.carry_fast = new_value.to_float() >= 0.5)


## The players' hull grid (its fast, native and batched gathers) and the bots' PVS sight pre-cull.
func _add_hull_and_pvs_cvars() -> void:
	add_cvar("fc_hull_grid", "1" if FcHullGrid.enabled else "0",
		"1: players' standing hulls are found through a grid filed once per tick (same hulls, cheaper above 12 players); 0: scan the whole roster per bot",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcHullGrid.enabled = new_value.to_float() >= 0.5)
	add_cvar("fc_demo_flush_gate", "1" if FcHullGrid.demo_flush_gate else "0",
		"1: the batched loop keeps idle weapon ticks waiting for one gs-sim call past the demo statistics' turn when they read nothing of that player (bots, or not recording); 0: flush before every turn",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcHullGrid.demo_flush_gate = new_value.to_float() >= 0.5)
	add_cvar("fc_hull_fast", "1" if FcHullGrid.fast else "0",
		"1: the hull gather tests the grid's candidates in one hoisted loop (same hulls); 0: one call per candidate",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcHullGrid.fast = new_value.to_float() >= 0.5)
	add_cvar("fc_hull_native", "1" if FcHullGrid.native else "0",
		"1: with fc_hull_fast, a mover that is not lag-compensated gathers its hulls in gs-sim (same hulls, no script call per player); 0: by script",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcHullGrid.native = new_value.to_float() >= 0.5)
	add_cvar("fc_hull_grid_native", "1" if FcHullGrid.grid_native else "0",
		"1: with fc_hull_native, the players are filed in gs-sim's hull world cells (same hulls, one call a turn); 0: by script",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcHullGrid.grid_native = new_value.to_float() >= 0.5)
	add_cvar("fc_motor_batch", "1" if FcHullGrid.batch else "0",
		"1: with fc_hull_native, gs-sim ticks the players' motors in runs of one call a game tick (same states); 0: one call per player",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcHullGrid.batch = new_value.to_float() >= 0.5)
	add_cvar("fc_tick_events", "0" if not FcHullGrid.events else ("2" if GSFpsTickEvents.native_enabled else "1"),
		"2: with fc_motor_batch, the players' motor edges are one table gs-sim derives after the loop; 1: the same table derived by script; 0: each player's edges inside its own tick",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(2.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			var level := new_value.to_float()
			FcHullGrid.events = level >= 0.5
			GSFpsTickEvents.native_enabled = level >= 1.5)
	add_cvar("sv_native_motor_state", "1" if GSFpsMotorBatch.native_state else "0",
		"1: with fc_motor_batch, each player's motor state stays in gs-sim across ticks, only script writes are sent, and gs-sim's server tick steps the player table once a tick (same states); 0: the script loop alone, every column sent each tick",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			GSFpsMotorBatch.native_state = new_value.to_float() >= 0.5
			FcNativeTick.enabled = GSFpsMotorBatch.native_state)
	add_cvar("sv_native_players", "1" if FcNativeTick.players else "0",
		"1: with fc_motor_batch and fc_tick_events, every player's controller tick is one gs-player-controller call (same states and edges); 0: the players' loop's own two passes",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcNativeTick.players = new_value.to_float() >= 0.5)
	add_cvar("fc_bot_pvs", "1" if FcBotPvs.enabled else "0",
		"1: a bot's sight ray is skipped where the map's PVS rules the pair out (same answers: those rays come back blocked); 0: every ray is cast",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcBotPvs.enabled = new_value.to_float() >= 0.5)
	add_cvar("fc_bot_pvs_native", "1" if FcBotPvs.native else "0",
		"1: with fc_bot_pvs, gs-sim asks the PVS where its library has it (bit for bit with the script), else no pre-cull; 0: the script set (slower than none)",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcBotPvs.native = new_value.to_float() >= 0.5)
	add_cvar("fc_spawn_native", "1" if FcSpawnPick.native else "0",
		"1: a free-for-all (scatter) spawn draws its weights in gs-sim where its library has GSSimSpawnPick and asks every enemy's sight of a site in one trace call (the same picks as gs-spawn); 0: gs-spawn's own pick",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcSpawnPick.native = new_value.to_float() >= 0.5)
	add_cvar("fc_posture_native", "1" if FcPlayer.posture_native else "0",
		"1: an idle weapon tick's posture row and flinch check run in gs-sim where its library has GSSimPlayerPost (bit for bit with the script); 0: the script",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcPlayer.posture_native = new_value.to_float() >= 0.5)
	FcWeaponTickCvars.add_to(self)
	add_cvar("fc_mechanics_native", "1" if FcPlayer.mechanics_native else "0",
		"1: the batched tick asks gs-sim (GSSimVolumes, one call) which players are clear of every map volume and skips their pushes, ladders, water and pits (the same states as the script); 0: every player runs them",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcPlayer.mechanics_native = new_value.to_float() >= 0.5)
	add_cvar("fc_drop_idle_skip", "1" if FcWeaponDropWiring.idle_keys_skip else "0",
		"1: a player with no drop or use key down this tick or last only runs the auto pickup (its key holds are idle); 0: both keys step anyway",
		GSConVar.FLAG_ARCHIVE).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcWeaponDropWiring.idle_keys_skip = new_value.to_float() >= 0.5)
	add_cvar("fc_bot_pvs_verify", "1" if FcBotPvs.verify else "0",
		"1: every sight the PVS rules out is cast anyway and every native ask is put to the script too, disagreements counted (a check, not for play)",
		0).with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			FcBotPvs.verify = new_value.to_float() >= 0.5)
