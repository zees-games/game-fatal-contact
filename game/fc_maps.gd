extends "fc_maps_catalogue.gd"


# --- Delivered: the maps the server names --------------------------------

## Where gs-cloud mounts every pack. gs-cloud's own constant, spelled out so this file
## parses in a build that does not link it.
const MOUNT_ROOT := "res://gs_cloud/"


## Pack key -> why it failed: a delivered map whose fetch or mount failed this session, for ANY reason
## (404, a browser's opaque "Failed to fetch" with status 0, another HTTP error, a pack missing files it
## declares). It leaves the solo list and is not asked for again, so a dead key is one line, not a loop.
static var _dead_keys: Dictionary = {}


## The pack keys (`<owner>/<map id>@<version>`) the server names for the running game:
## [code]server.games.current_maps()[/code], which gs-server-deploy's `cfg/content.yml`
## fills. Duck-typed, so a gs-server that predates the field — or a stand-in in a suite —
## is an empty list rather than a parse error.
##
## [b]Not gs-game's `GSGameContent.map_keys`[/b], which says the same thing, because this
## game does not link gs-game: its module is a `GSModule`, and pulling an addon into the
## client shell's dependency list for six lines of duck typing is the wrong trade.
static func server_map_keys(server: Object) -> PackedStringArray:
	var out := PackedStringArray()
	var games: Variant = server.get("games") if server != null else null

	if not (games is Object) or not (games as Object).has_method("current_maps"):
		return out

	for key: Variant in (games as Object).call("current_maps"):
		if not out.has(str(key)):
			out.append(str(key))

	return out


## The deathmatch and gun game packs a game with no server (solo, offline) lists, as keys.
# The ONE table of maps a solo player is offered (edit only this list to swap versions). Pinned to the versions production has.
# Temporarily left out while their packs ship pakfile-decoded textures (asset check 2026-11-07): dm-hot-cn-v1, dm-morpheus,
# dm-industrial-gamma, gg-simpsons-x, gg-lego-arena, gg-krusty-krab, gg-canyon, gg-punishment, gg-woods and 21 surf maps; they come
# back with their stripped versions. blackhawkdown and welcometomexicov6 are out too: prod only has a hollow 1.0.1. A pinned version
# a CDN lacks is retried at its latest.json in solo (dev has 1.0.4 and no 1.0.3).
const STANDALONE_KEYS: PackedStringArray = [
	"gamemann/aim-forts@1.0.5",
	# cp-orange-x3: stripped pack (every texture/model mapped to CC0, check_packs clean) from fc-dm-maps v1.0.10: CC0 brick walls and concrete stairs (no stair-step brick), grey/orange floors (gs-map-convert 2442296); member of asset 116.
	"gamemann/cp-orange-x3@1.0.10",
	"gamemann/crackhouse@1.0.5",
	"gamemann/dm-hot-cn-v1@1.0.5",
	"gamemann/dm-industrial-gamma@1.0.5",
	"gamemann/dm-morpheus@1.0.5",
	"gamemann/dm-overwatch@1.0.5",
	"gamemann/dm-scarletdevilmansion@1.0.5",
	"gamemann/gg-canyon@1.0.5",
	"gamemann/gg-fy-snow@1.0.5",
	"gamemann/gg-garage@1.0.5",
	"gamemann/gg-krusty-krab@1.0.5",
	"gamemann/gg-lego-arena@1.0.5",
	"gamemann/gg-punishment@1.0.5",
	"gamemann/gg-simpsons-x@1.0.5",
	"gamemann/gg-woods@1.0.5",
	# The combat surf packs are published as <repo>-<map> (see PACK_PREFIX), at the repo's 1.2.x.
	"gamemann/fc-surf-dm-maps-surf_10x_final@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_10x_reloaded_fixed@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_110b_austinpowers@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_29_12_06@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_adverse@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_akai_final@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_bathroom_final@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_buck_wild@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_dust2_2008_final@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_forbidden_ways_2nd@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_forbidden_ways_reloaded@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_fruits@1.2.4",
	"gamemann/fc-surf-dm-maps-surf_grave_reloaded@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_greatriver@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_greatriver_v4@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_greatriver_xdre4m@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_i_hate_campers@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_japan_ptad@1.2.4",
	"gamemann/fc-surf-dm-maps-surf_legends@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_machine2@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_machine_remix_final@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_mai_remix@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_matrix_v8@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_ny_advance@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_ny_bigloop_2008a@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_parrot_selector@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_pavilion@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_pox@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_rebel_resistance_final3@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_ski_2@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_ski_2_source@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_skyworld@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_snipers_island@1.2.4",
	"gamemann/fc-surf-dm-maps-surf_the_flow@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_the_gloaming@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_thriller@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_torque2@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_velocity@1.2.3",
	"gamemann/fc-surf-dm-maps-surf_xiv_v2a@1.2.4",
]


