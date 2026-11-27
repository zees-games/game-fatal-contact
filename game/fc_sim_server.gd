extends Node

const FcConfig := preload("fc_config.gd")
const FcGame := preload("fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcModule := preload("fc_module.gd")
const FcSimOwner := preload("fc_sim_owner.gd")
const FcBots := preload("fc_bots.gd")
const FcBotThreads := preload("fc_bot_threads.gd")
const FcTickBudget := preload("fc_tick_budget.gd")
const FcPlayerStack := preload("fc_player_stack.gd")
const FcMaps := preload("fc_maps.gd")
const FcWeaponDropWiring := preload("fc_weapon_drop_wiring.gd")
const FcPaths := preload("fc_paths.gd")
const FcSimPacer := preload("fc_sim_pacer.gd")
const FcNativePhases := preload("fc_native_phases.gd")

## The authoritative game of a solo session in its own process (`--sim_host 1`, [FcSimHost]): a loopback dedicated server the solo client spawns and joins, so the 66 Hz simulation never runs on the render thread. The same [FcModule] a public server runs.
## Launch flags (after `--`): `--port N --bots N --map ID --mode ID --ready PATH --bot_threads N --sim_load_us N --sim_sections 1 --sim_bench_sec N --sim_tick_raw 1 --bot_native_brain 0|1 --bot_native_loop 0|1 --cvar name=value`. It writes PATH once it accepts players, and quits a few seconds after its player left.

const FcFrameProbe := preload("fc_frame_probe.gd")

const CHANNEL := "arena.sim_server"
const REPORT_SEC := 5.0
const GONE_SEC := 5.0
const NEVER_SEC := 120.0

var _server: GSServer = null
var _joined := false
var _alone_sec := 0.0
var _since_check := 0.0
## `--sim_load_us N`, a bench knob: N microseconds of busy wait on every physics tick, to stand in for a
## slower machine's tick (the owner's 12-14 ms) on a fast bench box. 0, the default, adds nothing.
var _load_us := 0
var _game: FcGame = null
var _module: FcModule = null
## When the in-game behind line was last said (msec), or -1 while the server keeps its rate.
var _behind_said_ms := -1
## The longest gap between two frames in this report window (usec): a stall outside the tick shows here and not in SIM_HOST_TICK.
var _frame_at_usec := 0
var _frame_gap_max_usec := 0
## Paces the frames to the tick rate with a sleep then a spin (the OS timer may be coarse) and measures late ticks; `--sim_pace auto` (default) only on a coarse timer, `1` always, `0` never.
var _pacer := FcSimPacer.new()
## `--sim_slow_tick MS`: a tick (or a frame gap) over this prints a `SIM_HOST_SLOW_TICK` (`SIM_HOST_SLOW_FRAME`) line saying where it went; 0 (default) none.
var _slow_tick_ms := 0
## Slow-tick lines left in this report window: a stuck server must not flood the log.
var _slow_left := SLOW_LINES_PER_WINDOW
## Physics ticks run since the last frame (a slow frame's catch-up).
var _ticks_this_frame := 0
## The most slow-tick and slow-frame lines in one report window.
const SLOW_LINES_PER_WINDOW := 30
## `--sim_bench_sec N`: quit N seconds after the server is up, with no client (a bench or a coverage suite); 0 (default) waits for one.
var _bench_usec := 0
var _bench_from_usec := 0
## `--sim_tick_raw 1`: each report window also prints every tick's cost (`SIM_HOST_TICK_US`), so a bench can take its own mean and p99.
var _tick_raw := false


func _ready() -> void:
	# A sim host serves one solo client, so it offers the maps copied onto this machine as that client does.
	FcMaps.list_local = true
	var port := int(_arg("--port", "0"))
	var bots := int(_arg("--bots", "0"))
	if port <= 0:
		_die("no --port")
		return
	_apply_bench_flags()
	var data := "user://sim_host"
	var _made := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(data))

	var game := FcGame.new()
	game.name = "Arena"
	game.is_authority = true
	game.headless = true
	game.register_service = true
	# The solo cfg layers, lenient as solo reads them: a typo must not stop a single-player game.
	var binder := FcConfig.make_binder(game.config, "user://cfg/arena.json")
	GSLog.result(CHANNEL, "config", binder.load_layers())
	game.config_binder = binder
	game.tick_rate = solo_tick_rate(game.config.solo_tick_tiers, bots + 1, game.config.tick_rate)
	var mode := _arg("--mode", "")
	if mode != "":
		game.mode_id = StringName(mode)
	add_child(game)
	_game = game
	var map: FcMap = FcMap.by_id(StringName(_arg("--map", "")))
	var built := game.setup(map if map != null else FcMap.dm_box())
	if not built.ok:
		_die("Fatal Contact could not be built: %s" % built.error.message)
		return
	# As FcServer does: without it the boot map's match stays IDLE (nobody spawns, no
	# rounds) until the first host_change restarts it.
	game.start(0)

	var config := _server_config(port, game.tick_rate, data)
	var server := GSServer.new()
	server.name = "Server"
	server.config = config
	server.config_file = ""
	server.auto_boot = false
	add_child(server)
	var booted: GSResult = await server.boot()
	if not booted.ok:
		_die("boot: %s" % booted.error.message)
		return
	FcTickBudget.server_process = true
	var loaded: GSResult = await server.modules.load_module(FcPaths.rebase("res://game/fc_module.gd"))
	if not loaded.ok:
		_die("module: %s" % loaded.error.message)
		return
	var module := server.modules.get_module("arena") as FcModule
	_module = module
	_watch_slow_ticks(module)
	var quota: GSBotQuota = module.get("_bot_quota")
	if quota != null and quota.mode_cvar != null:
		quota.mode_cvar.force_set("fixed")
		quota.quota_cvar.force_set(str(bots))
		quota.empty_cvar.force_set("1")
	if not _apply_cvars(server):
		return
	for i in bots:
		var _id: int = module.bridge.add_bot("Bot %d" % (i + 1))
	var owner_node := FcSimOwner.new()
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
	# --sim_bench_sec counts from here: a slow box can spend longer than the bench loading the map and bots.
	_bench_from_usec = Time.get_ticks_usec()
	_print_ready(String(game.map.id), String(game.mode.id), bots)
	_report(module.net)


