extends GSGamePerfBench

const FcPresentation := preload("../game/fc_presentation.gd")
const ClientBench := preload("client_bench.gd")
const FcFrameProbe := preload("../game/fc_frame_probe.gd")
const FcHullGrid := preload("../game/fc_hull_grid.gd")
const FcSimHost := preload("../game/fc_sim_host.gd")
const FcNetContext := preload("../game/fc_net_context.gd")
const ProcSplit := preload("proc_split.gd")
const ProcSlices := preload("proc_slices.gd")
# Loaded with this script, so its _static_init (native brain on) runs before --brain-native.
const FcPlayerStack := preload("../game/fc_player_stack.gd")
const FcNpcs := preload("../game/fc_npcs.gd")
const RenderState := preload("render_state.gd")
const DrawCensus := preload("draw_census.gd")

## The 16v16 benchmark: gs-game's GSGamePerfBench (flags, recording, sidecar; see it) on Fatal Contact's client. Windowed on a GPU box (tools/perf_bench.sh) or headless through hv: `godot --path . res://tools/perf_bench.tscn -- --map cp-orange-x3 --mode ctf --bots 31 --seconds 30`. Fatal Contact's flags: `--pilot 0`, `--pilot-view sweep` (the pilot's look turns through the whole compass instead of swaying on one wall: the owner's draw counts need it), `--pilot-view tour` (the pilot is teleported through the spawn points; offline only, a sim host's reconcile puts it back), `--pilot-view fixed` (the drawn camera is the bench's: every spawn point at eye height, one turn each, the whole pass as long as `--seconds`; draws repeat run to run, the perf gate's view), `--motor-us 1`, `--queries 1` (script query timers; native body off), `--ctl-us 1`, `--brain-us 1` (GSBotBrain.think phases, as brain.bb_*), `--max-steps N`, `--native-us 1`, `--batch 0` (`fc_motor_batch` off), `--hull-min N`, `--sim-host 1` (solo game as a loopback server; its cost is the `SIM_HOST` log lines; `--boot-map dm_box` boots there and times a menu map change to the map). `--ragdoll-native 0|1`: gs-player-char's ragdoll bone pose in gs-sim (GSSimRagdollPose) or script; without the library it is script either way (the sidecar's `ragdoll_native` says which ran). `--brain-native 0|1`: gs-bot's native mind (GSSimBotMind: aim, fight step, perception) off or on; without the gs-sim library it is script either way (the sidecar's `brain_native` says which ran). `--tier-idle-seen N`: ticks between thinks of an idle bot a person only sees (bot_tier_every_idle_seen; 1 is the old every tick).
## `--sight-far M`, `--sight-far-reuse S`: bot sight LOD (bot_sight_far, bot_sight_far_reuse; default 20 m and 0.15 s, 0 turns it off). `--tier-body-near N`, `--tier-body-far N`: ticks between motor ticks of a coasting bot nobody sees (bot_tier_body_every_near/far; 1, the default, every tick). `--web-defaults 1`: the browser build's defaults (cl_remote_lod_every 8). Render knobs: `--res 1920x1080`, `--killcam-hz N`, `--killcam-crowd N` (cl_killcam_crowd; 0 never), `--lod-crowd N` (cl_remote_lod_crowd; 0 never), `--lod-scale F` (cl_remote_lod_scale), `--figure-lift-range M` (cl_figure_lift_range; 0 every frame), `--lod 0` (FcPlayer.present_lod_enabled off), `--anim-gate 0` (cl_remote_anim_gate off), `--occl 0` (cl_remote_occlusion off), `--carry 0` (AwWorldModel.person_carry off: the held gun's own kick and reload dip, no humanoid carry), `--world-shadow 0|1`, `--world-shadow-cell M` (r_world_shadow, r_world_shadow_cell), `--central-tick 0|1` (cl_held_central_tick), `--ablate a,b` (after the warm-up: shadowcensus, smallcast, smallcast2, noshadow, nofx, nohud, nobots, no3d, norender, rstate). `--census-every S` (`--census-top N`): a `census` line every S seconds of the recorded window, the draws and the geometry groups by triangles (tools/draw_census.gd), so a spike is caught as it happens. `--first-use 1` (gs-game's first-use rows): every weapon equipped, fired once cold and once warm, before the warm-up (offline only;
## `--first-use-only a,b` for some ids; rows also: hit, kill, death, `reload ID` (`--first-use-reload 0` skips), a thrown weapon's shot over `--first-use-thrown-frames N` frames (default 240: the fuse and blast), `npc ID` and `npc kill ID` with a horde mode such as `--mode siege`); `--prewarm 0` skips the client's weapon warm-up, so `--ab DIR DIR::--prewarm 0 -- --first-use 1` prices it. `--proc-split 1`: the process phase split by wall clock and a census of what processes (tools/proc_split.gd); `--present-ablate N` (FcPlayer.present_ablate bits: 1 no figure animation, 2 no held, 4 held not processing, 8 no pose); `--proc-ablate a,b --proc-slice N` (with --proc-split 1): each named group off for slices of N frames (default 40) between base slices, its ms/frame against them (tools/proc_slices.gd lists the groups; `own:<script>` / `sub:<script>` for one script's nodes). `--script-top N`: the N GDScript functions with the most self time in the report's script_functions (gs-profiler's profiler_script_top); needs the engine started with -d, which slows scripts, so read shares, not ms. `--lazy-models 1`: the client defers the models of weapons nobody carries until after the cover, as the web build does (FcClient defer_models_everywhere), and the bench does not read them all ahead, so `--first-use 1` prices those first equips. `--warm-list 1`: after the first-use rows, a `WARM_LIST <path>` line for every script loaded so far that the cover warms anyway (GSCloudSliceLoader.cached_scripts; pack scripts and addon classes; tools/record_warm_list.sh turns them into warm.txt).