## The surf packs are published as `gamemann/fc-surf-dm-maps-<map>`; the map's own id (its manifest's) has no prefix.
const PACK_PREFIX := "fc-surf-dm-maps-"


## [constant STANDALONE_KEYS] minus the maps [param catalogue] already has (a linked local
## import wins), so solo play lists the published maps and fetches one when it is picked.
## A pack [param content] already has mounted at another version is named at that version:
## a pinned version can go unpublished, and a mounted pack needs no fetch.
static func standalone_keys(catalogue: GSMapCatalogue, content: GSContentIndex = null) -> PackedStringArray:
	var out := PackedStringArray()
	var mounted := mounted_versions(content if content != null else GSContentIndex.shared())

	for key in STANDALONE_KEYS:
		var def := delivered_def(key)

		if def == null:
			continue

		var have: GSMapDef = catalogue.get_map(def.id) if catalogue != null else null

		if have == null or bool(have.meta.get("delivered", false)):
			var cid := String(def.content_id)
			out.append("%s@%s" % [cid, mounted[cid]] if mounted.has(cid) else key)

	return out


## content id -> version of each pack [param content] lists for the current session; the last mounted wins.
static func mounted_versions(content: GSContentIndex) -> Dictionary:
	var out := {}

	for pack in content.packs():
		out[str(pack.get("content_id", ""))] = str(pack.get("version", ""))

	return out


## A map the server names, as gs-map content: delivered, not downloaded.
##
## [b]Built from the key alone[/b], because nothing else is on the disk yet: these packs are
## a megabyte to five each and a server that fetched every one at boot would sit
## unreachable while it did, so a pack is fetched when the map is changed to
## (`FcMapSession`), as game-airdrift fetches its own. So the def says what the key says
## — id, content id, version — and nothing measured: no spawn count, no size, untagged, so
## the team modes are refused by the existing rule and the box-built modes by `imported`.
##
## [b]The version is the pack's, not the manifest's hash.[/b] A local import is hashed
## because nobody versions a link; a pack is versioned by whoever published it, the server
## named exactly that version, and a client is told it in the announce and fetches it from
## its own origin — so both ends agree on the bytes by construction, and a republish is a
## new version by gs-cloud's rule. Hashing would need the manifest before the fetch.
##
## [b]The scene path is the manifest inside the mount[/b] (`<mount>/<id>.json`): the file
## [FcMap] is built from, and inside the pack's own content — which is what lets a client
## that has never heard of the map accept it (`GSMapSyncClient` takes an unknown map only
## when its scene is under its mount). Null when the key is not `<owner>/<id>@<version>`.
static func delivered_def(key: String) -> GSMapDef:
	var def := GSMapDef.from_content_key(key)

	if def == null or def.content_version == "":
		return null

	if String(def.id).begins_with(PACK_PREFIX):
		def.id = StringName(String(def.id).trim_prefix(PACK_PREFIX))

	def.scene_path = manifest_in_mount(def)
	def.version = def.content_version
	def.display_name = String(def.id)
	def.kind = GSMapDef.KIND_ARENA
	def.author = "unknown"
	def.enabled = in_rotation(def.id)
	def.tier = 1
	def.description = "%s, delivered as %s." % [imported_label(def.id), key]
	def.meta = {
		"builder": "FcMap.by_id",
		"imported": true,
		"delivered": true,
		"key": key,
		"teams": true,
		"movement": "surf",
	}
	return def