## The tick rate for [param players] from [member FcConfig.solo_tick_tiers] ([param spec]), else [param default_rate].
## A table that does not parse, or names a rate the game cannot run, is said loudly and leaves [param default_rate].
static func solo_tick_rate(spec: String, players: int, default_rate: int) -> int:
	var tiers := GSTickTiers.parse(spec)
	if tiers.error != "":
		GSLog.warn(CHANNEL, "solo_tick_tiers ignored (%s); ticking at %d" % [tiers.error, default_rate])
		return default_rate
	var rate := tiers.rate_for(players, default_rate)
	if rate < FcGame.MIN_TICK_RATE or rate > FcGame.MAX_TICK_RATE:
		GSLog.warn(CHANNEL, "solo_tick_tiers gives %d Hz for %d players, outside %d-%d; ticking at %d" % [
			rate, players, FcGame.MIN_TICK_RATE, FcGame.MAX_TICK_RATE, default_rate])
		return default_rate
	if rate != default_rate:
		print("SIM_HOST tick rate %d for %d players (solo_tick_tiers %s)" % [rate, players, spec])  # check-logging: allow print (the SIM_HOST lines are the bench output perf_bench and soak read)
	return rate


## The bench switches a perf run passes through: bot threads, native brain and loop, a synthetic load and tick sections.
# `--cvar name=value` (repeatable), a bench knob for an A/B of one setting; an unknown name stops the host.
func _apply_cvars(server: GSServer) -> bool:
	var args := OS.get_cmdline_user_args()
	for k in args.size() - 1:
		if args[k] != "--cvar":
			continue
		var pair := args[k + 1].split("=", true, 1)
		var cv: GSConVar = server.console.find_cvar(pair[0]) if pair.size() == 2 else null
		if cv == null:
			_die("--cvar %s: no such cvar (name=value)" % args[k + 1])
			return false
		cv.force_set(pair[1])
	return true


