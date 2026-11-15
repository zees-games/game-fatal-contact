extends Node

const ArenaConfig := preload("arena_config.gd")
const ArenaGame := preload("arena_game.gd")
const ArenaMap := preload("../maps/arena_map.gd")
const ArenaModule := preload("arena_module.gd")
const ArenaSimOwner := preload("arena_sim_owner.gd")
const ArenaBots := preload("arena_bots.gd")
const ArenaBotThreads := preload("arena_bot_threads.gd")
const ArenaTickBudget := preload("arena_tick_budget.gd")
const ArenaPlayerStack := preload("arena_player_stack.gd")
const ArenaMaps := preload("arena_maps.gd")
const ArenaPaths := preload("arena_paths.gd")

## The authoritative game of a solo session in its own process (`--sim_host 1`, [ArenaSimHost]): a loopback dedicated server the solo client spawns and joins, so the 66 Hz simulation never runs on the render thread. The same [ArenaModule] a public server runs.
## Launch flags (after `--`): `--port N --bots N --map ID --mode ID --ready PATH --bot_threads N --sim_load_us N --sim_sections 1 --bot_native_brain 0|1 --bot_native_loop 0|1 --cvar name=value`. It writes PATH once it accepts players, and quits a few seconds after its player left.

const ArenaFrameProbe := preload("arena_frame_probe.gd")

const CHANNEL := "arena.sim_server"
const REPORT_SEC := 5.0
const GONE_SEC := 5.0
const NEVER_SEC := 120.0
## Most brain threads this process takes by default; the client renders on the same machine.
const BOT_THREADS_MAX := 4

var _server: DotServer = null
var _joined := false
var _alone_sec := 0.0
var _since_check := 0.0
## `--sim_load_us N`, a bench knob: N microseconds of busy wait on every physics tick, to stand in for a
## slower machine's tick (the owner's 12-14 ms) on a fast bench box. 0, the default, adds nothing.
var _load_us := 0
var _game: ArenaGame = null
var _module: ArenaModule = null
## When the in-game behind line was last said (msec), or -1 while the server keeps its rate.
var _behind_said_ms := -1


func _ready() -> void:
	# A sim host serves one solo client, so it offers the maps copied onto this machine as that client does.
	ArenaMaps.list_local = true
	var port := int(_arg("--port", "0"))
	var bots := int(_arg("--bots", "0"))
	if port <= 0:
		_die("no --port")
		return
	_apply_bench_flags()
	var data := "user://sim_host"
	var _made := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(data))

	var game := ArenaGame.new()
	game.name = "Arena"
	game.is_authority = true
	game.headless = true
	game.register_service = true
	# The solo cfg layers, lenient as solo reads them: a typo must not stop a single-player game.
	var binder := ArenaConfig.make_binder(game.config, "user://cfg/arena.json")
	DotLog.result(CHANNEL, "config", binder.load_layers())
	game.config_binder = binder
	game.tick_rate = solo_tick_rate(game.config.solo_tick_tiers, bots + 1, game.config.tick_rate)
	var mode := _arg("--mode", "")
	if mode != "":
		game.mode_id = StringName(mode)
	add_child(game)
	_game = game
	var map := ArenaMap.by_id(StringName(_arg("--map", "")))
	var built := game.setup(map if map != null else ArenaMap.dm_box())
	if not built.ok:
		_die("the arena could not be built: %s" % built.error.message)
		return
	# As ArenaServer does: without it the boot map's match stays IDLE (nobody spawns, no
	# rounds) until the first host_change restarts it.
	game.start(0)

	var config := _server_config(port, game.tick_rate, data)
	var server := DotServer.new()
	server.name = "Server"
	server.config = config
	server.config_file = ""
	server.auto_boot = false
	add_child(server)
	var booted: DotResult = await server.boot()
	if not booted.ok:
		_die("boot: %s" % booted.error.message)
		return
	ArenaTickBudget.server_process = true
	var loaded: DotResult = await server.modules.load_module(ArenaPaths.rebase("res://game/arena_module.gd"))
	if not loaded.ok:
		_die("module: %s" % loaded.error.message)
		return
	var module := server.modules.get_module("arena") as ArenaModule
	_module = module
	var quota: DotBotQuota = module.get("_bot_quota")
	if quota != null and quota.mode_cvar != null:
		quota.mode_cvar.force_set("fixed")
		quota.quota_cvar.force_set(str(bots))
		quota.empty_cvar.force_set("1")
	if not _apply_cvars(server):
		return
	for i in bots:
		var _id: int = module.bridge.add_bot("Bot %d" % (i + 1))
	var owner_node := ArenaSimOwner.new()
	owner_node.name = "Owner"
	add_child(owner_node)
	owner_node.setup(server, module)

	var ready_path := _arg("--ready", "")
	if ready_path != "":
		var f := FileAccess.open(ready_path, FileAccess.WRITE)
		if f != null:
			var _stored := f.store_string(str(config.effective_enet_port()))
			f.close()
	_server = server
	print("SIM_HOST ready map=%s mode=%s bots=%d bot_threads=%d brain=%s loop=%s" % [String(game.map.id), String(game.mode.id), bots,  # check-logging: allow print (the SIM_HOST lines are the bench output perf_bench and soak read)
		ArenaBotThreads.threads, "native" if ArenaPlayerStack.brain_native() else "script",
		"native" if ArenaBots.tier_schedule and bool(ArenaBots.tiers.get(&"native")) and ClassDB.class_exists(&"DotSimThinkTier") else "script"])
	_report(module.net)