var _pilot := true
var _motor_us := false
## Off by default: the script query timers switch the native body off, so every player would run the
## script collision path (about twice the motor cost) instead of the one a match really runs.
var _queries := false
var _native_us := false
var _ctl_us := false
var _brain_us := false
## `--weapon-us 1`: the rig's and the arsenal's parts of p_weapons, in microseconds per call (off by default: the clocks are inside p_weapons).
var _weapon_us := false
## `--tick N`: the game and engine tick rate (default: the game's, 66); 128 for the 128 Hz cost.
var _tick := 0
var _max_steps := -1
## `--fine 0`: no sub-spans inside a system (FcFrameProbe.fine), so a report matches one from before they were on by default.
var _fine := true
var _ablate := PackedStringArray()
var _sim_host := false
var _sched0 := {}
var _sched := {}
var _proc_split: ProcSplit = null
var _proc_slices: ProcSlices = null
var _lazy_models := false
var _census: Node = null


func _configure() -> void:
	client_scene = "res://game/fc.tscn"
	map = "cp-orange-x3"
	mode = "ctf"
	preload("../game/fc_weapon_roles.gd").ensure()
	var _scratch := FcPresentation.use_scratch_settings("perf_bench")


## `--world-shadow`, `--world-shadow-cell`, `--central-tick`: FcRenderCvars' values, pushed before the map is drawn.
func _render_cvar_flags() -> void:
	var rc := preload("../game/fc_render_cvars.gd")
	rc.world_shadow = int(args.get("world-shadow", 1 if rc.world_shadow else 0)) != 0
	rc.world_shadow_cell = float(args.get("world-shadow-cell", rc.world_shadow_cell))
	rc.held_central_tick = int(args.get("central-tick", 1 if rc.held_central_tick else 0)) != 0
	rc.apply()
	say("world shadow %s cell %.0f, held central tick %s" % [rc.world_shadow, rc.world_shadow_cell, rc.held_central_tick])


func _ready() -> void:
	super()
	_pilot = int(args.get("pilot", 1)) != 0
	_motor_us = int(args.get("motor-us", 0)) != 0
	_queries = int(args.get("queries", 0)) != 0
	_ctl_us = int(args.get("ctl-us", 0)) != 0
	_brain_us = int(args.get("brain-us", 0)) != 0
	_weapon_us = int(args.get("weapon-us", 0)) != 0
	_native_us = int(args.get("native-us", 0)) != 0 and ClassDB.class_exists(&"GSSimFpsBody")
	_max_steps = int(args.get("max-steps", -1))
	_fine = int(args.get("fine", 1)) != 0
	_lazy_models = int(args.get("lazy-models", 0)) != 0
	if _lazy_models:
		preload("../game/fc_client_prewarm.gd").defer_models_everywhere = true
	FcFrameProbe.fine_on_record = _fine
	_tick = int(args.get("tick", 0))
	if _max_steps > 0:
		preload("../game/fc_tick_budget.gd").max_steps = _max_steps
	var wh := String(args.get("res", "")).split("x")
	if wh.size() == 2 and DisplayServer.get_name() != "headless":
		get_window().size = Vector2i(int(wh[0]), int(wh[1]))
	if int(args.get("web-defaults", 0)) != 0:
		# The browser build's defaults (GSPlatform.is_web()), before the flags below may override one.
		var ap := preload("../game/fc_player.gd")
		ap.lod_off_every = ap.WEB_LOD_OFF_EVERY
		say("web defaults: lod_off_every %d" % ap.lod_off_every)
	if args.has("killcam-hz"):
		preload("../game/fc_killcam_bodies.gd").record_hz = float(args["killcam-hz"])
	if args.has("killcam-crowd"):
		preload("../game/fc_killcam_bodies.gd").crowd_players = int(args["killcam-crowd"])
	if args.has("lod-crowd"):
		preload("../game/fc_player.gd").lod_crowd_players = int(args["lod-crowd"])
	if args.has("figure-lift-range"):
		# By name as well: the console hands the figure FcPlayer's value; a gs-player-char older than 27 has no lift_range.
		preload("../game/fc_player.gd").figure_lift_range = float(args["figure-lift-range"])
		(GSHumanoidFigure as Script).set(&"lift_range", float(args["figure-lift-range"]))
	if args.has("lod-scale"):
		preload("../game/fc_player.gd").lod_scale = float(args["lod-scale"])
	if args.has("sight-far"):
		preload("../game/fc_bots.gd").sight_far = float(args["sight-far"])
	if args.has("sight-far-reuse"):
		preload("../game/fc_bots.gd").sight_far_reuse = float(args["sight-far-reuse"])
	if args.has("tier-idle-seen"):
		preload("../game/fc_bots.gd").tiers.idle_view_every = int(args["tier-idle-seen"])
	if args.has("tier-body-near"):
		preload("../game/fc_bots.gd").tiers.body_near_every = int(args["tier-body-near"])
	if args.has("tier-body-far"):
		preload("../game/fc_bots.gd").tiers.body_far_every = int(args["tier-body-far"])
	if int(args.get("batch", 1)) == 0:
		FcHullGrid.batch = false
	FcHullGrid.min_players = int(args.get("hull-min", FcHullGrid.MIN_PLAYERS))
	if int(args.get("lod", 1)) == 0:
		preload("../game/fc_player.gd").present_lod_enabled = false
	if int(args.get("occl", 1)) == 0:
		preload("../game/fc_player.gd").occlusion_enabled = false
	if int(args.get("anim-gate", 1)) == 0:
		preload("../game/fc_player.gd").anim_gate_enabled = false
	if int(args.get("present-native", 1)) == 0:
		preload("../game/fc_player.gd").present_schedule_native = false
	_render_cvar_flags()
	if int(args.get("carry", 1)) == 0:
		# By name: a no-op against an fc-weapons older than the switch.
		(AwWorldModel as Script).set(&"person_carry", false)
	if args.has("brain-native"):
		FcPlayerStack.set_brain_native(int(args["brain-native"]) != 0)
	say("brain: %s" % ("native" if FcPlayerStack.brain_native() else "script"))
	if args.has("weapon-native"):
		AwWeaponRig.native_spread = int(args["weapon-native"]) != 0
	say("weapon spread: %s" % ("native" if AwWeaponRig.native_spread_active() else "script"))
	if args.has("ragdoll-native"):
		# By name: the bench also runs against a gs-player-char older than the switch.
		(GSPlayerRagdoll as Script).set(&"native_pose", int(args["ragdoll-native"]) != 0)
	if int(args.get("target-first", 1)) == 0:
		# By name: the bench also runs against a gs-bot older than the switch.
		(GSBotBrain as Script).set(&"target_first", false)
	_ablate = String(args.get("ablate", "")).split(",", false)
	preload("../game/fc_player.gd").present_ablate = int(args.get("present-ablate", 0))
	preload("../game/fc_client_prewarm.gd").prewarm_weapons_enabled = int(args.get("prewarm", 1)) != 0