func _apply_bench_flags() -> void:
	# The brains on worker threads: the same match as one thread (headless_botthreads), less of each tick.
	FcBotThreads.threads = maxi(0, int(_arg("--bot_threads", str(FcBotThreads.native_default()))))
	# gs-bot's native mind (the `bot_native_brain` cvar, on by default) for a bench's A/B; brains on workers keep it with a worker-safe gs-sim.
	var brain_native := _arg("--bot_native_brain", "")
	if brain_native != "":
		FcPlayerStack.set_brain_native(brain_native.to_int() != 0)
	# gs-sim's native bot loop (think tiers so far; on when the library is loaded) off for a bench's A/B.
	var native_loop := _arg("--bot_native_loop", "")
	if native_loop != "" and FcBots.tier_schedule:
		# By name: gs-bot 26 (the live shell's) has no native tier to switch.
		FcBots.tiers.set(&"native", native_loop.to_int() != 0)
	_load_us = maxi(0, int(_arg("--sim_load_us", "0")))
	_bench_usec = int(maxf(0.0, _arg("--sim_bench_sec", "0").to_float()) * 1.0e6)
	_tick_raw = _arg("--sim_tick_raw", "0") == "1"
	var pace := _arg("--sim_pace", "auto")
	# The native timer first: its resolution request can make the probe below find a fine timer, leaving the engine's pacing.
	if _arg("--sim_native_timer", "1") != "0":
		_pacer.use_native_timer()
	_pacer.enabled = pace == "1" or (pace == "auto" and FcSimPacer.timer_is_coarse())
	print("SIM_HOST_PACE path: %s" % _pacer.path())  # check-logging: allow print (the SIM_HOST lines are the bench output perf_bench and soak read)
	set_physics_process(true)
	# Where a tick goes: the [FcFrameProbe] sections the server's tick records (srv_*, tick_*, p_*, bot_*, w_*),
	# printed per tick beside each SIM_HOST line. Off by default: each section costs two clock reads.
	# `2` adds the sub-spans inside them (`pl_pre`, `p_hitbox`, `p_wctx`, `br_*`; [member FcFrameProbe.fine]): a clock read each, so read shares.
	var sections := _arg("--sim_sections", "0")
	_slow_tick_ms = maxi(0, int(_arg("--sim_slow_tick", "0")))
	FcFrameProbe.slow_tick_usec = _slow_tick_ms * 1000
	if _slow_tick_ms > 0 and sections == "0":
		# The dump reads the sections, so it turns them on.
		sections = "1"
	if sections == "1" or sections == "2":
		FcFrameProbe.set_interval(1.0e9)
		# The addons' own phases, in a SIM_HOST_PHASES line: the controller's always, the brain's on one thread only
		# unless gs-bot times threaded brains (API 40, FcBots.brain_merge).
		GSFpsController.phase_timers = true
		FcBotThreads.phase_timers = true
		if FcBots.brain_phases:
			# By name: gs-bot 26 (the live shell's) has no brain phase timers.
			(GSBotBrain as GDScript).set(&"phase_timers", FcBotThreads.threads == 0 or FcBots.brain_merge)
		FcFrameProbe.fine = sections == "2"
		# p_weapons split by the rig's and the arsenal's own clocks (pw_*, pa_*), on the fine level and only when asked
		# ([member FcFrameProbe.weapon_phases]): armed, they turn the idle weapons' batch off.
		FcFrameProbe.weapon_phases = _arg("--sim_weapon_phases", "0") == "1"
		for w in _weapon_phase_clocks():
			(w[1] as GDScript).set(&"phase_timers", FcFrameProbe.fine and FcFrameProbe.weapon_phases)


