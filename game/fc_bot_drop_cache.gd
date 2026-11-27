extends RefCounted
## The bots' drop table kept from tick to tick (cvar `bot_drops_cache`): gs-bot's world packs it once a
## [member GSBotWorld.contacts_version], so each tick re-read the drop snapshot and re-rated every weapon lying about. While every
## drop rests, none was added, taken, emptied, pushed or put down (the drop layer's signals) and the count holds, the last pack is
## the pack: a frozen body does not move. Off, or with a drop in flight, it packs every tick as before. [member verify] (the
## suites) packs anyway and counts every reused table that differs from the fresh one in [member mismatched].

## Whether the table is kept while the drops stand still (cvar `bot_drops_cache`).
static var enabled: bool = true
## Suites: pack fresh on every reuse too and compare (bit for bit) with the kept table.
static var verify: bool = false
## Ticks that reused the kept table, for the suites.
static var reused: int = 0
## Reused tables a fresh pack differed from ([member verify]); 0 or the cache is wrong.
static var mismatched: int = 0

## The drop layer whose signals bump [member _rev] (a new map brings a new one).
var _layer: GSWeaponDrops = null
var _rev: int = 0
var _packed: Variant = null
var _packed_rev: int = -1
var _packed_count: int = -1


## The drop table [param pack] makes for [param game]'s drops, or the one kept from an earlier tick when nothing about the
## drops changed since.
func table(game: Object, pack: Callable) -> Variant:
	var layer := game.get(&"weapon_drops") as GSWeaponDrops  # perf-lint: allow dynamic_call the world holds its game untyped; once a tick
	if not enabled or layer == null:
		_packed = null
		return pack.call()
	if layer != _layer:
		_watch(layer)
	var n := layer.count()
	var still := layer.active_count() == 0
	if still and _packed != null and _packed_rev == _rev and _packed_count == n:
		reused += 1
		if verify and pack.call() != _packed:
			mismatched += 1
		return _packed
	var packed: Variant = pack.call()
	if still and packed is Array:
		_packed = packed
		_packed_rev = _rev
		_packed_count = n
	else:
		_packed = null
	return packed


## Listens to [param layer]'s changes instead of the last layer's.
func _watch(layer: GSWeaponDrops) -> void:
	_packed = null
	_layer = layer
	# The lambdas hold no reference to this cache's owner: only the box of the revision.
	var bump := _bump
	layer.dropped.connect(func(_id: int, _state: Dictionary, _at: Transform3D, _v: Vector3, _owner: int) -> void: bump.call())
	layer.ammo_changed.connect(func(_id: int, _state: Dictionary) -> void: bump.call())
	layer.removed.connect(func(_id: int, _taker: int) -> void: bump.call())
	layer.pushed.connect(func(_id: int, _at: Transform3D, _v: Vector3, _spin: Vector3) -> void: bump.call())
	layer.settled.connect(func(_id: int, _at: Transform3D) -> void: bump.call())


func _bump() -> void:
	_rev += 1