func _setup_client(c: Node) -> void:
	super(c)
	c.set("mouse_capture_override", true)
	_sim_host = int(args.get("sim-host", 0)) != 0
	if _sim_host:
		FcSimHost.forced = 1
		# `--boot-map ID`: the server boots there, and the bench changes to the map from the menu (a timed map change).
		FcSimHost.ask_map = String(args.get("boot-map", map))
		FcSimHost.ask_mode = mode


func _select(game: Object) -> void:
	if _sim_host:
		await _select_hosted()
		return
	if _tick > 0:
		game.config.tick_rate = _tick
		game.tick_rate = _tick
		Engine.physics_ticks_per_second = _tick
	if not _lazy_models:
		var _warmed := AwModelCache.warm(AwWeaponArtTable.model_paths())
	var picked: GSResult = null
	if String(game.get("map").id) != map:
		picked = await client.call("change_from_menu", StringName("map:" + map), StringName("mode:" + mode))
	elif String(game.get("mode").id) != mode:
		picked = await client.call("change_from_menu", StringName("mode:" + mode))
	if picked != null:
		say("map %s mode %s: %s" % [map, mode, "ok" if picked.ok else picked.error.message])
		await wait_gate(120.0)


## The server booted on the map and mode already: wait for the client to exist, load and see the roster.
func _select_hosted() -> void:
	var t := 0.0
	while client.get("gate") == null and t < 120.0:
		await wait(0.25)
		t += 0.25
	await wait_gate(120.0)
	if not _lazy_models:
		var _warmed := AwModelCache.warm(AwWeaponArtTable.model_paths())
	# Booted elsewhere (`--boot-map`, or a map the server could not mount): change to the map from the menu as a
	# player would; the client's timeline reports the change ("map change map:ID to playable").
	if String(client.get("game").get("map").id) != map:
		var picked: GSResult = await client.call("change_from_menu", StringName("map:" + map), StringName("mode:" + mode))
		say("sim host: map change to %s mode %s: %s" % [map, mode, "ok" if picked.ok else picked.error.message])
		await wait_gate(120.0)
	t = 0.0
	while _players(client.get("game")) < bots + 1 and t < 30.0:
		await wait(0.25)
		t += 0.25
	say("sim host: hosted %s, map %s, players %d" % [client.get("_sim_host") != null, String(client.get("game").get("map").id), _players(client.get("game"))])


