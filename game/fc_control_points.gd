extends RefCounted

## The control point layout: a line of capture points in their map order, the two ends
## owned by the sides, each point open to a side only once it holds the neighbour on its
## own side. Static so the objectives layer, the bots and the HUD share one reading of it
## (docs/control-points.md has the map schema, docs/modes.md the rules).

const FcMap := preload("../maps/fc_map.gd")

const RED := 1
const BLUE := 2

## Half the height of a point's capture cylinder, metres, about its manifest origin.
const HALF_HEIGHT := 2.5

## Capture time of a point on a map that places none (the built-in maps), seconds.
const FALLBACK_SECONDS := 8.0


## The team id a manifest owner tag names: `red` 1, `blue` 2, anything else neutral.
static func team_of_tag(tag: String) -> int:
	match tag:
		"red":
			return RED
		"blue":
			return BLUE
	return 0


## The points of [param map] in order: its own `control_points`, else three along the
## longest axis (red's end at -x, as the flag layout puts red's flag).
static func points_of(map: FcMap) -> Array[Dictionary]:
	if not map.control_points.is_empty():
		return map.control_points
	var reach := maxf(map.extent - 4.0, 4.0)
	var out: Array[Dictionary] = []
	var owners: Array[String] = ["red", "", "blue"]
	for i in owners.size():
		out.append({
			"id": StringName("cp%d" % (i + 1)),
			"name": "Point %d" % (i + 1),
			"at": Vector3(reach * 0.7 * float(i - 1), map.floor_y + 1.0, 0.0),
			"radius": maxf(reach * 0.12, 2.5),
			"order": i + 1,
			"owner": owners[i],
			"seconds": FALLBACK_SECONDS,
		})
	return out


## One capture def per point, locked in a line: red takes point i once it holds i-1,
## blue once it holds i+1. Nothing scores per point; the sweep is the score.
static func build(map: FcMap, rate: int) -> Array[GSObjectiveDef]:
	var out: Array[GSObjectiveDef] = []
	var points := points_of(map)
	var ids: Array[StringName] = []
	for p in points:
		ids.append(p["id"] as StringName)

	for i in points.size():
		var p: Dictionary = points[i]
		var area := GSObjectiveArea.cylinder(p["at"] as Vector3, float(p["radius"]), HALF_HEIGHT)
		var def := GSObjectiveDef.capture(ids[i], area, maxi(roundi(float(p["seconds"]) * rate), 1))
		def.display_name = str(p["name"])
		def.label = str(i + 1)
		def.initial_team = team_of_tag(str(p["owner"]))
		def.capture_required = 1
		def.capture_scales_with_players = true
		def.score_points = 0
		def.player_points = 0
		var needs := {}
		if i > 0:
			needs[RED] = [ids[i - 1]]
		if i < points.size() - 1:
			needs[BLUE] = [ids[i + 1]]
		def.requires_owned = needs
		out.append(def)
	return out


## The capture objectives of [param manager] in line order (the set keeps the build order).
static func line_of(manager: GSObjectiveManager) -> Array[GSObjective]:
	var out: Array[GSObjective] = []
	if manager == null or manager.objectives == null:
		return out
	for obj in manager.objectives.objectives:
		if obj.def != null and obj.def.kind == GSObjectiveDef.Kind.CAPTURE:
			out.append(obj)
	return out


## Whether [param team] may start a capture on [param obj] now (its neighbour rule).
static func open_to(manager: GSObjectiveManager, obj: GSObjective, team: int) -> bool:
	if obj == null or obj.owner_team == team or manager.objectives == null:
		return false
	return manager.objectives.owns_all(team, obj.def.requires_owned_for(team))


## The next point [param team] can take, or null when it holds them all.
static func next_for(manager: GSObjectiveManager, team: int) -> GSObjective:
	for obj in line_of(manager):
		if open_to(manager, obj, team):
			return obj
	return null


## How many points [param team] holds.
static func held_by(manager: GSObjectiveManager, team: int) -> int:
	var n := 0
	for obj in line_of(manager):
		if obj.owner_team == team:
			n += 1
	return n


## The point both sides' bots fight over: one being captured, else the next point of the
## side holding more (red on a tie), so a lead is pushed home rather than stalled.
static func front(manager: GSObjectiveManager) -> GSObjective:
	for obj in line_of(manager):
		if obj.progressing_team() > 0:
			return obj
	var leader := BLUE if held_by(manager, BLUE) > held_by(manager, RED) else RED
	var next := next_for(manager, leader)
	if next == null:
		next = next_for(manager, BLUE if leader == RED else RED)
	return next