## The tick rate for [param players] from [member ArenaConfig.solo_tick_tiers] ([param spec]), else [param default_rate].
## A table that does not parse, or names a rate the game cannot run, is said loudly and leaves [param default_rate].
static func solo_tick_rate(spec: String, players: int, default_rate: int) -> int:
	var tiers := DotTickTiers.parse(spec)
	if tiers.error != "":
		DotLog.warn(CHANNEL, "solo_tick_tiers ignored (%s); ticking at %d" % [tiers.error, default_rate])
		return default_rate
	var rate := tiers.rate_for(players, default_rate)
	if rate < ArenaGame.MIN_TICK_RATE or rate > ArenaGame.MAX_TICK_RATE:
		DotLog.warn(CHANNEL, "solo_tick_tiers gives %d Hz for %d players, outside %d-%d; ticking at %d" % [
			rate, players, ArenaGame.MIN_TICK_RATE, ArenaGame.MAX_TICK_RATE, default_rate])
		return default_rate
	if rate != default_rate:
		print("SIM_HOST tick rate %d for %d players (solo_tick_tiers %s)" % [rate, players, spec])  # check-logging: allow print (the SIM_HOST lines are the bench output perf_bench and soak read)
	return rate


## The bench switches a perf run passes through: bot threads, native brain and loop, a synthetic load and tick sections.
# `--cvar name=value` (repeatable), a bench knob for an A/B of one setting; an unknown name stops the host.
func _apply_cvars(server: DotServer) -> bool:
	var args := OS.get_cmdline_user_args()
	for k in args.size() - 1:
		if args[k] != "--cvar":
			continue
		var pair := args[k + 1].split("=", true, 1)
		var cv: DotConVar = server.console.find_cvar(pair[0]) if pair.size() == 2 else null
		if cv == null:
			_die("--cvar %s: no such cvar (name=value)" % args[k + 1])
			return false
		cv.force_set(pair[1])
	return true


