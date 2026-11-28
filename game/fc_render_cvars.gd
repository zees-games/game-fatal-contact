## Client cvars for addon-side draw and tick folds: the map's per-cell world shadow casters
## (gs-map's GSMapWorldShadow) and the held guns' one shared ticker (fc-weapons' AwWorldModel).
extends RefCounted

## By path: an older gs-map has no world shadow fold, and then these cvars do nothing.
const WORLD_SHADOW := "res://addons/gs_map/bsp/gs_map_world_shadow.gd"

## r_world_shadow: one shadow caster per cell of world chunks instead of one per chunk.
static var world_shadow := true
## r_world_shadow_cell: the cell edge, metres.
static var world_shadow_cell := 32.0
## cl_held_central_tick: every held gun ticked from one node rather than its own _process.
## On: one engine dispatch and one loop for every held gun instead of a `_process` each, which is untimed
## per-node time (arena.pf_nodes self) that grows with the player count. 0 hands each gun its own _process back.
static var held_central_tick := true


## Pushes every value at its addon. Safe to call again; a map already drawn keeps its casters.
static func apply() -> void:
	var shadow := _world_shadow_script()
	if shadow != null:
		shadow.call(&"configure", world_shadow, world_shadow_cell)
	if (AwWorldModel as Script).get(&"central_tick") != null:
		(AwWorldModel as Script).set(&"central_tick", held_central_tick)


static func add_vars(local: GSConsoleLocal) -> void:
	local.add_var(&"r_world_shadow", "1 casts the map's world shadows from one mesh per cell of chunks (fewer shadow draws); 0 one per chunk. Takes effect on the next map.",
		func() -> Variant: return 1 if world_shadow else 0,
		func(v: Variant) -> Variant:
			world_shadow = str(v).strip_edges() != "0"
			apply()
			return GSResult.success(1 if world_shadow else 0)
	)
	local.add_var(&"r_world_shadow_cell", "Edge of a world shadow cell, metres (32 is the default). Takes effect on the next map.",
		func() -> Variant: return world_shadow_cell,
		func(v: Variant) -> Variant:
			var text := str(v).strip_edges()
			if not text.is_valid_float() or text.to_float() <= 0.0:
				return GSResult.fail(GSError.CODE_INVALID, "r_world_shadow_cell takes metres above 0")
			world_shadow_cell = text.to_float()
			apply()
			return GSResult.success(world_shadow_cell)
	)
	local.add_var(&"cl_held_central_tick", "1 ticks every player's held gun from one node; 0 lets each gun run its own frame.",
		func() -> Variant: return 1 if held_central_tick else 0,
		func(v: Variant) -> Variant:
			held_central_tick = str(v).strip_edges() != "0"
			apply()
			return GSResult.success(1 if held_central_tick else 0)
	)


static func _world_shadow_script() -> Script:
	if not ResourceLoader.exists(WORLD_SHADOW):
		return null
	return load(WORLD_SHADOW) as Script