## The loopback server config for the solo host: [param data] holds its admin, ban and audit files.
static func _server_config(port: int, tickrate: int, data: String) -> GSServerConfig:
	var config := GSServerConfig.new()
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
	var now_usec := Time.get_ticks_usec()
	if _frame_at_usec > 0:
		_frame_gap_max_usec = maxi(_frame_gap_max_usec, now_usec - _frame_at_usec)
		if _slow_tick_ms > 0 and now_usec - _frame_at_usec >= _slow_tick_ms * 4000 and _slow_left > 0:
			_slow_left -= 1
			_report_slow_frame(now_usec - _frame_at_usec)
	_frame_at_usec = now_usec
	_ticks_this_frame = 0
	# A solo client that crashed cannot tell its server to stop: the server ends once its one remote
	# player is gone for a while, or when none ever came. (A process cannot ask after its parent.)
	_since_check += delta
	if _pacer.enabled:
		# gs-server sets the engine's cap at every tick rate change; the pacer is the only limiter.
		Engine.max_fps = 0
		_pacer.pace(Engine.physics_ticks_per_second)
	if _since_check < 1.0 or _server == null:
		return
	if _bench_usec > 0 and now_usec - _bench_from_usec >= _bench_usec:
		print("SIM_HOST_NATIVE %s | end" % FcNativePhases.status_line(_module.console))  # check-logging: allow print (the SIM_HOST lines are the bench output perf_bench and soak read)
		get_tree().quit(0)
		return
	_alone_sec = 0.0 if _remote_players() > 0 else _alone_sec + _since_check
	_since_check = 0.0
	_joined = _joined or _alone_sec == 0.0
	if _alone_sec >= (GONE_SEC if _joined else NEVER_SEC):
		get_tree().quit(0)


# Only on a slow frame (--slow-tick-ms), at most _slow_left times: kept out of _process's every-frame path.
func _report_slow_frame(gap_usec: int) -> void:
	print("SIM_HOST_SLOW_FRAME ", snappedf(gap_usec / 1000.0, 0.1), " ms | ticks ", _ticks_this_frame,  # check-logging: allow print (bench output)
		" | objects ", int(Performance.get_monitor(Performance.OBJECT_COUNT)), " | static mem ",
		snappedf(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, 0.1), " MB")


func _physics_process(_delta: float) -> void:
	_pacer.note_tick()
	_ticks_this_frame += 1
	var until := Time.get_ticks_usec() + _load_us
	while Time.get_ticks_usec() < until:
		pass


func _remote_players() -> int:
	var count := 0
	for session: GSClientSession in _server.sessions():
		if not session.local:
			count += 1
	return count


## The slow-tick dump: the module tells each tick over `--sim_slow_tick`, and the game's events are noted on the tick they happen in.
func _watch_slow_ticks(module: FcModule) -> void:
	if _slow_tick_ms <= 0:
		return
	module.slow_tick_report = func(tick: int, usec: int, objects: int) -> void:
		if _slow_left <= 0:
			return
		_slow_left -= 1
		print(FcFrameProbe.slow_tick_line(tick, usec, 16, " | objects %+d | ticks this frame %d" % [objects, _ticks_this_frame]))  # check-logging: allow print (bench output)
	var game := module.game
	if game == null:
		return
	var _k := game.player_killed.connect(func(_e: Variant) -> void: FcFrameProbe.tick_event(&"kill"))
	var _s := game.player_spawned.connect(func(_p: Variant) -> void: FcFrameProbe.tick_event(&"spawn"))
	var _m := game.match_state_changed.connect(func(_f: Variant, to: Variant) -> void: FcFrameProbe.tick_event(StringName("match:%s" % GSMatch.State.keys()[to])))
	var _c := game.map_changed.connect(func(_map: Variant) -> void: FcFrameProbe.tick_event(&"map"))
	var _n := game.non_player_killed.connect(func(_id: Variant, _d: Variant) -> void: FcFrameProbe.tick_event(&"npc_kill"))


