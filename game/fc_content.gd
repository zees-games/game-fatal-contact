extends RefCounted

const Roles := preload("fc_weapon_roles.gd")
const Grenades := preload("fc_grenades.gd")

## The game tier of the profile set: cfg/game/<this>/weapon/<id>.yml.
const GAME_ID := "game-fatal-contact"

## The mount the melee weapon carries for a thrown-knife attachment (FcAttach.BOOMERANG).
const KNIFE_MOUNT := &"grip"

## Every weapon, item, damage type and ruleset the game ships, built in code.
##
## [b]In code rather than as `.tres` files, deliberately, and only for this
## project.[/b] A real game ships resources an artist edits without touching code, and
## every class these build is `@tool`-annotated and inspector-editable for exactly
## that. What a *reference* game wants is the opposite: one file you can read top to
## bottom and see the whole content set, with the reasoning next to the numbers.
##
## [b]The weapons are fc-weapons', and none of them is defined here.[/b] The pack
## defines and draws them; what is left for the game is which of them a loadout may name
## and what each costs, which is below.

## A bullet: what the horde's gunner fires. Not a player weapon's type any more — the
## pack's darts are — but monsters still shoot bullets, so it stays registered.
const DAMAGE_BULLET := &"bullet"
## The pack's explosion type. One id with the pack, so a rocket and a grenade and a
## monster's death blast all answer to the same rule.
const DAMAGE_BLAST := AwWeaponIds.DAMAGE_BLAST
const DAMAGE_FALL := &"fall"
const DAMAGE_WORLD := &"world"
const DAMAGE_STOMP := &"stomp"


# --- Damage types ----------------------------------------------------------

static func bullet() -> GSDamageType:
	var type := GSDamageType.make(DAMAGE_BULLET, "Bullet")
	type.armour_share = 0.5
	type.armour_wear = 1.0
	# Falloff starts well beyond a duel and ends beyond the map's diagonal, so it
	# punishes cross-map plinking without making a mid-range fight feel weak.
	type.falloff_start = 24.0
	type.falloff_end = 60.0
	type.falloff_floor = 0.55
	type.self_scale = 0.0
	return type


static func fall() -> GSDamageType:
	var type := GSDamageType.make(DAMAGE_FALL, "Fall")
	# Armour does not soften a landing, and a fall has no hit group.
	type.armour_share = 0.0
	type.uses_hit_groups = false
	type.self_scale = 1.0
	return type


static func stomp() -> GSDamageType:
	var type := GSDamageType.make(DAMAGE_STOMP, "Stomp")
	type.armour_share = 0.0
	type.uses_hit_groups = false
	return type


static func world() -> GSDamageType:
	var type := GSDamageType.make(DAMAGE_WORLD, "The world")
	type.armour_share = 0.0
	type.uses_hit_groups = false
	return type


## Every damage type the game registers: its own three, and the pack's four.
##
## [b]Built once and shared[/b], and the reason is identity rather than speed. gs-combat
## registers the objects it is handed, and [method weapon_catalogue] hands the SAME objects
## to the pack, so a launcher's splash and the registered "blast" are one rule. Two copies
## built independently would agree today and drift the first time somebody tuned one.
static var _damage: Dictionary = {}
static var _item_catalogue: GSItemCatalogue = null
static var _item_catalogue_generation := -1


static func damage_table() -> Dictionary:
	if _damage.is_empty():
		_damage = AwWeaponDamage.table()
		_damage[DAMAGE_BULLET] = bullet()
		_damage[DAMAGE_FALL] = fall()
		_damage[DAMAGE_WORLD] = world()
		_damage[DAMAGE_STOMP] = stomp()
	return _damage


static func damage_types() -> Array[GSDamageType]:
	var out: Array[GSDamageType] = []
	for type: GSDamageType in damage_table().values():
		out.append(type)
	return out


# --- Weapons ---------------------------------------------------------------
#
# Every duration is in ticks. Seconds would make the pistol fire at two different
# rates on a 64 Hz server and a 128 Hz one, which is two different games — the pack
# says the same and is tuned at this rate.