## Each weapon id: equip it (the draw), fire it cold, then again warm, the player invulnerable. Rows "equip ID", "shot ID", "shot2 ID".
func _first_use(_game: Object) -> void:
	if _sim_host:
		say("first use: offline only, not with --sim-host")
		return
	var ids: Array[StringName] = []
	for id: StringName in AwWeaponCatalogue.table():
		ids.append(id)
	if args.has("first-use-only"):
		ids.clear()
		for s in String(args["first-use-only"]).split(",", false):
			ids.append(StringName(s))
	var at_gate := GSCloudSliceLoader.cached_scripts("res://", GSCloudClient.WARM_SKIP_DIRS).size()
	await _first_control("control 1")
	await _first_blood()
	await _first_decal()
	await _first_impact()
	await _first_hit()
	await _first_control("control 2")
	await _first_footsteps()
	await _first_kill()
	await _first_npcs()
	var reloads := int(args.get("first-use-reload", 1)) != 0
	var thrown_frames := int(args.get("first-use-thrown-frames", 240))
	for id in ids:
		var def: GSWeaponDef = AwWeaponCatalogue.table().get(id)
		var me: Variant = client.get("player")
		if def == null or me == null:
			say("first use: skip %s (%s)" % [id, "no def" if def == null else "no player"])
			continue
		me.health.invulnerable = true
		var _given: Variant = me.arsenal.give(id)
		var _eq := await time_first_use("equip %s" % id, func() -> void: me.arsenal.equip(def.slot), Callable(), 0, 45)
		var t := 0.0
		while t < 3.0 and not (me.arsenal.current() != null and me.arsenal.current().id() == id):
			await wait(0.1)
			t += 0.1
		if me.arsenal.current() == null or me.arsenal.current().id() != id:
			say("first use: %s did not equip" % id)
			continue
		await wait(0.8)
		# A thrown weapon's window runs on to the blast (the fuse), so "shot frag" is the first grenade, throw and detonation.
		var thrown := def.tags.has(&"thrown")
		for row in ["shot", "shot2"]:
			# Held ten frames, so a physics tick sees it at any frame rate; the window runs on to the impact and the shell.
			var _shot := await time_first_use("%s %s" % [row, id], func() -> void: Input.action_press(&"arena_fire"),
				func() -> void: Input.action_release(&"arena_fire"), 10, thrown_frames if thrown else 45)
			await wait(1.0)
		# Two rounds gone, so the magazine has room: the first reload (its sequence, parts and sounds). `--first-use-reload 0` skips it.
		if reloads and not thrown and def.magazine > 0:
			var _reload := await time_first_use("reload %s" % id, func() -> void: Input.action_press(&"arena_reload"),
				func() -> void: Input.action_release(&"arena_reload"), 10, 90)
			await wait(float(def.reload_ticks) / float(maxi(def.authored_tick_rate, 66)) + 0.5)
	await _first_death()
	if int(args.get("warm-list", 0)) != 0:
		var scripts := GSCloudSliceLoader.cached_scripts("res://", GSCloudClient.WARM_SKIP_DIRS)
		# Only what the cover warms anyway: the pack's own scripts and the addon classes. A listed script the cover's scan does not
		# find (an addon script reached only through a preload) blocks it as well, and that only moves its compile from the gate
		# to the cover: with them, warm.txt held the warm web cover 4 s longer (staging02).
		var classes := {}
		for entry: Dictionary in ProjectSettings.get_global_class_list():
			classes[str(entry["path"]).trim_prefix("res://")] = true
		var kept := 0
		for path in scripts:
			if not path.begins_with("addons/") or classes.has(path):
				print("WARM_LIST " + path)
				kept += 1
		say("warm list: %d scripts loaded at the gate, %d after the first uses, %d listed" % [at_gate, scripts.size(), kept])


## A point [param metres] in front of the player's camera and a transform there facing back at it: where a decal or an impact is drawn.
func _in_front(metres: float) -> Transform3D:
	var me: Variant = client.get("player")
	var cam: Transform3D = me.camera.global_transform
	return Transform3D(cam.basis, cam.origin - cam.basis.z * metres)


## Rows "control N": the window of a first use with nothing done in it, so the worst frame of a bot-fight spike (a killcam moment, a bot's shot) is not read as the first use's cost.
func _first_control(what: String) -> void:
	var _row := await time_first_use(what, func() -> void: pass, Callable(), 0, 30)
	await wait(0.3)


## Row "blood": the first blood splatter (its decal pool, material and texture) at a point in sight, without the ray or the hit handler.
func _first_blood() -> void:
	var me: Variant = client.get("player")
	var pres: Variant = client.get("presentation")
	if me == null or pres == null or me.camera == null or pres.blood == null:
		return
	var at := _in_front(3.0)
	var _row := await time_first_use("blood", func() -> void: pres.blood.decals.splatter(at.origin, at.basis.z), Callable(), 0, 30)
	await wait(0.3)


## Row "decal": the first bullet hole (the decal sheet's first draw), alone.
func _first_decal() -> void:
	var me: Variant = client.get("player")
	var pres: Variant = client.get("presentation")
	if me == null or pres == null or me.camera == null or pres.fx == null:
		return
	var at := _in_front(4.0)
	var _row := await time_first_use("decal", func() -> void: var _hole: Variant = pres.fx.spawn_decal(&"bullet_hole", at), Callable(), 0, 30)
	await wait(0.3)


## Row "impact": the first impact through the presentation's own handler (hole, impact sound, spark), after the decal row, so it prices the sound and the spark.
func _first_impact() -> void:
	var me: Variant = client.get("player")
	var pres: Variant = client.get("presentation")
	if me == null or pres == null or me.camera == null:
		return
	var at := _in_front(5.0)
	var _row := await time_first_use("impact", func() -> void: pres.on_impact(at, false, &"rifle"), Callable(), 0, 30)
	await wait(0.3)


## Row "hit": the server's HIT event for a body in front of the player, before any shot, through the client's own handler
## (hit marker, damage number, blood decal, body impact), as an in-process host runs it inside the first resolved shot.
func _first_hit() -> void:
	var me: Variant = client.get("player")
	var game: Variant = client.get("game")
	if me == null or game == null or me.camera == null:
		return
	var victim := 0
	for p: Variant in game.players():
		if p != me:
			victim = int(p.player_id)
			break
	var cam: Transform3D = me.camera.global_transform
	var point := cam.origin - cam.basis.z * 3.0
	var _row := await time_first_use("hit", func() -> void:
		client.call(&"_on_hit", {"point": point, "victim_id": victim, "amount": 25.0, "headshot": false, "lethal": false}), Callable(), 0, 30)


## Rows "footstep SURFACE": the first step sound of each surface through the client's audio manager (stream load and decode).
func _first_footsteps() -> void:
	var me: Variant = client.get("player")
	var heard: Variant = client.get("presentation").audio if client.get("presentation") != null else null
	if me == null or heard == null:
		return
	for surface: StringName in GSAudioStock.SURFACES:
		var id := GSAudioStock.footstep_id(surface)
		var _row := await time_first_use("footstep %s" % surface, func() -> void: heard.play_at(id, me.global_position), Callable(), 0, 20)
		await wait(0.3)


## The bot nearest to the player (another seat), or null.
func _other_player(me: Variant, game: Variant) -> Variant:
	for p: Variant in game.players():
		if p != me:
			return p
	return null


