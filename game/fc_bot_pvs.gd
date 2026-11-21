extends RefCounted
## The map's PVS before a bot's sight ray (cvar `fc_bot_pvs`), as the Source engine asks it before its own trace
## (`CCSBot::IsVisible`): a cluster pair that no position can see between needs no ray. The PVS is the one dot-net
## already holds for snapshot interest (`GSNetVisibility`, attached by the module on a converted map with vis data).
## [b]Same answers:[/b] the set only says "no" where the map's world brushes block every line between the two clusters
## (doors count as open), so the ray it saves would have come back blocked; `fc_bot_pvs_verify` (scale128 `--pvsverify`)
## casts it anyway and counts every disagreement. dot-sim's `GSSimPvs` asks the same set natively (cvar
## `fc_bot_pvs_native`, bit for bit with the script). Without the library no set is asked: the script set costs more
## than the rays it saves (scale128 A/B, blackhawkdown 32 bots: bot_los 0.50 ms off, 0.36 native, 0.65 script), so it
## answers only when `fc_bot_pvs_native` is 0 (the reference and the A/B arm).
## Typed loosely on purpose: a build whose dot-net lacks the class still parses this file.

## The game's meta holding the map's set, written by the module when it attaches the set to its netcode.
const META := &"fc_bot_pvs_set"

## Cvar `fc_bot_pvs`: 0 casts every sight ray.
static var enabled := true
## Cvar `fc_bot_pvs_native`: 0 asks the script set even where dot-sim has `GSSimPvs` (slower than no set).
static var native := true
## Cvar `fc_bot_pvs_verify`: every pair the set rules out is also cast, and with the native set every ask is also
## put to the script set; [member stats] counts what disagreed. The ray's answer is the one used.
static var verify := false
## Counting switch for the bench and the suite ([member stats]); off, nothing is counted.
static var counting := false
## Asks, pairs ruled out, ruled-out pairs whose ray was clear, native answers that differed from the script's.
static var stats := PackedInt64Array([0, 0, 0, 0])
static var _lock := Mutex.new()

## The script set ([code]GSNetVisibility[/code]) of the map in play, or null.
var script_set: Object = null
## The set [method open] asks: the native one, the script one or null (no PVS: every ray is cast).
var active: Object = null
var _native: Object = null


static func reset_stats() -> void:
	_lock.lock()
	stats = PackedInt64Array([0, 0, 0, 0])
	_lock.unlock()


static func _count(slot: int) -> void:
	_lock.lock()
	stats[slot] += 1
	_lock.unlock()


## Finds the map's PVS on [param game] (meta [constant META]); once a tick, before any ask.
func bind(game: Object) -> void:
	active = null
	script_set = null
	if not enabled or game == null:
		return
	var vis: Variant = game.get_meta(META) if game.has_meta(META) else null
	if not vis is Object or not (vis as Object).has_method(&"native_dict") or not bool((vis as Object).call(&"is_ready")):
		return
	script_set = vis
	if not native:
		active = vis
		return
	if not GSSim.has(&"pvs"):
		return
	if _native == null:
		_native = ClassDB.instantiate(&"GSSimPvs")
	if int(_native.call(&"serial")) != int(script_set.get("serial")):
		if not bool(_native.call(&"load", script_set.call(&"native_dict"))):
			return
	active = _native


## Whether a sight from [param from] to [param to] still needs its ray (false: the PVS rules it out). Worker safe.
func open(from: Vector3, to: Vector3) -> bool:
	var seen: bool = active.visible(from, to)
	if verify and active != script_set and bool(script_set.visible(from, to)) != seen:
		_count(3)
	if counting:
		_lock.lock()
		stats[0] += 1
		if not seen:
			stats[1] += 1
		_lock.unlock()
	return seen


## With [member verify], [param seen] is the ray's answer for a pair the set ruled out: counted when clear.
static func ruled_out_but(seen: bool) -> void:
	if seen:
		_count(2)