func _apply_bench_flags() -> void:
	# The brains on worker threads: the same match as one thread (headless_botthreads), less of each tick.
	ArenaBotThreads.threads = maxi(0, int(_arg("--bot_threads", str(default_bot_threads()))))
	# dot-bot's native mind (the `bot_native_brain` cvar, off by default) for a bench's A/B; brains on workers leave it.
	var brain_native := _arg("--bot_native_brain", "")
	if brain_native != "":
		ArenaPlayerStack.set_brain_native(brain_native.to_int() != 0)
	# dot-sim's native bot loop (think tiers so far; on when the library is loaded) off for a bench's A/B.
	var native_loop := _arg("--bot_native_loop", "")
	if native_loop != "" and ArenaBots.tier_schedule:
		# By name: dot-bot 26 (the live shell's) has no native tier to switch.
		ArenaBots.tiers.set(&"native", native_loop.to_int() != 0)
	_load_us = maxi(0, int(_arg("--sim_load_us", "0")))
	set_physics_process(_load_us > 0)
	# Where a tick goes: the [ArenaFrameProbe] sections the server's tick records (srv_*, tick_*, p_*, bot_*, w_*),
	# printed per tick beside each SIM_HOST line. Off by default: each section costs two clock reads.
	# `2` adds the sub-spans inside them (`pl_pre`, `p_hitbox`, `p_wctx`, `br_*`; [member ArenaFrameProbe.fine]): a clock read each, so read shares.
	var sections := _arg("--sim_sections", "0")
	if sections == "1" or sections == "2":
		ArenaFrameProbe.set_interval(1.0e9)
		# The addons' own phases, in a SIM_HOST_PHASES line: the controller's always, the brain's on one thread only.
		DotFpsController.phase_timers = true
		if ArenaBots.brain_phases:
			# By name: dot-bot 26 (the live shell's) has no brain phase timers.
			(DotBotBrain as GDScript).set(&"phase_timers", ArenaBotThreads.threads == 0)
		ArenaFrameProbe.fine = sections == "2"
		# p_weapons split by the rig's and the arsenal's own clocks (pw_*, pa_*), on the fine level only: a clock read a part.
		for w in _weapon_phase_clocks():
			(w[1] as GDScript).set(&"phase_timers", ArenaFrameProbe.fine)


## The loopback server config for the solo host: [param data] holds its admin, ban and audit files.
static func _server_config(port: int, tickrate: int, data: String) -> DotServerConfig:
	var config := DotServerConfig.new()
	config.hostname = "solo"
	config.port = port
	config.tickrate = tickrate
	config.max_players = 0  # unlimited, as on the dedicated stack: bot_quota sets the bots; nothing caps them at 64
	config.bind_address = "127.0.0.1"
	config.transport_mode = "dual"
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % data
	config.bans_path = "%s/bans.json" % data
	config.audit_log_path = "%s/audit.jsonl" % data
	config.hibernate_when_empty = false
	config.startup_config = ""
	config.autoexec_config = ""
	config.query_enabled = false
	config.enet_share_udp_port = false
	config.stdin_console_enabled = false
	# Only the owner chats here, and the menus ask over chat (B, the team screen's 2 s refresh): the
	# public 20 a minute refused them with "sending messages too quickly".
	config.chat_rate_per_minute = 240
	config.log_level = "warn"
	return config


func _process(delta: float) -> void:
	# A solo client that crashed cannot tell its server to stop: the server ends once its one remote
	# player is gone for a while, or when none ever came. (A process cannot ask after its parent.)
	_since_check += delta
	if _since_check < 1.0 or _server == null:
		return
	_alone_sec = 0.0 if _remote_players() > 0 else _alone_sec + _since_check
	_since_check = 0.0
	_joined = _joined or _alone_sec == 0.0
	if _alone_sec >= (GONE_SEC if _joined else NEVER_SEC):
		get_tree().quit(0)


func _physics_process(_delta: float) -> void:
	var until := Time.get_ticks_usec() + _load_us
	while Time.get_ticks_usec() < until:
		pass


func _remote_players() -> int:
	var count := 0
	for session: DotClientSession in _server.sessions():
		if not session.local:
			count += 1
	return count