## Lethal damage from [param attacker] to [param victim] through the game's own combat (feed, award, ragdoll, drop), protection off.
func _kill(game: Variant, attacker: int, victim: int) -> void:
	var health: GSHealth = game.combat.health_of(victim)
	if health == null:
		return
	health.invulnerable = false
	health.invulnerable_until_tick = -1
	var type: GSDamageType = game.combat.damage_type(&"bullet")
	var hit := GSDamage.make(attacker, victim, health.health + health.armour + 50.0, type)
	hit.tick = game.current_tick()
	hit.weapon_id = &"rifle"
	game.combat.apply_damage(hit)


## Row "kill": a bot put a few metres in front of the player and killed by them (kill feed, award, ragdoll, weapon drop).
func _first_kill() -> void:
	var me: Variant = client.get("player")
	var game: Variant = client.get("game")
	if me == null or game == null or me.camera == null:
		return
	var victim: Variant = _other_player(me, game)
	if victim == null:
		say("first use: kill skipped (no bot)")
		return
	var cam: Transform3D = me.camera.global_transform
	victim.global_position = me.global_position - Vector3(cam.basis.z.x, 0.0, cam.basis.z.z).normalized() * 4.0
	await wait(0.3)
	var _row := await time_first_use("kill", func() -> void: _kill(game, int(me.player_id), int(victim.player_id)), Callable(), 0, 90)
	await wait(1.0)


## Rows "death" (the player killed by a bot: death view, killview, respawn screen) and "respawn". Last: the player is down after it.
func _first_death() -> void:
	var me: Variant = client.get("player")
	var game: Variant = client.get("game")
	if me == null or game == null:
		return
	var killer: Variant = _other_player(me, game)
	me.health.invulnerable = false
	var _row := await time_first_use("death", func() -> void: _kill(game, int(killer.player_id) if killer != null else 0, int(me.player_id)), Callable(), 0, 120)


## Rows "npc ID" (a monster of each kind placed in sight) and "npc kill ID" (it killed by the player). Needs a mode with a horde
## (`--mode siege`); other modes have no monsters and say so.
func _first_npcs() -> void:
	var me: Variant = client.get("player")
	var game: Variant = client.get("game")
	var horde: Variant = game.get("horde") if game != null else null
	if me == null or horde == null or horde.nav == null or me.camera == null:
		say("first use: npc rows skipped (no horde in mode %s)" % mode)
		return
	var cam: Transform3D = me.camera.global_transform
	var want := cam.origin - cam.basis.z * 8.0
	var at: Vector3 = horde.nav.points[0]
	for point: Vector3 in horde.nav.points:
		if point.distance_squared_to(want) < at.distance_squared_to(want):
			at = point
	for def: GSNpcDef in FcNpcs.catalogue().in_faction(FcNpcs.FACTION):
		var held: Array = []
		var _spawned := await time_first_use("npc %s" % def.id, func() -> void: _place_npc(horde, def.id, at, held), Callable(), 0, 45)
		await wait(0.5)
		var npc: GSNpcInstance = held[0] if not held.is_empty() else null
		if npc == null:
			say("first use: npc %s did not spawn" % def.id)
			continue
		var _killed := await time_first_use("npc kill %s" % def.id, func() -> void: _kill(game, int(me.player_id), horde.entity_id_for(npc)), Callable(), 0, 90)
		await wait(1.0)


## The siege director keeps the world at its NPC budget, which refuses a hand-placed monster: clear the world and place at once.
func _place_npc(horde: Variant, id: StringName, at: Vector3, held: Array) -> void:
	var _cleared: int = horde.clear()
	held.append(horde.spawn_one(id, at))


func _start_pilot(_game: Object) -> void:
	if _pilot:
		var pilot := ClientBench.Pilot.new()
		var view := String(args.get("pilot-view", ""))
		pilot.sweep = view == "sweep" or view == "tour"
		if view == "tour":
			pilot.tour = _tour_points()
		pilot.client = client
		pilot.process_priority = -999
		add_child(pilot)
		if view == "fixed":
			var fixed := ClientBench.FixedView.new()
			fixed.client = client
			fixed.stops = _tour_points()
			fixed.cycle = maxf(1.0, float(args.get("seconds", 60)))
			fixed.process_priority = 1 << 30
			add_child(fixed)
		if args.has("hold"):
			_hold_weapon(StringName(String(args["hold"])))


## The map's spawn points, ordered by a stride that is coprime with their count so successive stops are far apart: a walk through every district.
func _tour_points() -> Array[Vector3]:
	var out: Array[Vector3] = []
	var spawns: Array = client.get("game").get("map").spawns
	var n := spawns.size()
	var stride := maxi(1, n / 3)
	while n > 1 and absi(_gcd(stride, n)) != 1:
		stride += 1
	for i in range(n):
		out.append((spawns[(i * stride) % n] as Transform3D).origin)
	say("tour: %d stops" % out.size())
	return out


static func _gcd(a: int, b: int) -> int:
	return a if b == 0 else _gcd(b, a % b)


## `--hold ID`: the pilot carries weapon ID (a scoped rifle shows the scope glass's second scene render while aiming in). `--aim 1` aims it.
func _hold_weapon(id: StringName) -> void:
	await wait(3.0)
	var def: GSWeaponDef = AwWeaponCatalogue.table().get(id)
	var me: Variant = client.get("player")
	if def == null or me == null:
		say("hold: skip %s" % id)
		return
	me.health.invulnerable = true
	var _given: Variant = me.arsenal.give(id)
	me.arsenal.equip(def.slot)
	say("hold %s" % id)
	# `--aim 1`: and holds the Aim key from here on (aims down the sights, so a scoped rifle shows its scope view).
	if int(args.get("aim", 0)) != 0 and InputMap.has_action(&"arena_aim"):
		await wait(1.0)
		client.set("mouse_capture_override", true)
		Input.action_press(&"arena_aim")
		say("aim held")


