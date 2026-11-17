extends RefCounted

## The materials of a drawn BSP map: textures, role colours, water and the lighting constants they share. Split out of fc_bsp_map.gd for file size.


const FcPaths := preload("../game/fc_paths.gd")


## How many of the generated grid's squares one 64-unit square of UV is. The importer writes UVs for an untextured surface in 64-unit squares, the grid these
## maps are built on. [method FcMap.dev_texture] draws four squares a tile, so a tile is four of those: one grid square on the floor is 64 units, 1.22 m, on every surface.
const GRID_SQUARES_PER_TILE := 4.0

## The colour a surface the importer measured nothing for is drawn, by its role.
const ROLE_COLOURS := {
	"RAMP": Color(0.78, 0.52, 0.30),
	"PLATFORM": Color(0.62, 0.64, 0.68),
	"FLOOR": Color(0.46, 0.48, 0.52),
}

## Lifts the baked darks so geometry stays readable. Airdrift's numbers were 0.10 and no gamma; rendered here on a real GPU, greatriver and dust2 (median lightmap texel about a
## fifth of full) came out near black under a bright sky, so the shade is lifted by a gamma of 0.55 (white stays white) and the floor raised to 0.20.
const AMBIENT := 0.20
const LIGHT_BOOST := 1.35
const LIGHTMAP_LIFT := 0.55
## Higher for a grid surface, which has no darks of its own to lose. See Airdrift's
## `AirdriftBspMap.prototype_ambient`, which was chosen by rendering it.
const PROTOTYPE_AMBIENT := 0.32

## The grid every untextured surface wears, built once per process.
static var _grid: Texture2D = null


## Whether a material name is water: its file name says `water` and it is not a
## waterfall. game-airdrift's AirdriftBspMap.is_water_material; keep the two in step.
static func is_water_material(material: String) -> bool:
	var last := material.to_lower().get_file()
	return last.contains("water") and not last.contains("waterfall")


## Water in the map's own colour where it measured one that is not grey, else the shader's
## teal. See game-airdrift's AirdriftBspMap._water_material.
static func _water_material(s: Dictionary, lightmap: Texture2D) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(FcPaths.rebase("res://maps/fc_bsp_water.gdshader"))
	mat.set_shader_parameter("lightmap_tex", lightmap)
	mat.set_shader_parameter("light_boost", LIGHT_BOOST)
	mat.set_shader_parameter("ambient", AMBIENT)
	mat.set_shader_parameter("lift", LIGHTMAP_LIFT)
	var colour: Variant = s.get("colour", null)
	if colour is Array and (colour as Array).size() >= 3:
		var c := Color(float(colour[0]), float(colour[1]), float(colour[2]))
		if c.s > 0.25 and c.v > 0.04:
			mat.set_shader_parameter("tint", Color(c.r, c.g, c.b, 1.0).lightened(0.15))
	mat.set_meta(&"water", true)
	return mat


static func _material_for(s: Dictionary, dir: String, lightmap: Texture2D) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	# [b]Two shaders, and the opaque one is the default.[/b] Writing ALPHA at all is what puts a spatial shader in the transparent pass, where depth is not written and a map
	# draws through itself (Airdrift shipped every imported map that way). Only a surface the map's own material called translucent gets the shader that writes it.
	mat.shader = load(FcPaths.rebase(
		"res://maps/fc_bsp_translucent.gdshader" if bool(s.get("translucent", false))
		else "res://maps/fc_bsp_lightmapped.gdshader"
	))
	mat.set_shader_parameter("lightmap_tex", lightmap)
	mat.set_shader_parameter("light_boost", LIGHT_BOOST)
	mat.set_shader_parameter("ambient", AMBIENT)
	mat.set_shader_parameter("lift", LIGHTMAP_LIFT)

	var texture_name: Variant = s.get("texture", null)

	if texture_name is String and not (texture_name as String).is_empty():
		var tex := _load_texture(dir.path_join("textures").path_join(texture_name))

		if tex != null:
			mat.set_shader_parameter("albedo_tex", tex)
			mat.set_shader_parameter("tint", Color.WHITE)
			mat.set_shader_parameter("uv_scale", 1.0)

			var second := str(s.get("texture2", ""))

			if not second.is_empty() and second != "<null>" and s.has("alpha_offset"):
				var tex2 := _load_texture(dir.path_join("textures").path_join(second))

				if tex2 != null:
					mat.set_shader_parameter("albedo2_tex", tex2)
					mat.set_shader_parameter("has_albedo2", true)

			return mat

	# [b]Water draws as water[/b] (game-airdrift's rule, see fc_bsp_water.gdshader): the
	# source game's water was never in a map, so a pool was an opaque grid floor a player
	# sank through. A map that shipped its water texture keeps it, above.
	if is_water_material(str(s.get("material", ""))):
		return _water_material(s, lightmap)

	# No texture the map carried: it lived in the source game's own archives, which on a surf map is most of the map. The grid, painted the colour the map's compiler measured
	# for that texture (`colour`), so the map keeps its palette and the grid keeps the scale — a flat fill at surf speed says nothing about how fast it is going past.
	if _grid == null:
		_grid = load(FcPaths.rebase("res://maps/fc_map.gd")).dev_texture(
			128, 32, Color(0.80, 0.80, 0.80), Color(0.52, 0.52, 0.52)
		)

	var tint: Color = ROLE_COLOURS.get(str(s.get("role", "FLOOR")), ROLE_COLOURS["FLOOR"])
	var colour: Variant = s.get("colour", null)

	if colour is Array and (colour as Array).size() >= 3:
		var measured := Color(float(colour[0]), float(colour[1]), float(colour[2]))

		# [b]A measured black is trusted only when the name says black[/b] (Airdrift's rule,
		# learnt by rendering every map): a self-lit panel has no albedo for the compiler to
		# measure, so it reads zero and would draw as a hole. A material named black IS black.
		if measured.get_luminance() > 0.01 or str(s.get("material", "")).to_lower().contains("black"):
			tint = measured

	mat.set_shader_parameter("albedo_tex", _grid)
	mat.set_shader_parameter("tint", tint)
	mat.set_shader_parameter("uv_scale", 1.0 / GRID_SQUARES_PER_TILE)
	mat.set_shader_parameter("ambient", PROTOTYPE_AMBIENT)
	return mat


## A texture through the resource loader, which is the only path an export ships. `Image.load_from_file` on a `res://` path works from source and returns nothing in an
## exported build, because the export carries the imported `.ctex` and not the `.png`. The file read below is the fallback for a map nobody has imported yet.
static func _load_texture(path: String) -> Texture2D:
	if path.is_empty():
		return null

	if ResourceLoader.exists(path):
		var res: Resource = load(path)

		if res is Texture2D:
			return res

	if not FileAccess.file_exists(path):
		return null

	var img := Image.load_from_file(path)

	if img == null:
		return null

	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