## Every few seconds, one line: the tick rate held and what a tick cost (gs-net server counters).
func _report(net: GSNetManager) -> void:
	var last: Dictionary = net.perf_counters()
	if _module != null:
		_module.keep_tick_costs = true
	var t0 := Time.get_ticks_usec()
	while is_inside_tree():
		var warm_from := FcWeaponDropWiring.server_warming(_game)
		await get_tree().create_timer(REPORT_SEC).timeout
		var boot := booting(warm_from, FcWeaponDropWiring.server_warming(_game))
		var now: Dictionary = net.perf_counters()
		var secs := (Time.get_ticks_usec() - t0) / 1.0e6
		var ticks := maxi(1, int(now[&"server_ticks"]) - int(last[&"server_ticks"]))
		var held := ticks / secs
		var sim_ms := (int(now[&"server_sim_usec"]) - int(last[&"server_sim_usec"])) / 1000.0 / ticks
		print("SIM_HOST %.1f ticks/s of %d | sim %.3f ms/tick send %.3f ms/tick" % [  # check-logging: allow print (the SIM_HOST lines are the bench output perf_bench and soak read)
			held, Engine.physics_ticks_per_second, sim_ms,
			(int(now[&"server_send_usec"]) - int(last[&"server_send_usec"])) / 1000.0 / ticks])
		var rate := Engine.physics_ticks_per_second
		var period := 1000000 / maxi(rate, 1)
		var costs: PackedInt32Array = _module.tick_costs if _module != null else PackedInt32Array()
		var over := 0
		for c in costs:
			if c > period:
				over += 1
		var behind := behind_line(held, rate, sim_ms, FcSimPacer.cause(over, costs.size(), _pacer.frames_over, _pacer.frames, _pacer.stall_max_usec, _pacer.over_max_usec, period) if _pacer.enabled else "")
		if behind != "" and not boot:
			GSLog.warn(CHANNEL, behind)
		if not boot:
			_tell_player(held, Engine.physics_ticks_per_second)
		if _module != null and _tick_raw:
			print("SIM_HOST_TICK_US%s %s" % [" boot" if boot else "", ",".join(PackedStringArray(Array(_module.tick_costs)))])  # check-logging: allow print (the SIM_HOST lines are the bench output perf_bench and soak read)
		if _module != null:
			print("SIM_HOST_NATIVE %s" % FcNativePhases.status_line(_module.console))  # check-logging: allow print (the SIM_HOST lines are the bench output perf_bench and soak read)
			print("%s | frame gap max %.1f ms%s" % [tick_line(_module.tick_costs, Engine.physics_ticks_per_second), _frame_gap_max_usec / 1000.0, " | boot warm" if boot else ""])  # check-logging: allow print (the SIM_HOST lines are the bench output perf_bench and soak read)
			_module.tick_costs.clear()
		_frame_gap_max_usec = 0
		_slow_left = SLOW_LINES_PER_WINDOW
		print(_pacer.window_line(rate))  # check-logging: allow print (the SIM_HOST lines are the bench output perf_bench and soak read)
		# server_tick's own sections (a gs-net without them reports 0): input before sim, the
		# still-registered check inside sim, the rewind history record inside send.
		print("SIM_HOST_NET ms/tick | input %.3f, check %.3f, hist %.3f" % [  # check-logging: allow print (the SIM_HOST lines are the bench output perf_bench and soak read)
			_per_tick(now, last, &"server_input_usec", ticks), _per_tick(now, last, &"server_check_usec", ticks),
			_per_tick(now, last, &"server_history_usec", ticks)])
		if FcFrameProbe.on():
			print(sections_line(FcFrameProbe._sections, ticks))  # check-logging: allow print (the SIM_HOST lines are the bench output perf_bench and soak read)
			print(net_split_line(FcFrameProbe._sections, ticks, _per_tick(now, last, &"server_input_usec", ticks),  # check-logging: allow print (the SIM_HOST lines are the bench output perf_bench and soak read)
				_per_tick(now, last, &"server_check_usec", ticks), _per_tick(now, last, &"server_send_usec", ticks)))
			FcFrameProbe._reset()
			print(phases_line(ticks))  # check-logging: allow print (the SIM_HOST lines are the bench output perf_bench and soak read)
		last = now
		t0 = Time.get_ticks_usec()