const TICK_RATE := 66

## What a player spawns with when nothing else says: a knife in the melee slot, so the
## number keys always have something under 1, a pistol and a rifle, and one frag.
##
## [b]A list of ids, not a second table of weapons.[/b] The pack is the only place a
## weapon is defined, and everything this game decides about one is which ids it hands
## out — so a mode that wants shotguns for everybody edits this and nothing else.
const DEFAULT_LOADOUT: Array[StringName] = [
	AwWeaponIds.KNIFE, AwWeaponIds.PISTOL, AwWeaponIds.RIFLE, AwWeaponIds.FRAG,
]


## [constant DEFAULT_LOADOUT] with each weapon resolved by role (a weapon pack may fill a role); the same list when none does.
static func default_loadout() -> Array[StringName]:
	return [Roles.resolve(&"melee"), Roles.resolve(&"secondary"), Roles.resolve(&"primary"), Roles.resolve(&"thrown")]


## The melee weapon every player is guaranteed.
static func melee_id() -> StringName:
	return Roles.resolve(&"melee")

## The slot a fresh spawn is holding: the primary.
const DEFAULT_SLOT := AwWeaponIds.SLOT_PRIMARY


## The pack's weapons, against this game's damage types.
static func weapons() -> Array[GSWeaponDef]:
	Roles.ensure()
	AwWeaponPack.game = GAME_ID
	var out := AwWeaponCatalogue.weapons(damage_table())
	for def in out:
		normalise_slot(def)
		if def.id == melee_id() and not def.mounts.has(KNIFE_MOUNT):
			def.mounts.append(KNIFE_MOUNT)
	return out


static func special_slot() -> int:
	return Roles.special_slot()


static func is_grenade_slot(slot: int) -> bool:
	return Roles.is_grenade_slot(slot)


static func normalise_slot(def: GSWeaponDef) -> void:
	Roles.normalise_slot(def)


## Guns that may only ever sit in the primary slot, whatever slot the pack file asks for.
## The railgun (charge rifle) once landed in the heavy slot 5; every path (give, pickup,
## loadout, catalogue, table) goes through [method weapons], so pinning it here covers all.
const PRIMARY_ONLY: Array[StringName] = [AwWeaponIds.CHARGE_RIFLE]


## True when [param id] must live in the primary slot only.
static func is_primary_only(id: StringName) -> bool:
	return PRIMARY_ONLY.has(id)


## The whole weapon table, validated as one document.
##
## A server checks this at boot, headless, before anybody joins — which is the only
## moment anybody is watching.
static func weapon_catalogue() -> GSWeaponCatalogue:
	Roles.ensure()
	var out := GSWeaponCatalogue.new()
	for def in weapons():
		out.add(def)
	return out


## Weapons by id, for a module that has an item id and needs the weapon.
static func weapon_table() -> Dictionary:
	Roles.ensure()
	var out: Dictionary = {}
	for def in weapons():
		out[def.id] = def
	return out


# --- On the wire -------------------------------------------------------------
#
# A weapon travels as its place in `AwWeaponIds.all()`, plus one, so nothing is 0. The
# same addon is compiled into both ends — the server and the client shell — so the list is
# the same list on both, and a number is five bits where a StringName would be a string.

## Bits a weapon index takes: room for the pack's twenty-seven and four more.
const WEAPON_INDEX_BITS := 6


## [param id]'s wire number, or 0 for nothing and for anything the pack does not define.
static func weapon_index(id: StringName) -> int:
	if id == &"":
		return 0
	return Roles.wire_index(id) + 1


## The weapon [param index] names, or `&""`.
static func weapon_at(index: int) -> StringName:
	var ids := Roles.wire_ids()
	return ids[index - 1] if index >= 1 and index <= ids.size() else &""


## Bits the carried set takes: one per weapon in the pack.
static func carry_bits() -> int:
	return mini(Roles.wire_ids().size(), 62)