## Fetches a delivered map's pack when it is not mounted and gives `FcImportedMaps` its directory, so
## `FcMap.by_id` builds the map from the mounted manifest. Shared by the map session (a server's change)
## and the solo picker. A pack whose manifest is not `"kind": "arena"` is refused and leaves [param catalogue].
static func mount_delivered(
	map: GSMapDef, loader: GSMapLoader, catalogue: GSMapCatalogue = null, allow_latest := false
) -> GSResult:
	var key := str(map.meta.get("key", "%s@%s" % [String(map.content_id), map.effective_content_version()]))

	if FcImportedMaps.is_mounted(map.id) \
			and FcImportedMaps.manifest_path(map.id) == manifest_in_mount(map):
		refresh_delivered_meta(map)
		return GSResult.success(null)

	var first_key := key

	if _dead_keys.has(key):
		if catalogue != null:
			catalogue.remove(map.id)

		return GSResult.fail(GSError.CODE_STATE, "could not load the map %s: %s (not retried this session)" % [String(map.id), _dead_keys[key]])

	var fetched: GSResult = await loader.ensure_content(map)

	if not fetched.ok and allow_latest and fetched.error != null and fetched.error.http_status == 404:
		fetched = await _fetch_latest(map, loader)
		key = str(map.meta.get("key", key))

	if not fetched.ok:
		# Any failure, not only a 404: a browser reports a CORS-less 404 as status 0 ("Failed to fetch"),
		# and a dead key left listed fails every time it is picked.
		var status := fetched.error.http_status if fetched.error != null else 0
		var why := fetched.error.message if fetched.error != null else ""

		if status == 0:
			why = "%s (no usable answer from the server: offline, blocked, or not published)" % why

		mark_dead(first_key, why)
		mark_dead(key, why)

		if catalogue != null:
			catalogue.remove(map.id)

		# The toast shows only the message, so the reason goes into it; the whole chain goes to the log.
		GSLog.warn(CHANNEL, "a delivered map could not be fetched", {"map": String(map.id), "pack": key, "why": str(fetched.error)})
		return fetched.wrap("could not fetch the map %s: %s" % [String(map.id), why])

	var dir := mount_of(map)
	var added := FcImportedMaps.add_mounted(map.id, dir)

	if added.ok:
		var missing := missing_declared_files(dir, FcImportedMaps.manifest(map.id))

		if not missing.is_empty():
			FcImportedMaps.remove_mounted(map.id)
			added = GSResult.fail(
				GSError.CODE_IO, "The delivered map is incomplete.",
				"%d declared file(s) missing, e.g. %s" % [missing.size(), missing[0]]
			)

	if not added.ok:
		if added.error.code == GSError.CODE_INVALID:
			refuse(key, FcImportedMaps.kind_at(manifest_in_mount(map)))

			if catalogue != null:
				catalogue.remove(map.id)
		elif not (fetched.value is bool and not fetched.value):
			# Fetched, but no map document, no mesh, or fewer files than its manifest declares (a hollow pack).
			mark_dead(first_key, added.error.detail)
			mark_dead(key, added.error.detail)

			if catalogue != null:
				catalogue.remove(map.id)

		if added.error.code != GSError.CODE_INVALID:
			return added.wrap("could not load the map %s: %s" % [String(map.id), added.error.message.trim_suffix(".")])

		return added.wrap("%s is not a map this game can build" % key)

	refresh_delivered_meta(map)
	GSLog.info(CHANNEL, "a delivered map is mounted", {"map": String(map.id), "pack": key, "dir": dir})
	return GSResult.success(null)