func _add_counters(game: Object) -> void:
	# Unit counts for profiler_groups (e.g. bots:arena.bot,players:arena.p_); read only when that lists them.
	if profiler.has_method(&"add_counter"):
		profiler.call(&"add_counter", "players", func() -> int: return (game.call("players") as Array).size(), "arena.p_")
		profiler.call(&"add_counter", "bots", func() -> int: return maxi((game.call("players") as Array).size() - 1, 0), "arena.bot")


## Per thread of this process and of the sim host: run time, run-queue wait, slices and context switches (Linux /proc).
func _sched_snapshot() -> Dictionary:
	var out := {}
	if OS.get_name() != "Linux":
		return out
	var pids := {"client": OS.get_process_id()}
	var host: Variant = client.get("_sim_host") if client != null else null
	if host != null and int(host.get("_pid")) > 0:
		pids["server"] = int(host.get("_pid"))
	for who: String in pids:
		var base := "/proc/%d/task" % pids[who]
		var threads := {}
		for tid: String in DirAccess.get_directories_at(base):
			var st := _proc_read(base + "/" + tid + "/schedstat").split(" ", false)
			if st.size() < 3:
				continue
			var cs := {"voluntary_ctxt_switches": 0, "nonvoluntary_ctxt_switches": 0}
			for l in _proc_read(base + "/" + tid + "/status").split("\n", false):
				var kv := l.split(":", false, 1)
				if kv.size() == 2 and cs.has(kv[0]):
					cs[kv[0]] = int(kv[1].strip_edges())
			threads[tid] = {"run": int(st[0]), "wait": int(st[1]), "slices": int(st[2]), "vcs": cs.voluntary_ctxt_switches, "nvcs": cs.nonvoluntary_ctxt_switches,
				"comm": _proc_read(base + "/" + tid + "/comm").strip_edges(), "main": int(tid) == pids[who]}
		out[who] = threads
	return out


## /proc files report size 0, so read them line by line rather than by length.
func _proc_read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var s := ""
	while not f.eof_reached():
		s += f.get_line() + "\n"
	return s


## Wall time split per thread over the recording, ms per frame: running and waiting for a CPU (the rest is sleeping or blocked); context switches per frame.
func _sched_report(a: Dictionary, b: Dictionary) -> Dictionary:
	var n := maxf(frames_recorded(), 1.0)
	var res := {}
	for who: String in b:
		var rows := []
		for tid: String in b[who]:
			var t1: Dictionary = b[who][tid]
			var t0: Dictionary = (a.get(who, {}) as Dictionary).get(tid, {"run": 0, "wait": 0, "slices": 0, "vcs": 0, "nvcs": 0})
			var run: float = (int(t1.run) - int(t0.run)) / 1e6 / n
			if run < 0.05 and not t1.main:
				continue
			rows.append({"tid": tid, "comm": t1.comm, "main": t1.main, "run_ms": snappedf(run, 0.01),
				"rq_wait_ms": snappedf((t1.wait - t0.wait) / 1e6 / n, 0.01), "vcs": snappedf((t1.vcs - t0.vcs) / n, 0.01), "nvcs": snappedf((t1.nvcs - t0.nvcs) / n, 0.01)})
		rows.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return float(x.run_ms) > float(y.run_ms))
		res[who] = rows
	return res


func _record_begin() -> void:
	_sched0 = _sched_snapshot()
	FcFrameProbe.fine = _fine
	_apply_ablate()
	if args.has("script-top") and profiler != null:
		profiler.config.script_top = int(args["script-top"])
	if int(args.get("proc-split", 0)) != 0:
		say("proc census %s" % JSON.stringify(ProcSplit.census(get_tree().root)))
		# One remote player's own subtree (the first without a camera): the per-player share of the node count.
		for p: Object in client.get("game").call("players"):
			if p.get("camera") == null and p is Node:
				say("proc census remote player %s" % JSON.stringify(ProcSplit.census(p as Node)))
				say("proc census remote player tree %s" % JSON.stringify(_subtree_sizes(p as Node, 9)))
				break
		say("proc census root tree %s" % JSON.stringify(_subtree_sizes(get_tree().root, 6, 30)))
		_proc_split = ProcSplit.new()
		add_child(_proc_split)
		if args.has("proc-ablate"):
			_proc_slices = ProcSlices.new()
			_proc_slices.split = _proc_split
			_proc_slices.levers = String(args["proc-ablate"]).split(",", false)
			_proc_slices.slice = int(args.get("proc-slice", 40))
			add_child(_proc_slices)
	if float(args.get("census-every", 0)) > 0.0:
		_census = DrawCensus.new()
		_census.every = float(args["census-every"])
		_census.top = int(args.get("census-top", 12))
		_census.say = say
		add_child(_census)
	GSFpsPhysicsBody.profile = _queries
	GSFpsPhysicsBody.prof.fill(0)
	# --ctl-us 1: the controller's phases alone, on whichever motor path runs (--motor-us forces the script one).
	GSFpsController.phase_timers = _ctl_us
	GSBotBrain.phase_timers = _brain_us
	if _brain_us:
		GSBotBrain.phase_us.fill(0)
	AwWeaponRig.phase_timers = _weapon_us
	GSWeaponArsenal.phase_timers = _weapon_us
	AwWeaponRig.phase_us.fill(0)
	AwWeaponRig.phase_calls.fill(0)
	GSWeaponArsenal.phase_us.fill(0)
	GSWeaponArsenal.phase_calls.fill(0)
	if _ctl_us:
		GSFpsController.phase_us.fill(0)
	if _motor_us:
		GSFpsMotor.profile = true
		GSFpsController.phase_us.fill(0)
		GSFpsMotor.phase_us.fill(0)
	if _native_us:
		ClassDB.class_call_static(&"GSSimFpsBody", &"reset_profile")
		ClassDB.class_call_static(&"GSSimFpsBody", &"set_profile", true)


