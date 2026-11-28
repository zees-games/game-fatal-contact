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
## cl_scope_release: a put-away scope gives back its lens picture (fc-weapons AwScopeGlass.release_stowed) and every lens shares one
## environment (share_environment). 0 keeps a 384-pixel MSAA target per stowed scoped gun and an environment per lens.
static var scope_release := true:
	set(value):
		scope_release = value
		AwViewModel.ScopeGlass.release_stowed = value
		AwViewModel.ScopeGlass.share_environment = value
## cl_equip_reuse: a build pushed out of a view's cache, or left by a freed view (a kill-view rig past the cap), goes to the shared store
## for the next view to take (fc-weapons aw_equip_cache.gd spill_evicted); the shared store is capped at [constant SHARED_PER_WEAPON] builds
## a weapon, and a kill-view rig keeps [constant KILLVIEW_RIG_KEEPS] put-away build of its own. 0 frees them, the store unbounded and 6 a rig, as before.
static var equip_reuse := true:
	set(value):
		equip_reuse = value
		_EquipCache.spill_evicted = value
		apply_store_cap()
## cl_trail_share: thrown-knife streaks share one material, gradient and glint (made and drawn under the load cover); 0 builds them per knife.
static var trail_share := true
## cl_drop_warm: every weapon's drop look and a kill's point, health and ammo pickups drawn for real ahead of the camera under the load
## cover, so their lit, fogged pass compiles there (a first battle_rifle drop was 9 shader compiles, 71 ms); 0 leaves only the collected warm-up.
static var drop_warm := true

const _EquipCache := preload("res://addons/fc_weapons/view/aw_equip_cache.gd")
## Shared-store builds allowed per weapon in the art table with [member equip_reuse] on.
const SHARED_PER_WEAPON := 2
## A parked kill-view rig's own put-away builds with [member equip_reuse] on (they spill to the shared store beyond it).
const KILLVIEW_RIG_KEEPS := 1

## View models the kill view keeps parked with [member killview_cache] on (4 without).
const KILLVIEW_RIGS := 10

const VARS: Array[StringName] = [&"cl_scoreboard_reuse", &"cl_killview_cache", &"cl_scope_prewarm", &"cl_drop_pool",
	&"cl_scope_release", &"cl_equip_reuse", &"cl_trail_share", &"cl_drop_warm"]
const HELP: Array[String] = [
	"1 refills the scoreboard's drawn rows on a refresh; 0 builds every row again.",
	"1 keeps a parked kill-view model per weapon and swaps to it; 0 re-equips one model (a build per new weapon).",
	"1 builds and draws the scope once at load; 0 builds it on the first scope.",
	"1 reuses parked weapon-drop bodies; 0 builds each drop as it lands.",
	"1 frees a put-away scope's lens picture and shares one lens environment; 0 keeps both per scope.",
	"1 hands put-away weapon builds between views (capped shared store); 0 frees them past each view's cache.",
	"1 shares the thrown-knife streak's material and glint, warmed at load; 0 builds them per knife.",
	"1 draws every weapon drop and pickup once ahead of the camera at load; 0 compiles them on the first drop.",
]


## The shared store's cap for [member equip_reuse]: [constant SHARED_PER_WEAPON] a weapon in the art table on, unbounded (0) off.
static func apply_store_cap() -> void:
	AwViewModel.prewarm_keep_limit = AwWeaponArtTable.table().size() * SHARED_PER_WEAPON if equip_reuse else 0


## A kill-view rig's own cache size.
static func killview_rig_keeps() -> int:
	return KILLVIEW_RIG_KEEPS if equip_reuse else 6


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
		&"cl_scope_release":
			return scope_release
		&"cl_equip_reuse":
			return equip_reuse
		&"cl_trail_share":
			return trail_share
		&"cl_drop_warm":
			return drop_warm
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
		&"cl_scope_release":
			scope_release = on
		&"cl_equip_reuse":
			equip_reuse = on
		&"cl_trail_share":
			trail_share = on
		&"cl_drop_warm":
			drop_warm = on


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