## Fills a mounted delivered map's listing from its manifest, as `_imported_def_for` does for a linked one: the key alone
## cannot say which modes the map lists or whether it lays an objective, so until then only the modes about the players are offered (team deathmatch among them: every map hosts it).
static func refresh_delivered_meta(def: GSMapDef) -> void:
	var map: FcMap = FcMap.imported(def.id, true) if def != null else null

	if map == null:
		return

	def.meta["spawns"] = map.spawns.size()
	def.meta["teams"] = _has_team_spawns(map)
	def.meta["tagged"] = _has_tagged_sides(map)
	def.meta["modes"] = Array(map.modes)
	def.meta["movement"] = String(map.movement_profile)


## Marks a pack key unusable for the rest of the session.
static func mark_dead(key: String, why: String) -> void:
	_dead_keys[key] = why


static func is_dead(key: String) -> bool:
	return _dead_keys.has(key)


static func clear_dead() -> void:
	_dead_keys.clear()


## Textures the map manifest in [param dir] declares for its surfaces (a lightmap is optional: imports declare one they may lack) that the mount lacks:
## a hollow pack resolves and mounts but has no content. Empty when complete.
static func missing_declared_files(dir: String, manifest: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()

	# A pack that carries its converted world under `worlds/` keeps its textures and lightmaps there.
	if DirAccess.open(dir.path_join("worlds")) != null:
		return out

	var seen := {}

	for surface: Variant in manifest.get("surfaces", []):
		if not surface is Dictionary:
			continue

		for field in ["texture", "texture2"]:
			var tex_name := str((surface as Dictionary).get(field, ""))

			if tex_name.is_empty() or tex_name == "<null>" or seen.has(tex_name):
				continue

			seen[tex_name] = true

			if not FileAccess.file_exists(dir.path_join("textures").path_join(tex_name)):
				out.append("textures/" + tex_name)

	return out


## Solo only: the pinned version is not published, so retry at the pack's `latest.json` version and
## re-point [param map] at it. A server's change never comes here: online both ends use the server's exact version.
static func _fetch_latest(map: GSMapDef, loader: GSMapLoader) -> GSResult:
	var pinned := map.effective_content_version()
	var latest := await latest_version(String(map.content_id))

	if latest == "" or latest == pinned:
		return GSResult.failure(GSError.from_http(404)).wrap("%s@%s and its latest are not published" % [String(map.content_id), pinned])

	var was_version := map.content_version
	var was_scene := map.scene_path
	map.content_version = latest
	map.version = latest
	map.scene_path = manifest_in_mount(map)
	var fetched: GSResult = await loader.ensure_content(map)

	if not fetched.ok:
		map.content_version = was_version
		map.version = was_version
		map.scene_path = was_scene
		return fetched

	map.meta["key"] = "%s@%s" % [String(map.content_id), latest]
	GSLog.info(CHANNEL, "pinned pack not published, using its latest", {"pack": String(map.content_id), "pinned": pinned, "latest": latest})
	return fetched


## The version `<content id>/latest.json` names on the cloud client's origin, or "" when unknown. A client that
## has `latest_version(id)` answers it itself; otherwise the registered client's HTTP bases are asked.
static func latest_version(content_id: String) -> String:
	var cloud: Object = GSRegistry.get_service(GSMapLoader.CLOUD_SERVICE)

	if cloud == null:
		return ""

	if cloud.has_method("latest_version"):
		var own := str(await cloud.call("latest_version", content_id)).strip_edges()
		return "" if own.contains("/") or own.contains("..") else own

	if not cloud.has_method("resolved_http_base_urls"):
		return ""

	var root := (Engine.get_main_loop() as SceneTree).root
	var http := GSHttp.new()
	root.add_child(http)

	for base: String in cloud.call("resolved_http_base_urls"):
		var got: GSResult = await http.get_json("%s/%s/latest.json" % [base.rstrip("/"), content_id])

		if got.ok and got.value is Dictionary:
			var version := str((got.value as Dictionary).get("version", "")).strip_edges()

			if version != "" and not version.contains("/") and not version.contains(".."):
				http.queue_free()
				return version

	http.queue_free()
	return ""


## `res://gs_cloud/<content id>/<version>`, where [param def]'s pack mounts.
static func mount_of(def: GSMapDef) -> String:
	return "%s%s/%s" % [MOUNT_ROOT, String(def.content_id), def.effective_content_version()]


## `<mount>/<id>.json`: the manifest a delivered map is built from.
static func manifest_in_mount(def: GSMapDef) -> String:
	return mount_of(def).path_join("%s.json" % String(def.id))


## Whether [param def] is one of this game's delivered maps: content, and its scene the
## manifest in its own mount. Structural rather than a meta flag, because a def from a host
## carries whatever meta the host wrote; the mount is checked plain by `GSMapSyncClient`.
static func is_delivered(def: GSMapDef) -> bool:
	return (
		def != null and not def.is_local()
		and String(def.content_id).get_file().trim_prefix(PACK_PREFIX) == String(def.id)
		and def.scene_path == manifest_in_mount(def)
	)


## Makes [param catalogue]'s delivered maps the ones [param keys] names: adds each one not
## there (replacing a local import of the same id, because the server named a version and a
## client without the link can only fetch a pack), and removes each delivered map no longer
## named (putting back a local import of that id, when this machine has one). Returns how
## many were added and removed. [param playing] is the map running now: it leaves the
## catalogue like any other, but its mount stays registered, because the running game
## rebuilds its solid from that manifest on a mode change.
##
## [b]A pack already on the disk is checked now[/b]: one whose manifest is not
## `"kind": "arena"` is skipped with one warning. One not fetched yet is checked when it is
## (`FcMapSession`), and leaves the catalogue then. A built-in map's id is never
## replaced: `FcMap.by_id` would build the built-in whatever the catalogue said.
static func adopt_delivered(
	catalogue: GSMapCatalogue, keys: PackedStringArray, playing: StringName = &""
) -> Dictionary:
	var added := 0
	var removed := 0

	if catalogue == null:
		return {"added": 0, "removed": 0}

	var named: Dictionary = {}

	for key in keys:
		var def := delivered_def(key)

		if def == null:
			GSLog.warn(CHANNEL, "a map the server names is not <owner>/<map>@<version>", {"entry": key})
			continue

		if FcMap.ids().has(def.id):
			GSLog.warn(CHANNEL, "a map the server names has a built-in map's id, and is skipped", {
				"pack": key,
			})
			continue

		if _refused_keys.has(key) or _dead_keys.has(key):
			continue

		var on_disk := FcImportedMaps.kind_at(def.scene_path)

		if FileAccess.file_exists(def.scene_path) and on_disk != FcImportedMaps.KIND:
			refuse(key, on_disk)
			continue

		named[def.id] = key
		var existing := catalogue.get_map(def.id)

		if existing != null and str(existing.meta.get("key", "")) == key:
			continue

		var res := catalogue.add(def)

		if res.ok:
			added += 1
		else:
			GSLog.warn(CHANNEL, "a map the server names could not be catalogued", {
				"pack": key, "why": res.error.message,
			})

	for def in catalogue.maps.duplicate():
		if not bool(def.meta.get("delivered", false)) or named.has(def.id):
			continue

		catalogue.remove(def.id)
		removed += 1

		if def.id != playing:
			FcImportedMaps.remove_mounted(def.id)

		var local: FcMap = FcMap.imported(def.id)

		if local != null:
			var _put_back := catalogue.add(_def_for(def.id, local))

	if added > 0 or removed > 0:
		GSLog.info(CHANNEL, "the server's maps are in the catalogue", {
			"added": added, "removed": removed, "named": keys.size(),
		})

	return {"added": added, "removed": removed}


## Records that the pack [param key] is not an arena map, once, with the one warning.
static func refuse(key: String, kind: String) -> void:
	if _refused_keys.has(key):
		return

	_refused_keys[key] = true
	GSLog.warn(CHANNEL, "a map the server names is not an arena map, and is skipped", {
		"pack": key, "kind": kind if kind != "" else "(none)",
	})
