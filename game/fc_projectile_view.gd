extends Node3D

const FcProjectiles := preload("fc_projectiles.gd")

## Every rocket and grenade the game is flying, drawn. Client side.
##
## [b]Nothing drew them, offline or connected.[/b] `FcProjectiles` flew every rocket
## correctly on the authority and the only thing anybody saw was the splash damage — a
## launcher that fired nothing visible and a grenade that was a number going down. This
## reads the same list the simulation advances, once a frame, and moves one node per
## entry; it writes nothing back, so dropping it changes no outcome.
##
## A grenade is its own model from fc-weapons' art table, turned and scaled the way
## the pack draws it in a hand. A launcher's round is the launcher's own missile
## (`AwMissileArt`, fc-weapons level 27) with a glow at its tail; anything without one, or
## an older pack, is a small hot sphere with a light, which is also what reads at forty metres. On a networked client the list is the copies the server's LAUNCH
## events started, flown by `FcNetBridge.client_tick`.

## The round's radius in metres, and its glow.
const ROUND_RADIUS := 0.11
const ROUND_COLOUR := Color(1.0, 0.62, 0.22)

## fc-weapons' per-launcher missile art and the level that has it.
const MISSILE_ART := "res://addons/fc_weapons/art/aw_missile_art.gd"
const MISSILE_LEVEL := 27

## A grenade's fuse light.
const FUSE_COLOUR := Color(1.0, 0.18, 0.12)

## The layer whose list is drawn. Re-pointed by the client whenever the game builds a new
## one, which a map change does.
var projectiles: FcProjectiles = null

## One drawn node per flying entry, keyed by the entry.
var _drawn: Dictionary = {}

var _round_mesh: SphereMesh = null
var _round_material: StandardMaterial3D = null
var _missile_art: Script = null
## Weapon id -> the built missiles kept off the tree for the next shot (a spent one is taken back, so a shot copies nothing).
var _missiles: Dictionary = {}
## Weapon ids whose missile could not be built, so they are not tried again.
var _missile_failed: Dictionary = {}


func _notification(what: int) -> void:
	# The kept missiles are off the tree, so nothing else frees them.
	if what == NOTIFICATION_PREDELETE:
		for spare: Variant in _missiles.values():
			for node: Variant in spare:
				(node as Node).free()
		_missiles.clear()


func _ready() -> void:
	# Top level, so the world's position is the only one: a parent that moved would carry
	# every grenade in the air with it.
	top_level = true
	if GSAddonApi.build_level("fc_weapons") >= MISSILE_LEVEL:
		_missile_art = load(MISSILE_ART) as Script


func _process(_delta: float) -> void:
	present()


## Moves every drawn node to where its entry is, adding and freeing as they come and go.
## Public so a suite can step it with no frame.
func present() -> void:
	var live: Array = projectiles.flying() if projectiles != null else []
	var seen := {}

	for f: FcProjectiles.Flying in live:
		seen[f] = true
		var node: Node3D = _drawn.get(f)

		if node == null:
			node = _make(f)
			add_child(node)
			_drawn[f] = node

		node.global_position = f.position

		# A rocket points where it is going; a grenade tumbles, which is what a thrown
		# object does and what tells a watcher it is not a rocket.
		if f.spawn.fuse_ticks <= 0 and f.velocity.length_squared() > 0.01:
			node.look_at(f.position + f.velocity, _up_for(f.velocity))
		elif not f.resting:
			node.rotate_x(0.2)

	for f in _drawn.keys():
		if not seen.has(f):
			_release(f)


func drawn_count() -> int:
	return _drawn.size()


## Drops everything drawn: a map change, the client leaving.
func clear() -> void:
	for f in _drawn.keys():
		_release(f)


## Frees the drawn node of [param f], taking its missile back for the next shot.
func _release(f: Variant) -> void:
	var node := _drawn[f] as Node3D
	if node.has_meta(&"missile"):
		var missile := node.get_meta(&"missile") as Node
		node.remove_child(missile)
		(_missiles[node.get_meta(&"missile_id")] as Array).append(missile)
	node.queue_free()
	_drawn.erase(f)