## Every few seconds, one line: the tick rate held and what a tick cost (dot-net server counters).
func _report(net: DotNetManager) -> void:
	var last: Dictionary = net.perf_counters()
	var t0 := Time.get_ticks_usec()
	while is_inside_tree():
		await get_tree().create_timer(REPORT_SEC).timeout
		var now: Dictionary = net.perf_counters()
		var secs := (Time.get_ticks_usec() - t0) / 1.0e6
		var ticks := maxi(1, int(now[&"server_ticks"]) - int(last[&"server_ticks"]))
		var held := ticks / secs
		var sim_ms := (int(now[&"server_sim_usec"]) - int(last[&"server_sim_usec"])) / 1000.0 / ticks
		print("SIM_HOST %.1f ticks/s of %d | sim %.3f ms/tick send %.3f ms/tick" % [  # check-logging: allow print (the SIM_HOST lines are the bench output perf_bench and soak read)
			held, Engine.physics_ticks_per_second, sim_ms,
			(int(now[&"server_send_usec"]) - int(last[&"server_send_usec"])) / 1000.0 / ticks])
		var behind := behind_line(held, Engine.physics_ticks_per_second, sim_ms)
		if behind != "":
			DotLog.warn(CHANNEL, behind)
		_tell_player(held, Engine.physics_ticks_per_second)
		# server_tick's own sections (a dot-net without them reports 0): input before sim, the
		# still-registered check inside sim, the rewind history record inside send.
		print("SIM_HOST_NET ms/tick | input %.3f, check %.3f, hist %.3f" % [  # check-logging: allow print (the SIM_HOST lines are the bench output perf_bench and soak read)
			_per_tick(now, last, &"server_input_usec", ticks), _per_tick(now, last, &"server_check_usec", ticks),
			_per_tick(now, last, &"server_history_usec", ticks)])
		if ArenaFrameProbe.on():
			print(sections_line(ArenaFrameProbe._sections, ticks))  # check-logging: allow print (the SIM_HOST lines are the bench output perf_bench and soak read)
			ArenaFrameProbe._reset()
			print(phases_line(ticks))  # check-logging: allow print (the SIM_HOST lines are the bench output perf_bench and soak read)
		last = now
		t0 = Time.get_ticks_usec()


## Under this share of its rate a report window says the game ran slower than the clock.
const BEHIND_SHARE := 0.95


## The loud line for a window that held [param held] ticks a second of [param rate], or "" while it kept real time.
## The solo client follows this server's pace, so a short window is a game (gravity included) slowed by that share.
static func behind_line(held: float, rate: int, sim_ms: float) -> String:
	if rate <= 0 or held >= rate * BEHIND_SHARE:
		return ""
	return "SIM_HOST BEHIND real time: %.1f of %d ticks/s, the game runs at %d%% speed (a tick costs %.1f ms of %.1f); lower solo_tick_tiers or the bots" % [
		held, rate, roundi(held * 100.0 / rate), sim_ms, 1000.0 / rate]


## Says in the game, as a server line, that it runs slower than the clock: once as it falls behind, then every
## [member ArenaConfig.behind_notice_sec] while it stays behind, and again after it caught up and fell behind again.
func _tell_player(held: float, rate: int) -> void:
	var now := Time.get_ticks_msec()
	var every := _game.config.behind_notice_sec if _game != null else 0.0
	var text := behind_notice(held, rate)
	if text == "":
		_behind_said_ms = -1
		return
	if not notice_due(now, _behind_said_ms, every):
		return
	_behind_said_ms = now
	if _module != null and _module.services != null:
		_module.services.announce(text)


## The player's line for a window that held [param held] ticks a second of [param rate], or "" while it kept real time.
static func behind_notice(held: float, rate: int) -> String:
	if rate <= 0 or held >= rate * BEHIND_SHARE:
		return ""
	return "The server cannot keep up: the game runs at %d%% speed. Fewer bots or a lower arena_solo_tick_tiers helps." % roundi(held * 100.0 / rate)


