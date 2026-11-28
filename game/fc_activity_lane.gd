extends RefCounted
## The players' last-active column (cvar sv_native_activity, docs/native-server-tick.md): the batched players'
## loop notes the whole roster's activity in one gs-sim call ([code]GSSimServerTick.activity_note[/code], API 7)
## instead of one [code]GSMatch.note_activity[/code] (a scoreboard lookup and a write) per player per tick.
## The notes reach the score records only when gs-match's idle check could tell them apart (before
## [code]match_node.tick[/code]), when a player leaves, and when the lane is switched off: every write of a
## record's last_active_tick is the current tick, so [code]max(record, noted)[/code] is what the record would
## hold had every note gone straight to it, and the idle check sees the same records on the ticks it reads them.

const FcNativePhases := preload("fc_native_phases.gd")

## cvar sv_native_activity: 1 notes through the column, 0 through GSMatch.note_activity (the fallback).
static var enabled := true

var _native: Object = null
var _missing := false
## The roster ids as the column takes them, rebuilt when player_ids() hands a new array.
var _ids := PackedInt64Array()
var _ids_src: Array[int] = []
## Whether this tick's batched loop notes through the column ([method begin]).
var active := false
## The latest tick noted or checked; whether notes wait in the column.
var _now := 0
var _pending := false


## Decides this tick's path; writes back every pending note when the lane was switched off.
func begin(match_node: GSMatch) -> void:
	active = enabled and _lane_ready()
	if not active and _pending:
		flush(match_node)


## With the lane on this tick, notes ids[i] active at [param tick] for every rows[i] that is not -1 (the loop's
## "no tick" marker); counts the dispatch either way.
func note(ids: Array[int], rows: PackedInt32Array, tick: int) -> void:
	FcNativePhases.tally(FcNativePhases.PLAYERS, active)
	if not active:
		return
	if not is_same(ids, _ids_src):
		_ids_src = ids
		_ids = PackedInt64Array(ids)
	_native.activity_note(_ids, rows, tick)
	_now = tick
	_pending = true


## Before gs-match's idle check: writes the notes it could misjudge without them.
func hand_over(match_node: GSMatch, tick: int) -> void:
	if _native == null:
		return
	var config := match_node.config
	if config.idle_seconds <= 0.0 or match_node.state != GSMatch.State.LIVE:
		return
	var threshold := int(config.idle_seconds * float(config.tick_rate))
	_now = tick
	_write(match_node, _native.activity_due(tick, threshold))


## Before gs-match forgets the player: its pending note into its record.
func leave(match_node: GSMatch, id: int) -> void:
	if _native == null:
		return
	var noted: int = _native.activity_take(id)
	if noted >= 0:
		_write_one(match_node, id, noted)


## Every pending note into the records (tests, the off switch, and a match (re)start, before its ticks
## count from the start again).
func flush(match_node: GSMatch) -> void:
	if _native != null and _pending:
		_write(match_node, _native.activity_flush())
		_pending = false


func _write(match_node: GSMatch, pairs: PackedInt64Array) -> void:
	for i in range(0, pairs.size(), 2):
		_write_one(match_node, pairs[i], pairs[i + 1])


func _write_one(match_node: GSMatch, id: int, noted: int) -> void:
	var record := match_node.scoreboard.find(str(id))
	# Later than now: stamped before a restart, which the script's next note overwrites.
	if record != null and (record.last_active_tick < noted or record.last_active_tick > _now):
		record.last_active_tick = noted


func _lane_ready() -> bool:
	if _native != null:
		return true
	if _missing:
		return false
	if not (ClassDB.class_exists(&"GSSimServerTick") and ClassDB.class_has_method(&"GSSimServerTick", &"activity_note")):
		_missing = true
		GSLog.warn(FcNativePhases.CHANNEL, "sv_native_activity: gs-sim lacks GSSimServerTick.activity_note (API 7); activity notes stay in script")
		return false
	_native = ClassDB.instantiate(&"GSSimServerTick")
	return true