## Every bit [method carry_mask] can set.
static func carry_full() -> int:
	return (1 << carry_bits()) - 1


## Whether [method apply_carry] checks in one pass that nothing needs giving or taking before the full
## pass, and [method apply_carry_memo] skips an unchanged arsenal (the [code]net_carry_fast[/code] cvar; off
## is the reference). Either way the arsenal ends up the same.
static var carry_fast := true


## Whether [param arsenal] is ready and carries exactly [param mask].
static func carries_exactly(arsenal: GSWeaponArsenal, mask: int) -> bool:
	return arsenal != null and arsenal.is_ready() and carry_mask(arsenal) == mask & carry_full()


## [method apply_carry] for a caller that applies a mask every frame (a client's own player): [param memo],
## an Array the caller keeps, remembers the arsenal, its gs-weapon [code]revision()[/code] and the mask it
## was last found to carry, and while all three hold nothing is scanned at all (the revision moves on every
## give, take, drop, refit, ammo change and restore). Plain [method apply_carry] without the revision (gs-weapon
## before API 51) or with [member carry_fast] off.
static func apply_carry_memo(arsenal: GSWeaponArsenal, mask: int, memo: Array) -> int:
	if not carry_fast or arsenal == null or not arsenal.has_method(&"revision"):
		return apply_carry(arsenal, mask)
	var id := arsenal.get_instance_id()
	if memo.size() == 3 and memo[0] == id and memo[2] == mask and memo[1] == int(arsenal.call(&"revision")):
		return 0
	var changed := apply_carry(arsenal, mask)
	if carries_exactly(arsenal, mask):
		memo.assign([id, int(arsenal.call(&"revision")), mask])
	else:
		memo.clear()
	return changed


## Everything [param arsenal] carries, one bit per weapon.
static func carry_mask(arsenal: GSWeaponArsenal) -> int:
	if arsenal == null:
		return 0

	# One pass over what is carried, not one `carries` per pack weapon (a dictionary copy and shelf scan
	# per ~30 ids: 123 us of a 201 us pull on PH, every client frame and every server tick per person).
	# `weapons_in` is the arsenal's carried set (the one `carried_weight` sums); a bit set twice is set once.
	var mask := 0
	var bits := carry_bits()

	for s: int in arsenal.slots():
		for w: GSWeaponSlot in arsenal.weapons_in(s):
			var i := Roles.wire_index(w.id())
			if i >= 0 and i < bits:
				mask |= 1 << i

	return mask


## [method carry_mask] the slow way, one `carries` per wire id: what a suite holds the fast one to.
static func carry_mask_by_id(arsenal: GSWeaponArsenal) -> int:
	if arsenal == null:
		return 0
	var mask := 0
	var ids := Roles.wire_ids()
	for i in range(carry_bits()):
		if arsenal.carries(ids[i]):
			mask |= 1 << i
	return mask


## Makes [param arsenal] carry exactly what [param mask] says. Returns how many weapons
## it gave or took.
##
## [b]What a client's arsenal is filled from, and it was filled from nothing.[/b] A
## loadout is resolved from a store on the server, and nothing sent its result, so a
## connected client's own arsenal was empty for the whole of every match: it predicted no
## shot, drew no flash, played no report, its HUD read zero and its number keys selected
## nothing — while the server, which had the weapons, fired them correctly. Takes before
## gives, because a give replaces a slot and a take of the replaced weapon afterwards
## would empty it.
##
## [b]Full magazines on a give[/b]: the ammunition is corrected from the snapshot right
## after, and a weapon given empty would read as a reload the player did not ask for.
##
## [b]One pass first[/b] ([member carry_fast]): an arsenal that already carries [param mask] (the case on
## all but a handful of frames) gives and takes nothing in the full pass either, so [method carry_mask]'s
## one pass over the carried weapons answers instead of two catalogue scans of every wire id (141 us a
## call on PH). headless_roles holds the two ways together over random sequences.
static func apply_carry(arsenal: GSWeaponArsenal, mask: int) -> int:
	if arsenal == null or not arsenal.is_ready():
		return 0
	if carry_fast and carry_mask(arsenal) == mask & carry_full():
		return 0

	var ids := Roles.wire_ids()
	var changed := 0

	for i in range(mini(ids.size(), 62)):
		var def := arsenal.catalogue.get_def(ids[i]) if arsenal.catalogue != null else null
		if def == null:
			continue

		var held := arsenal.slot_at(def.slot)
		if (mask & (1 << i)) == 0 and held != null and held.id() == ids[i]:
			var _taken := arsenal.take(def.slot)
			changed += 1

	for i in range(mini(ids.size(), 62)):
		if (mask & (1 << i)) != 0 and not arsenal.carries(ids[i]):
			if arsenal.give(ids[i]).ok:
				changed += 1

	return changed