## Whether a behind line is due at [param now_ms] when the last was said at [param last_ms] (-1: not while behind).
static func notice_due(now_ms: int, last_ms: int, every_sec: float) -> bool:
	return last_ms < 0 or every_sec <= 0.0 or now_ms - last_ms >= int(every_sec * 1000.0)


static func _per_tick(now: Dictionary, last: Dictionary, key: StringName, ticks: int) -> float:
	return (int(now.get(key, 0)) - int(last.get(key, 0))) / 1000.0 / ticks


## `SIM_HOST_SECTIONS name ms/tick xcalls/tick, ...`, costliest first. Sections nest (srv_game holds tick_players,
## which holds p_weapons), so the lines do not add up to the sim time.
static func sections_line(sections: Dictionary, ticks: int) -> String:
	var rows: Array = []
	for key: StringName in sections:
		var row: PackedInt64Array = sections[key]
		rows.append([row[0] / 1000.0 / ticks, String(key), float(row[1]) / ticks])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var parts := PackedStringArray()
	for r: Array in rows:
		parts.append("%s %.3f x%.1f" % [r[1], r[0], r[2]])
	return "SIM_HOST_SECTIONS ms/tick | " + ", ".join(parts)


## [prefix, script] of the weapon sub-phase clocks this build's addons have: AwWeaponRig's from arena-weapons API 10,
## DotWeaponArsenal's from dot-weapon API 32. Read and set by name, so an older shell's addons still parse.
static func _weapon_phase_clocks() -> Array:
	var clocks := []
	if DotAddonApi.build_level("arena_weapons") >= 10:
		clocks.append(["pw_", AwWeaponRig])
	if DotAddonApi.build_level("dot_weapon") >= 32:
		clocks.append(["pa_", DotWeaponArsenal])
	return clocks


## `SIM_HOST_PHASES name ms/tick, ...`: DotFpsController's phases (pc_*, outside the motor) and DotBotBrain's (bb_*).
static func phases_line(ticks: int) -> String:
	var parts := PackedStringArray()
	var names := ["pc_pre", "pc_consume", "pc_motor", "pc_publish", "pc_report", "pc_signals", "pc_post", "pc_body"]
	for i in names.size():
		parts.append("%s %.3f" % [names[i], DotFpsController.phase_us[i] / 1000.0 / ticks])
	# The rig's and the arsenal's sub-phases (pw_*, pa_*), by name: an older shell's addons have no such timers.
	for w in _weapon_phase_clocks():
		var script: GDScript = w[1]
		if not script.get(&"phase_timers"):
			continue
		var w_names: Array = script.get(&"PHASES")
		var w_us: PackedInt64Array = script.get(&"phase_us")
		for i in w_names.size():
			parts.append("%s%s %.3f" % [w[0], w_names[i], w_us[i] / 1000.0 / ticks])
		w_us.fill(0)
		script.set(&"phase_us", w_us)
	DotFpsController.phase_us.fill(0)
	if not ArenaBots.brain_phases:
		return "SIM_HOST_PHASES ms/tick | " + ", ".join(parts)
	var brain: GDScript = DotBotBrain
	var brain_names: Array = brain.get(&"PHASES")
	var brain_us: PackedInt64Array = brain.get(&"phase_us")
	for i in brain_names.size():
		parts.append("%s %.3f" % [brain_names[i], brain_us[i] / 1000.0 / ticks])
	brain_us.fill(0)
	brain.set(&"phase_us", brain_us)
	return "SIM_HOST_PHASES ms/tick | " + ", ".join(parts)


func _die(why: String) -> void:
	printerr("arena sim server: ", why)
	get_tree().quit(1)


## A quarter of the machine's threads, at most [constant BOT_THREADS_MAX]; 0 (one after another) below 8.
static func default_bot_threads() -> int:
	var n := mini(floori(OS.get_processor_count() / 4.0), BOT_THREADS_MAX)
	return n if n >= 2 else 0


static func _arg(flag: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find(flag)
	return args[index + 1] if index >= 0 and index + 1 < args.size() else fallback
