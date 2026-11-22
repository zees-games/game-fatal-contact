extends RefCounted

## How deep a point sits inside a weapon part's mesh, for anim_review's "forearm inside weapon" check.
##
## The part's box alone is not the part: a one-mesh gun (the smg's mac10: receiver, grip and magazine in one mesh) is an L
## whose box takes in the air under the receiver behind the grip, exactly where the hand's wrist and forearm belong, and
## read 0.04-0.06 m "inside" on every frame the hand held the grip. A point counts as inside only when the mesh closes
## round it: a ray along each of the six axes hits one of its faces. Its depth is the shortest of those six hits, in
## metres ([param scale] is the part's world scale per axis).

const AXES: Array[Vector3] = [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.BACK, Vector3.FORWARD]

static var _faces: Dictionary = {}


## Depth (metres) of [param p], in [param mesh]'s own space, inside the mesh; 0 outside its box or where a ray escapes.
static func depth(mesh: Mesh, p: Vector3, scale: Vector3) -> float:
	if mesh == null or not mesh.get_aabb().has_point(p):
		return 0.0
	var faces := faces_of(mesh)
	var deepest := INF
	for axis in AXES:
		var near := INF
		for i in range(0, faces.size() - 2, 3):
			var hit: Variant = Geometry3D.ray_intersects_triangle(p, axis, faces[i], faces[i + 1], faces[i + 2])
			if hit != null:
				near = minf(near, ((hit as Vector3) - p).length())
		if near == INF:
			return 0.0
		deepest = minf(deepest, near * absf((axis * scale).length()))
	return deepest


## The mesh's triangles (cached per mesh: anim_review asks for every arm point on every frame).
static func faces_of(mesh: Mesh) -> PackedVector3Array:
	var id := mesh.get_rid()
	if not _faces.has(id):
		_faces[id] = mesh.get_faces()
	return _faces[id]