# --- Loadout ---------------------------------------------------------------

## Which loadout slot each of the pack's arsenal slots goes in.
##
## [b]`primary` and `secondary` keep the names they had[/b], because a stored loadout is a
## document keyed on slot ids and a player's saved choice should survive this game
## changing its weapons. The heavies go in `primary` with the rifles: a launcher is
## something you carry INSTEAD of a rifle, and the budget is what makes that a choice.
static func loadout_slot_for(slot: int) -> StringName:
	Roles.use_layout()
	if slot == AwWeaponIds.SLOT_MELEE:
		return &"melee"
	if slot == AwWeaponIds.SLOT_SIDEARM:
		return &"secondary"
	if slot == AwWeaponIds.SLOT_PRIMARY:
		return &"primary"
	if is_grenade_slot(slot):
		return &"thrown"
	return &"primary"

## The one item a player has to have unlocked. Everything else is free.
##
## Kept rather than made free with the rest, because it is the only thing exercising
## gs-loadout's entitlement path in this game, and a path nothing exercises is one
## nobody knows still works. The game's entitlement source grants it to everybody.
const PAID_WEAPON := AwWeaponIds.LAUNCHER


## The order a loadout is put in a player's hands: melee, the primary (or heavy), the sidearm,
## the throwable, then gear. NOT the schema's slot order, which is the B menu's (primary first).
##
## [b]Kept as it was before the menu reordered the slots[/b], because the order things are given
## in is the arsenal's own order, which every bot's weapon choice walks: giving the knife third
## moved `headless_bots`' measured reactions (hard slower than medium on the same seed).
static func give_rank(slot: int) -> int:
	Roles.use_layout()
	if slot == AwWeaponIds.SLOT_MELEE:
		return 0
	if slot == AwWeaponIds.SLOT_PRIMARY:
		return 1
	if slot == AwWeaponIds.SLOT_SIDEARM:
		return 2
	return 3 if is_grenade_slot(slot) else 4


## [param entries] (`GSLoadoutManager.resolve`'s) in [method give_rank] order, stably.
static func in_give_order(entries: Array[Dictionary]) -> Array[Dictionary]:
	var ranked: Array[Dictionary] = []
	for rank in range(5):
		for e in entries:
			if give_rank(int(e.get("arsenal_slot", 0))) == rank:
				ranked.append(e)
	return ranked