## `SIM_HOST_TICK`: the whole server tick's cost per tick in a window ([param costs], usec), p50/p95/max against the budget
## of [param rate] and how many ticks went over it: a mean hides the spikes that make a tick late.
static func tick_line(costs: PackedInt32Array, rate: int) -> String:
	var budget_ms := 1000.0 / maxi(rate, 1)
	if costs.is_empty():
		return "SIM_HOST_TICK no ticks | budget %.2f ms" % budget_ms
	var sorted := costs.duplicate()
	sorted.sort()
	var n := sorted.size()
	var over := 0
	for c in sorted:
		if c / 1000.0 > budget_ms:
			over += 1
	return "SIM_HOST_TICK ms | p50 %.2f p95 %.2f max %.2f over %d/%d | budget %.2f ms" % [
		sorted[int(n * 0.5)] / 1000.0, sorted[mini(n - 1, int(n * 0.95))] / 1000.0, sorted[n - 1] / 1000.0, over, n, budget_ms]


## Under this share of its rate a report window says the game ran slower than the clock.
const BEHIND_SHARE := 0.95


## The loud line for a window that held [param held] ticks a second of [param rate], or "" while it kept real time.
## The solo client follows this server's pace, so a short window is a game (gravity included) slowed by that share.
## [param cause] (from [method FcSimPacer.cause]) is appended when given, so a log says why: tick cost, timer or starvation.
static func behind_line(held: float, rate: int, sim_ms: float, cause: String = "") -> String:
	if rate <= 0 or held >= rate * BEHIND_SHARE:
		return ""
	return "SIM_HOST BEHIND real time: %.1f of %d ticks/s, the game runs at %d%% speed (a tick costs %.1f ms of %.1f); %s" % [
		held, rate, roundi(held * 100.0 / rate), sim_ms, 1000.0 / rate,
		"likely cause: " + cause if cause != "" else "lower solo_tick_tiers or the bots"]


## Whether a report window overlapped the boot's one-off work (the server drop warm, [param warming_at_start] or
## [param warming_at_end]): its numbers are printed, but it is not counted as behind nor told to the player.
## Every window after it is, played or not: a sim truly behind in play always says so.
static func booting(warming_at_start: bool, warming_at_end: bool) -> bool:
	return warming_at_start or warming_at_end


## Says in the game, as a server line, that it runs slower than the clock: once as it falls behind, then every
## [member FcConfig.behind_notice_sec] while it stays behind, and again after it caught up and fell behind again.
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
	return "The server cannot keep up: the game runs at %d%% speed. Fewer bots or a lower fc_solo_tick_tiers helps." % roundi(held * 100.0 / rate)


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


## What `srv_net` holds, as parts that do add up. gs-net's server tick runs every entity's `_net_simulate`, and the
## first player's runs the whole game, so `srv_net` wraps `srv_bots` and `srv_game` (siblings, not nested in each
## other), the kill view, the toy pulls and each player's own `srv_netpull`, then gs-net's input, check and send
## (send includes the history record). `rest` is what none of them owns: the registry walk, every behaviour's
## `_net_simulate` call around those spans, and the probes' own bookkeeping.
## `SIM_HOST_NET_SPLIT ms/tick | srv_net 19.01 = srv_game 11.58 + srv_bots 4.97 + ... + rest 0.35`.
static func net_split_line(sections: Dictionary, ticks: int, input_ms: float, check_ms: float, send_ms: float) -> String:
	var ms := func(key: StringName) -> float:
		var row: PackedInt64Array = sections.get(key, PackedInt64Array([0]))
		return row[0] / 1000.0 / maxi(ticks, 1)
	var total: float = ms.call(&"srv_net")
	var rest := total - input_ms - check_ms - send_ms
	var parts := PackedStringArray()
	for key: StringName in NET_SPLIT:
		var spent: float = ms.call(key)
		rest -= spent
		parts.append("%s %.3f" % [key, spent])
	parts.append_array(PackedStringArray(["send %.3f" % send_ms, "input %.3f" % input_ms, "check %.3f" % check_ms, "rest %.3f" % rest]))
	return "SIM_HOST_NET_SPLIT ms/tick | srv_net %.3f = %s" % [total, " + ".join(parts)]


## The FcFrameProbe spans nested directly in `srv_net` ([method net_split_line]).
const NET_SPLIT: Array[StringName] = [&"srv_game", &"srv_bots", &"srv_netpull", &"srv_killview", &"srv_pulls"]


