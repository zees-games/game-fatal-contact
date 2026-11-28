## Client cvars for the frame-hitch fixes (nightly perf-400fps-32bots-1): each turns a reuse or a load-time warm-up
## on; 0 puts back the older path, built on first use.
extends RefCounted

## cl_scoreboard_reuse: the Tab board refills its drawn rows (gs-menu 24's reuse_rows) instead of building ~1300 Controls a refresh.
static var scoreboard_reuse := true
## cl_killview_cache: the kill view keeps a parked view model per weapon (up to KILLVIEW_RIGS) and swaps to one mid-replay.
static var killview_cache := true
## cl_scope_prewarm: the scope's lens, housing and glass are built and drawn once under the load cover.
static var scope_prewarm := true
## cl_drop_pool: a dropped weapon's pickup body is taken from a parked pool rather than built when it lands.
static var drop_pool := true

## View models the kill view keeps parked with [member killview_cache] on (4 without).
const KILLVIEW_RIGS := 10

const VARS: Array[StringName] = [&"cl_scoreboard_reuse", &"cl_killview_cache", &"cl_scope_prewarm", &"cl_drop_pool"]
const HELP: Array[String] = [
	"1 refills the scoreboard's drawn rows on a refresh; 0 builds every row again.",
	"1 keeps a parked kill-view model per weapon and swaps to it; 0 re-equips one model (a build per new weapon).",
	"1 builds and draws the scope once at load; 0 builds it on the first scope.",
	"1 reuses parked weapon-drop bodies; 0 builds each drop as it lands.",
]


static func value(key: StringName) -> bool:
	match key:
		&"cl_scoreboard_reuse":
			return scoreboard_reuse
		&"cl_killview_cache":
			return killview_cache
		&"cl_scope_prewarm":
			return scope_prewarm
		&"cl_drop_pool":
			return drop_pool
	return false


static func store(key: StringName, on: bool) -> void:
	match key:
		&"cl_scoreboard_reuse":
			scoreboard_reuse = on
		&"cl_killview_cache":
			killview_cache = on
		&"cl_scope_prewarm":
			scope_prewarm = on
		&"cl_drop_pool":
			drop_pool = on


static func add_vars(local: GSConsoleLocal) -> void:
	for i in VARS.size():
		var key: StringName = VARS[i]
		local.add_var(key, HELP[i],
			func() -> Variant: return 1 if value(key) else 0,
			func(v: Variant) -> Variant:
				var text := str(v).strip_edges()
				if text != "0" and text != "1":
					return GSResult.fail(GSError.CODE_INVALID, "%s takes 0 or 1" % key)
				store(key, text == "1")
				return GSResult.success(1 if text == "1" else 0)
		)
