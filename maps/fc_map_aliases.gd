extends RefCounted

## Map ids this game used to ship under, and the ids they carry now.
##
## The `dm_`, `cp_` and `gg_` prefixes were dropped from the ids of the built-in maps. A saved setting, a server's
## rotation file or a launch argument may still name the old one, so every id the game is handed from outside goes
## through [method resolve] first. An old id is logged the first time it is seen, so a stale setting shows up.
## Delivered maps keep their published ids until their packs are republished under the new ones; add each to
## [constant IDS] when that happens.

## Old id -> current id.
const IDS := {
	&"dm_box": &"box",
	&"dm_atrium": &"atrium",
	&"dm_pit": &"pit",
}

## Old ids already logged, so a hot path does not repeat the line.
static var _warned: Dictionary = {}


## The current id for [param id]: itself unless it is an old one (hyphens or underscores, as ids are written both ways).
static func resolve(id: StringName) -> StringName:
	var now: Variant = IDS.get(id)
	if now == null and str(id).contains("-"):
		now = IDS.get(StringName(str(id).replace("-", "_")))
	if now == null:
		return id
	if not _warned.has(id):
		_warned[id] = true
		push_warning("map id '%s' is the old name of '%s'; using '%s'" % [id, now, now])
	return now


## [method resolve] for a string, "" staying "".
static func resolve_text(id: String) -> String:
	return id if id == "" else str(resolve(StringName(id)))