## The items a loadout can name. One per weapon, plus armour.
##
## Note that the item ids match the weapon ids. That is a convention this game chose,
## not something gs-loadout requires — it is what makes `weapon_table()[item.id]` the
## whole of the mapping, and gs-loadout's `arsenal_slot` hint the whole of the rest.
static func catalogue() -> GSItemCatalogue:
	Roles.ensure()
	# Built once per role table: it rebuilt the whole weapon list twice per call, and a
	# client builds a loadout schema inside a loading frame.
	if _item_catalogue != null and _item_catalogue_generation == Roles.generation:
		return _item_catalogue
	var items: Array[GSItem] = []
	var all_weapons := weapons()

	# Utility grenades are entitled by `sv_grenade_utility`, like the launcher is by the game's source.
	var utility := Grenades.utility_ids(all_weapons)
	for weapon in all_weapons:
		var item := GSItem.make(weapon.id, GSItem.KIND_WEAPON, weapon.id != PAID_WEAPON and not utility.has(weapon.id))
		item.display_name = weapon.display_name
		# One loadout slot per weapon, from the pack's arsenal slot. A knife in the
		# primary slot would be a player who spawns with nothing to shoot.
		item.slots = [loadout_slot_for(weapon.slot)]
		item.tags = weapon.tags.duplicate()
		# Free unless the weapon profile sets `params.loadout_cost`.
		item.cost = int(weapon.params.get(&"loadout_cost", 0))
		items.append(item)

	var armour := GSItem.make(&"armour", GSItem.KIND_EQUIPMENT, true)
	armour.display_name = "Armour"
	armour.slots = [&"gear"]
	armour.cost = 0
	items.append(armour)

	_item_catalogue = GSItemCatalogue.of(items)
	_item_catalogue_generation = Roles.generation
	return _item_catalogue


## The loadout schema: a melee, a sidearm, a primary, a throwable and a gear slot, on a
## points budget that is off unless the server sets one.
##
## Points rather than an explicit list of legal combinations, because "a launcher, or a
## rifle and armour" is a handful of numbers rather than an enumeration that grows as
## the square of the weapon count — and there are twenty-seven weapons now.
static func loadout_schema() -> GSLoadoutSchema:
	# [b]Required, like the throwable below, and that is what puts them in anybody's
	# hands.[/b] gs-loadout's default loadout fills REQUIRED slots only, so as optional
	# slots a player who never chose a loadout spawned with a rifle and a pistol and
	# pressed 5 to nothing — rendered, not reasoned: the grenade was in the class's
	# loadout and the store's default replaced it a frame later. A loadout saved before
	# these slots existed is not refused for lacking them: this game conforms on load
	# (`GSLoadoutConfig.conform_on_load`), and conforming fills an empty required slot
	# with its default before it trims to the budget.
	var melee := GSLoadoutSlot.make(&"melee", true, Roles.resolve(&"melee"))
	melee.display_name = "Melee"
	melee.kinds = [GSItem.KIND_WEAPON]
	melee.arsenal_slot = AwWeaponIds.SLOT_MELEE
	# After the guns: the order is the B menu's, where a player looks for the primary first.
	# Nothing stored depends on it (a loadout is keyed by slot id), and the hand a spawn
	# holds is FcPlayer._better_hand's, not the first slot given.
	melee.order = 22

	var primary := GSLoadoutSlot.make(&"primary", true, Roles.resolve(&"primary"))
	primary.display_name = "Primary"
	primary.kinds = [GSItem.KIND_WEAPON]
	primary.arsenal_slot = AwWeaponIds.SLOT_PRIMARY
	primary.order = 10

	var secondary := GSLoadoutSlot.make(&"secondary", true, Roles.resolve(&"secondary"))
	secondary.display_name = "Secondary"
	secondary.kinds = [GSItem.KIND_WEAPON]
	secondary.arsenal_slot = AwWeaponIds.SLOT_SIDEARM
	secondary.order = 20

	var thrown := GSLoadoutSlot.make(&"thrown", true, Roles.resolve(&"thrown"))
	thrown.display_name = "Grenades"
	thrown.kinds = [GSItem.KIND_WEAPON]
	thrown.arsenal_slot = AwWeaponIds.thrown_slot()
	thrown.order = 25

	var gear := GSLoadoutSlot.make(&"gear")
	gear.display_name = "Gear"
	gear.kinds = [GSItem.KIND_EQUIPMENT]
	gear.order = 30

	var schema := GSLoadoutSchema.of(
		&"arena", [melee, primary, secondary, thrown, gear], catalogue()
	)
	# No point-buy by default; a server sets mp_loadout_budget and per-weapon loadout_cost.
	schema.point_budget = 0
	return schema