func _record_end() -> void:
	_sched = _sched_report(_sched0, _sched_snapshot())
	if _census != null:
		_census.queue_free()
		_census = null
	if _proc_slices != null:
		say("proc slices ms/frame %s" % JSON.stringify(_proc_slices.report()))
		_proc_slices.queue_free()
		_proc_slices = null
	if _proc_split != null:
		say("proc split ms/frame %s" % JSON.stringify(_proc_split.report()))
		_proc_split.queue_free()
		_proc_split = null
	for who: String in _sched:
		for r: Dictionary in _sched[who]:
			say("sched %s %s%s run %.2f rq %.2f vcs %.2f nvcs %.2f ms|n/frame" % [who, r.comm, " (main)" if r.main else "", r.run_ms, r.rq_wait_ms, r.vcs, r.nvcs])
	FcFrameProbe.fine = false
	GSFpsPhysicsBody.profile = false
	GSFpsMotor.profile = false
	GSFpsController.phase_timers = false
	GSBotBrain.phase_timers = false
	AwWeaponRig.phase_timers = false
	GSWeaponArsenal.phase_timers = false
	if _native_us:
		ClassDB.class_call_static(&"GSSimFpsBody", &"set_profile", false)


func _sidecar_extra(_game: Object) -> Dictionary:
	var n := frames_recorded()
	var pr := GSFpsPhysicsBody.prof
	var queries := {}
	var names := ["cast", "rest", "overlap", "ray"]
	for i in names.size():
		queries[names[i]] = {"per_frame": snappedf(pr[i * 2] / n, 0.01), "ms_per_frame": snappedf(pr[i * 2 + 1] / 1000.0 / n, 0.001),
			"us_each": snappedf(float(pr[i * 2 + 1]) / maxf(pr[i * 2], 1.0), 0.01)}
	var phases := {}
	if _motor_us or _ctl_us:
		# Totals over the recording in ms per frame; per player tick is these over arena.p_controller calls.
		var ctl := ["pre", "consume", "motor", "publish", "report", "signals_stats", "post", "set_position"]
		for i in ctl.size():
			phases["ctl." + ctl[i]] = snappedf(GSFpsController.phase_us[i] / 1000.0 / n, 0.001)
	if _brain_us:
		for i in GSBotBrain.PHASES.size():
			phases["brain." + GSBotBrain.PHASES[i]] = snappedf(GSBotBrain.phase_us[i] / 1000.0 / n, 0.001)
	if _motor_us:
		for i in GSFpsMotor.PHASES.size():
			if GSFpsMotor.PHASES[i] != "":
				phases["motor." + GSFpsMotor.PHASES[i]] = snappedf(GSFpsMotor.phase_us[i] / 1000.0 / n, 0.001)
	var weapon := {}
	if _weapon_us:
		# Per rig call (idle and full together); the arsenal's per call of its own, its counts beside.
		var rc := AwWeaponRig.phase_calls
		weapon["rig_calls"] = {"idle": rc[0], "full": rc[1]}
		for i in AwWeaponRig.PHASES.size():
			weapon["pw." + AwWeaponRig.PHASES[i]] = snappedf(float(AwWeaponRig.phase_us[i]) / maxf(rc[0] + rc[1], 1.0), 0.01)
		var ac := GSWeaponArsenal.phase_calls
		weapon["arsenal_calls"] = {"full": ac[0], "idle": ac[1], "idle_rested": ac[2]}
		for i in GSWeaponArsenal.PHASES.size():
			weapon["pa." + GSWeaponArsenal.PHASES[i]] = snappedf(float(GSWeaponArsenal.phase_us[i]) / maxf(ac[0] + ac[1], 1.0), 0.01)
	var native := {}
	if _native_us:
		# Count then microseconds per slot: the four engine queries, then whole native ticks; the tick less the queries is gs-sim's own work.
		var c: PackedInt64Array = ClassDB.class_call_static(&"GSSimFpsBody", &"profile_counters")
		var slots := ["cast", "rest", "overlap", "ray", "tick"]
		for i in mini(slots.size(), c.size() / 2):
			native[slots[i]] = {"per_frame": snappedf(float(c[i * 2]) / n, 0.01), "ms_per_frame": snappedf(c[i * 2 + 1] / 1000.0 / n, 0.001),
				"us_each": snappedf(float(c[i * 2 + 1]) / maxf(c[i * 2], 1.0), 0.01)}
	# Which movers gathered their hulls natively (gs-sim's hull world) and which by script: native 0 with a world
	# false means the loaded libgs_sim predates GSSimHullWorld (rebuild it, ci/install.sh).
	var hulls := {}
	if _game != null:
		hulls["world"] = _game.get(&"_hull_world") != null
		hulls["remote_feet"] = (_game.get(&"remote_feet_fn") as Callable).is_valid()
		hulls["remote_lags"] = (_game.get(&"remote_lags_fn") as Callable).is_valid()
		var native_n := 0
		var roster: Variant = _game.get(&"_roster")
		if roster is Array:
			for p: Variant in roster:
				if p is Object and bool((p as Object).get(&"_hull_body_ok")):
					native_n += 1
			hulls["roster"] = (roster as Array).size()
		hulls["native"] = native_n
		hulls["batch"] = FcHullGrid.batch
		hulls["batch_rows"] = FcHullGrid.batch_rows
		hulls["batch_faults"] = FcHullGrid.batch_faults
	return {"phases_ms_per_frame": phases, "weapon_us_per_call": weapon, "native": native, "hulls": hulls, "sim_host": _sim_host and client.get("_sim_host") != null, "sched": _sched, "net": FcNetContext.describe(client.get("bridge")), "pilot": _pilot, "pilot_view": String(args.get("pilot-view", "")) if _pilot else "", "brain_native": FcPlayerStack.brain_native(), "ragdoll_native": (GSPlayerRagdoll as Script).get(&"native_pose") == true and ClassDB.class_exists(&"GSSimRagdollPose"), "queries": _queries, "max_steps": _max_steps, "fine": _fine, "motor_queries": queries, "body_skipped": preload("../game/fc_player.gd").body_skipped, "tiers": preload("../game/fc_bots.gd").tiers.describe()}


