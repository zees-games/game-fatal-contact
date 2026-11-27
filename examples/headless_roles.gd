extends Node

const Roles := preload("../game/fc_weapon_roles.gd")
const FcContent := preload("../game/fc_content.gd")
const FcPlayer := preload("../game/fc_player.gd")
const FcModule := preload("../game/fc_module.gd")

## Weapons by role: with no extra pack the own pack (fc_weapons) fills every role on the append-only wire numbers; with a pack
## enabled its weapons join, carry a wire number and survive the round trip, and clearing puts everything back. Skips the pack half unless a
## pack is linked (zz_modern_weapons, or fc_weapons).
##
## [codeblock]
## ./game.sh --no-parse test headless_roles
## [/codeblock]

var _checks := 0
var _failed := 0


func _ready() -> void:
	Roles.clear()
	Roles.scan()
	var has_default := ResourceLoader.exists("res://addons/fc_weapons/spawn_provider.gd")
	_check(Roles.packs.has("fc_weapons") == has_default, "fc_weapons is the default provider exactly when linked")

	# A pack that is not there: the own pack alone fills every role.
	Roles.force_packs = ["not_installed"]
	Roles.scan()
	var own_count := Roles.pack_ids.size()
	_check(Roles.packs == PackedStringArray(["fc_weapons"]), "a missing pack is skipped, the own pack stays: %s" % str(Roles.packs))
	_check(Roles.resolve(&"primary") == AwWeaponIds.RIFLE and Roles.resolve(&"melee") == AwWeaponIds.KNIFE, "the own pack fills the roles")
	_check(FcContent.default_loadout() == FcContent.DEFAULT_LOADOUT, "default loadout is the shipped one")
	_check(Roles.wire_ids().slice(0, AwWeaponIds.all().size()) == AwWeaponIds.all(), "wire ids start with the append-only list")
	_check(own_count > 0 and FcContent.weapons().size() == own_count, "catalogue is the own pack's alone: %d" % own_count)
	_check_groups(false)
	_check_carry_mask()
	_check_carry_parity()

	for dir in ["zz_modern_weapons", "fc_weapons"]:
		if not ResourceLoader.exists("res://addons/%s/spawn_provider.gd" % dir):
			print("  skip  %s is not linked" % dir)
			continue

		Roles.force_packs = [dir]
		Roles.scan()
		var added := Roles.pack_ids.size()
		_check(Roles.packs.has(dir) and added > 0, "%s registered: %d weapons" % [dir, added])
		var table := FcContent.weapon_table()

		for role: StringName in Roles.ROLE_DEFAULT:
			var id := Roles.resolve(role)
			_check(table.has(id), "%s resolves to %s, which the catalogue holds" % [role, id])

		var first := Roles.pack_ids[own_count] if Roles.pack_ids.size() > own_count else Roles.pack_ids[0]
		_check(FcContent.weapon_at(FcContent.weapon_index(first)) == first, "%s round-trips the wire" % first)
		_check(FcContent.weapon_index(first) < (1 << FcContent.WEAPON_INDEX_BITS), "its index fits the field")
		_check(AwWeaponArtTable.table().has(first), "%s has art" % first)
		_check(FcPlayer.weapon_catalogue().ids() == FcContent.weapon_catalogue().ids(), "the shared rig catalogue follows the scan of %s" % dir)
		_check(FcContent.loadout_schema().default_loadout().item_in(&"primary") == Roles.resolve(&"primary"), "the default loadout names the role's weapon")
		_check_groups(dir != "fc_weapons")

		Roles.force_packs = ["not_installed"]
		Roles.scan()
		_check(Roles.pack_ids.size() == own_count and FcContent.weapons().size() == own_count, "clearing leaves the own pack alone")
		_check(FcPlayer.weapon_catalogue().ids() == FcContent.weapon_catalogue().ids(), "the shared rig catalogue follows the clear")

	Roles.clear()
	print("RESULT: ", "PASS" if _failed == 0 and _checks >= 5 else "FAIL", " ", _checks, " checks, ", _failed, " failed")
	get_tree().quit(1 if _failed > 0 else 0)