## [prefix, script] of the weapon and shot sub-phase clocks this build's addons have: AwWeaponRig's from fc-weapons API 10,
## GSWeaponArsenal's from gs-weapon API 32, GSCombatManager's and GSTrace's from gs-combat API 7. Read and set by name, so an older shell's addons still parse.
static func _weapon_phase_clocks() -> Array:
	var clocks := []
	if GSAddonApi.build_level("fc_weapons") >= 10:
		clocks.append(["pw_", AwWeaponRig])
	if GSAddonApi.build_level("gs_weapon") >= 32:
		clocks.append(["pa_", GSWeaponArsenal])
	# s_resolve's parts: GSCombatManager.resolve_shot (sr_*) and GSTrace.ray inside its pellets (st_*), gs-combat API 7.
	if GSAddonApi.build_level("gs_combat") >= 7:
		clocks.append(["sr_", GSCombatManager])
		clocks.append(["st_", GSTrace])
	return clocks


## `SIM_HOST_PHASES name ms/tick, ...`: GSFpsController's phases (pc_*, outside the motor) and GSBotBrain's (bb_*).
static func phases_line(ticks: int) -> String:
	var parts := PackedStringArray()
	var names := ["pc_pre", "pc_consume", "pc_motor", "pc_publish", "pc_report", "pc_signals", "pc_post", "pc_body"]
	for i in names.size():
		parts.append("%s %.3f" % [names[i], GSFpsController.phase_us[i] / 1000.0 / ticks])
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
	GSFpsController.phase_us.fill(0)
	# srv_bots outside the brains (sb_*, FcBotThreads.PHASES).
	for i in FcBotThreads.PHASES.size():
		parts.append("%s %.3f" % [FcBotThreads.PHASES[i], FcBotThreads.phase_us[i] / 1000.0 / ticks])
	FcBotThreads.phase_us.fill(0)
	if not FcBots.brain_phases:
		return "SIM_HOST_PHASES ms/tick | " + ", ".join(parts)
	var brain: GDScript = GSBotBrain
	var brain_names: Array = brain.get(&"PHASES")
	var brain_us: PackedInt64Array = brain.get(&"phase_us")
	for i in brain_names.size():
		parts.append("%s %.3f" % [brain_names[i], brain_us[i] / 1000.0 / ticks])
	brain_us.fill(0)
	brain.set(&"phase_us", brain_us)
	# gs-bot 40: the world queries' calls per tick beside their time (bq_*_n).
	var brain_calls: Variant = brain.get(&"phase_calls")
	if brain_calls is PackedInt64Array:
		var calls: PackedInt64Array = brain_calls
		for i in brain_names.size():
			if String(brain_names[i]).begins_with("bq_"):
				parts.append("%s_n %.2f" % [brain_names[i], calls[i] / float(ticks)])
		calls.fill(0)
		brain.set(&"phase_calls", calls)
	return "SIM_HOST_PHASES ms/tick | " + ", ".join(parts)


func _die(why: String) -> void:
	printerr("arena sim server: ", why)
	get_tree().quit(1)


static func _arg(flag: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find(flag)
	return args[index + 1] if index >= 0 and index + 1 < args.size() else fallback


## The bench's ready line: the map, the bots and which bot paths run natively (perf_bench and soak read it).
static func _print_ready(map_id: String, mode_id: String, bots: int) -> void:
	print("SIM_HOST ready map=%s mode=%s bots=%d bot_threads=%d brain=%s loop=%s drops=%s unstick=%s" % [map_id, mode_id, bots,  # check-logging: allow print (the SIM_HOST lines are the bench output perf_bench and soak read)
		FcBotThreads.threads, "native" if FcPlayerStack.brain_native() else "script",
		"native" if FcBots.tier_schedule and bool(FcBots.tiers.get(&"native")) and ClassDB.class_exists(&"GSSimThinkTier") else "script",
		"native" if bool((GSBotWorld as Script).get(&"native_drops")) and ClassDB.class_has_method(&"GSSimBotDrops", &"pack") else "script",
		"native" if bool((GSBotUnstick as Script).get(&"native_enabled")) and ClassDB.class_has_method(&"GSSimBotMind", &"unstick_step") else "script"])