## Casters by size: the census (`shadowcensus`) and the cuts `smallcast` (longest side < 0.6 m) and `smallcast2` (< 1.5 m).
func _shadow_cap(mode: String) -> void:
	var limit := 0.6 if mode == "smallcast" else 1.5
	var buckets := {"<0.3": 0, "<0.6": 0, "<1.5": 0, "<4": 0, "big": 0}
	var cut := 0
	var whos := {}
	for n in get_tree().root.find_children("*", "MeshInstance3D", true, false):
		var m := n as MeshInstance3D
		if m.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_ON or not m.is_visible_in_tree() or m.mesh == null:
			continue
		var box := m.mesh.get_aabb().size
		var b := m.global_transform.basis
		var size := maxf(box.x * b.x.length(), maxf(box.y * b.y.length(), box.z * b.z.length()))
		var k := "<0.3" if size < 0.3 else "<0.6" if size < 0.6 else "<1.5" if size < 1.5 else "<4" if size < 4.0 else "big"
		buckets[k] += 1
		if mode == "shadowcensus" and size < 1.5:
			var a := m.get_parent()
			var who := ""
			while a != null and who.length() < 90 and a != get_tree().root:
				who = String(a.get_class()) + ":" + String(a.name).left(14) + "/" + who
				a = a.get_parent()
			who = who.right(70)
			whos[who] = int(whos.get(who, 0)) + 1
		if mode != "shadowcensus" and size < limit:
			m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			cut += 1
	for w in whos:
		say("census %d %s" % [whos[w], w])
	say("%s: casters by longest side %s, cut %d" % [mode, buckets, cut])


func _apply_ablate() -> void:
	for a in _ablate:
		match a:
			"noshadow":
				for l in get_tree().root.find_children("*", "Light3D", true, false):
					(l as Light3D).shadow_enabled = false
			"shadowcensus", "smallcast", "smallcast2":
				_shadow_cap(a)
			"rstate":
				for line in RenderState.lines(get_tree().root):
					say("rstate " + line)
			"nofx":
				var envs: Array[Environment] = []
				for we in get_tree().root.find_children("*", "WorldEnvironment", true, false):
					envs.append((we as WorldEnvironment).environment)
				for cam in get_tree().root.find_children("*", "Camera3D", true, false):
					if (cam as Camera3D).environment != null:
						envs.append((cam as Camera3D).environment)
				for e in envs:
					if e != null:
						e.ssao_enabled = false
						e.ssil_enabled = false
						e.glow_enabled = false
						e.fog_enabled = false
						e.volumetric_fog_enabled = false
				say("nofx: %d environments" % envs.size())
			"nohud":
				var hud: Variant = client.get("hud")
				# Not `hud.visible = false`: the client's _restore_hud_if_orphaned shows a hidden HUD again at once, so the
				# ablation never held. The HUD stays visible; what it draws (its children) is hidden.
				if hud != null:
					var hidden := 0
					for c in (hud as Node).get_children():
						if c.get("visible") != null:
							c.set("visible", false)
							hidden += 1
					say("nohud: %d HUD children hidden" % hidden)
			"skelmanual":
				var n_sk := 0
				for sk in get_tree().root.find_children("*", "Skeleton3D", true, false):
					(sk as Skeleton3D).modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
					n_sk += 1
				say("skelmanual: %d skeletons set to manual" % n_sk)
			"nobots":
				for p: Object in client.get("game").call("players"):
					if p.get("camera") == null:
						p.visible = false
			# Splits the engine's render phase: no3d keeps the canvas and the present (swapchain, the Xvfb copy) but draws no
			# 3D scene; norender skips RenderingServer.draw altogether, leaving physics and scripts.
			"no3d":
				get_viewport().disable_3d = true
			"norender":
				RenderingServer.render_loop_enabled = false
	if not _ablate.is_empty():
		say("ablate %s" % ",".join(_ablate))


## Node counts under each child of [param node], [param depth] levels down, larger than [param least]: where a census's
## nodes live.
static func _subtree_sizes(node: Node, depth: int, least: int = 0) -> Dictionary:
	var out := {}
	for c: Node in node.get_children(true):
		var n := _count_nodes(c)
		if n <= least:
			continue
		var key := "%s(%s)=%d" % [c.name, c.get_class(), n]
		out[key] = _subtree_sizes(c, depth - 1, least) if depth > 1 and c.get_child_count(true) > 0 else n
	return out


static func _count_nodes(node: Node) -> int:
	var n := 1
	for c: Node in node.get_children(true):
		n += _count_nodes(c)
	return n
