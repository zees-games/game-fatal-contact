extends RefCounted

## The pack's per-map download groups (`groups.json`): a map's baked light and bot rides. A client joins with the group of the map being played (the server reports it with the map) and tops
## up the next map's group on a change, so a player never downloads the other maps' files. A server and a solo host ask for every group. Built in, or on a gs-cloud before API 22, there is nothing to fetch.

const CHANNEL := "arena.content"

const FcPaths := preload("fc_paths.gd")
const PREFIX := "map-"


## The group holding [param map_id]'s files; a map with none of its own simply has an empty group.
static func group_for(map_id: StringName) -> String:
	return PREFIX + String(map_id)


## The groups a server reports beside [param map_id] (gs-server's `set_current_map`).
static func groups_for(map_id: StringName) -> PackedStringArray:
	return PackedStringArray([group_for(map_id)]) if map_id != &"" else PackedStringArray()


## Fetches and mounts [param map_id]'s group into this game's mounted pack before the level is built.
## Never fatal: a map without its bake still draws, so a failure is logged and the change goes on.
static func top_up(map_id: StringName) -> GSResult:
	var root := FcPaths.root()
	var cloud: Object = GSRegistry.get_service(GSMapLoader.CLOUD_SERVICE)
	if map_id == &"" or root == "res://" or cloud == null or not cloud.has_method(&"ensure_groups_at"):
		return GSResult.success(false)
	var got: GSResult = await cloud.call(&"ensure_groups_at", root, groups_for(map_id))
	if not got.ok:
		GSLog.warn(CHANNEL, "could not fetch the map's files", {"map": String(map_id), "why": got.error.message})
		return got
	return GSResult.success(true)