## `FcContent.carry_mask` (one pass over the carried weapons) against the one `carries` per wire id it replaced, empty, held
## and with a weapon stowed behind another in its slot.
func _check_carry_mask() -> void:
	var arsenal := _carry_arsenal()
	var ids := Roles.wire_ids()
	var by_slot: Dictionary = {}
	for i in range(FcContent.carry_bits()):
		var def := arsenal.catalogue.get_def(ids[i])
		if def != null:
			var row: Array = by_slot.get(def.slot, [])
			row.append(ids[i])
			by_slot[def.slot] = row
	var same := FcContent.carry_mask(arsenal) == FcContent.carry_mask_by_id(arsenal) and FcContent.carry_mask(arsenal) == 0
	var stowed := false
	for slot: int in by_slot:
		for id: StringName in by_slot[slot].slice(0, 2):
			var _given := arsenal.give(id)
		stowed = stowed or arsenal.weapons_in(slot).size() > 1
		same = same and FcContent.carry_mask(arsenal) == FcContent.carry_mask_by_id(arsenal)
	_check(same and stowed and FcContent.carry_mask(arsenal) != 0,
		"carry_mask matches one carries() per wire id, a weapon stowed: %d" % FcContent.carry_mask(arsenal))
	arsenal.free()


func _carry_arsenal() -> GSWeaponArsenal:
	var arsenal := GSWeaponArsenal.new()
	arsenal.max_slots = FcPlayer.MAX_SLOTS
	arsenal.catalogue = FcPlayer.weapon_catalogue()
	arsenal.carry = GSWeaponCarry.new()
	arsenal.carry.slot_capacity = 3
	add_child(arsenal)
	var _set := arsenal.setup()
	return arsenal


## `FcContent.apply_carry_memo` with `carry_fast` (the one-pass check and the revision memo) against the full
## two-pass `apply_carry`, over a seeded run of masks (half of them repeats, as a client sees frame to frame)
## with gives and takes between them that the memo must notice: the same return and the same carry every step.
func _check_carry_parity() -> void:
	var fast := _carry_arsenal()
	var full := _carry_arsenal()
	var ids := Roles.wire_ids()
	var bits := FcContent.carry_bits()
	var rng := RandomNumberGenerator.new()
	rng.seed = 2026_11_26
	var memo: Array = []
	var mask := 0
	var steps := 600
	var mismatches := 0
	var repeats := 0
	var changes := 0
	for step in range(steps):
		var roll := rng.randf()
		if roll < 0.12 and bits > 0:
			var id: StringName = ids[rng.randi_range(0, bits - 1)]
			var _a := fast.give(id)
			var _b := full.give(id)
			continue
		if roll < 0.2:
			var slot := rng.randi_range(0, FcPlayer.MAX_SLOTS - 1)
			var _a := fast.take(slot)
			var _b := full.take(slot)
			continue
		if roll < 0.6:
			mask = 0
			for i in range(bits):
				if rng.randf() < 0.3:
					mask |= 1 << i
		else:
			repeats += 1
		FcContent.carry_fast = true
		var got := FcContent.apply_carry_memo(fast, mask, memo)
		FcContent.carry_fast = false
		var want := FcContent.apply_carry(full, mask)
		FcContent.carry_fast = true
		changes += want
		if got != want or FcContent.carry_mask(fast) != FcContent.carry_mask(full):
			mismatches += 1
			if mismatches <= 3:
				print("  carry step %d mask %d: fast %d -> %d, full %d -> %d" % [step, mask, got,
					FcContent.carry_mask(fast), want, FcContent.carry_mask(full)])
	_check(mismatches == 0 and repeats > 50 and changes > 50,
		"apply_carry fast and memo match the full pass over %d steps (%d repeats, %d changes, %d mismatches)"
		% [steps, repeats, changes, mismatches])
	fast.free()
	full.free()


## The download groups the server announces for fc-weapons (`FcModule.addon_groups`): exactly the catalogue's, or everything
## when a weapon is another pack's ([param foreign]) or fc-weapons predates its groups (API 14).
func _check_groups(foreign: bool) -> void:
	var module := FcModule.new()
	var announced: Array = module.addon_groups().get("fc_weapons", [])
	module.free()
	_check(FcModule.weapon_groups([&"not_a_weapon"]) == ["*"], "an id fc-weapons does not know is announced as every group")

	if foreign or GSAddonApi.build_level("fc_weapons") < 14:
		_check(announced == ["*"], "every group is announced when the catalogue cannot be narrowed: %s" % str(announced))
		return

	var groups: Script = load(FcModule.WEAPON_GROUPS_SCRIPT)
	var ids: Array = []

	for def: GSWeaponDef in FcContent.weapons():
		ids.append(def.id)

	var expected := Array(groups.call("groups_for", ids))
	_check(not announced.is_empty() and announced == expected and not announced.has("*"), "the catalogue's %d weapons are announced as %d groups" % [ids.size(), announced.size()])


func _check(ok: bool, what: String) -> void:
	_checks += 1

	if not ok:
		_failed += 1

	print("  %s  %s" % ["ok  " if ok else "FAIL", what])