func _make(f: FcProjectiles.Flying) -> Node3D:
	var root := Node3D.new()
	root.name = "Projectile"

	# A launcher's own missile (fc-weapons level 27), nose along the flight: the shot reads as the weapon fired it.
	var missile := _missile(f.spawn.id)
	if missile != null:
		root.add_child(missile)
		root.set_meta(&"missile", missile)
		root.set_meta(&"missile_id", f.spawn.id)
		root.add_child(_fuse_light() if f.spawn.fuse_ticks > 0 else _exhaust_light())
		return root

	var art: Variant = AwWeaponArtTable.table().get(f.spawn.id)

	if f.spawn.fuse_ticks > 0 and art is AwWeaponVisual and (art as AwWeaponVisual).has_model():
		var model := AwModelCache.instantiate((art as AwWeaponVisual).model_path)

		if model != null:
			# The hand's turn and scale, without the hand's offset: the origin is the
			# grenade's own, and the entry's position is where it is.
			var placed := (art as AwWeaponVisual).world_transform()
			placed.origin = Vector3.ZERO
			model.transform = placed
			root.add_child(model)
			root.add_child(_fuse_light())
			return root

	root.add_child(_round())
	return root


## fc-weapons' `AwMissileArt` model for [param weapon_id], or null: below level 27, for a weapon without a
## missile of its own, or when its model is not loaded. Reached by path; FC's floor is below 27.
func _missile(weapon_id: StringName) -> Node3D:
	if GSAddonApi.build_level("fc_weapons") < MISSILE_LEVEL:
		return null
	if _missile_art == null or _missile_failed.has(weapon_id) or not bool(_missile_art.call(&"has_missile", weapon_id)):
		return null
	var spare: Array = _missiles.get(weapon_id, [])
	_missiles[weapon_id] = spare
	if not spare.is_empty():
		return spare.pop_back() as Node3D
	var built: Variant = _missile_art.call(&"build", weapon_id)
	if built is Node3D:
		return built as Node3D
	_missile_failed[weapon_id] = true
	return null


## The motor's glow behind a flying missile: the hot round's light, moved to its tail.
func _exhaust_light() -> OmniLight3D:
	var light := OmniLight3D.new()
	light.name = "Exhaust"
	light.light_color = ROUND_COLOUR
	light.light_energy = 1.6
	light.omni_range = 4.0
	light.position = Vector3(0.0, 0.0, 0.45)
	light.shadow_enabled = false
	return light


## A lit fuse: a small red light on a grenade.
##
## [b]Because the grenade alone could not be seen.[/b] Rendered, a frag resting fourteen
## metres away was two or three brown pixels on a grey floor — the size it really is, and
## a grenade nobody can see is one nobody can get away from, which is the only decision a
## grenade exists to force. The light lands on the floor round it, which is what the eye
## finds.
func _fuse_light() -> OmniLight3D:
	var light := OmniLight3D.new()
	light.name = "Fuse"
	light.light_color = FUSE_COLOUR
	light.light_energy = 2.2
	light.omni_range = 1.6
	light.position = Vector3(0.0, 0.15, 0.0)
	light.shadow_enabled = false
	return light


## The round's mesh and material, built now for a draw under the loading cover (GSLoadGate.warm_up): the first
## launcher shot compiled them, 34 ms and 4 pipelines on a GPU box.
func warm() -> Array:
	_round_assets()
	return [_round_mesh, _round_material]


## A small hot sphere with a light: a launcher's round, or anything without a model.
func _round() -> Node3D:
	_round_assets()
	var holder := Node3D.new()

	var mesh := MeshInstance3D.new()
	mesh.mesh = _round_mesh
	mesh.material_override = _round_material
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(mesh)

	var light := OmniLight3D.new()
	light.light_color = ROUND_COLOUR
	light.light_energy = 1.6
	light.omni_range = 4.0
	holder.add_child(light)

	return holder


func _round_assets() -> void:
	if _round_mesh != null:
		return
	_round_mesh = SphereMesh.new()
	_round_mesh.radius = ROUND_RADIUS
	_round_mesh.height = ROUND_RADIUS * 2.0
	_round_material = StandardMaterial3D.new()
	_round_material.albedo_color = ROUND_COLOUR
	_round_material.emission_enabled = true
	_round_material.emission = ROUND_COLOUR
	_round_material.emission_energy_multiplier = 3.0
	_round_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED


static func _up_for(direction: Vector3) -> Vector3:
	return Vector3.RIGHT if absf(direction.normalized().dot(Vector3.UP)) > 0.99 else Vector3.UP
