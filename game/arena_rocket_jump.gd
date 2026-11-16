extends RefCounted

## The rocket launchers' server cvars (`sv_rocket_*`) and the Rocketjump warhead, on FC's side.
##
## fc-weapons (API level 27) owns the numbers and the maths: `AwRocketRules` holds the single-missile launcher's
## tube and blast and the Rocketjump's damage cut and launch, `AwRocketJump.launch_velocity` says where a blast
## throws its own shooter. This file is the glue: it re-applies the cvars to the shared weapon and attachment
## catalogues when they change, gives a Rocketjump blast a self-damage scale of its own, and turns the launch
## velocity into a push on the shooter's controller.
##
## [b]Everything is reached by path.[/b] FC's floor for fc-weapons is below 27 (it may not be above the shell's
## pin), so the classes are never named here: below 27 the files do not exist and every function is a no-op.
##
## [b]Server only.[/b] The push is applied on the authority, before the shooter's next motor step; a client sees
## it through the snapshot correction, not predicted.

const MIN_LEVEL := 27

const RULES_PATH := "res://addons/arena_weapons/aw_rocket_rules.gd"
const JUMP_PATH := "res://addons/arena_weapons/aw_rocket_jump.gd"

## The def param the warhead fits (`AwRocketJump.PARAM`), and the attachment's id.
const PARAM := &"rocketjump"
const ATTACHMENT := &"rocketjump"

## Where a body's middle is, as a share of the eye height above the feet: what the blast pushes on.
const BODY_CENTRE := 0.5

static var _jump: Script = null

## Self-scaled copies of a damage type, by "<base instance id>:<scale>": one per type and cvar value.
static var _types: Dictionary = {}


static func supported() -> bool:
	return DotAddonApi.build_level("arena_weapons") >= MIN_LEVEL and ResourceLoader.exists(RULES_PATH)


## A fresh `AwRocketRules` at its defaults, or null below level 27.
static func make_rules() -> RefCounted:
	if not supported():
		return null
	return (load(RULES_PATH) as Script).new() as RefCounted


static func is_rocketjump(def: DotWeaponDef) -> bool:
	return def != null and bool(def.params.get(PARAM, false))


## Puts [param rules] on every launcher def in [param catalogue] and the Rocketjump's damage cut on its
## attachment in [param attachments]. Run on bind and on every `sv_rocket_*` change; a weapon already fitted
## in somebody's hands keeps the numbers it was fitted with until it is fitted again (a respawn).
static func apply_rules(rules: RefCounted, catalogue: DotWeaponCatalogue, attachments: DotWeaponAttachments) -> void:
	if rules == null:
		return

	if catalogue != null:
		for id in catalogue.ids():
			rules.call(&"apply", catalogue.get_def(id))

	if attachments != null:
		var warhead := attachments.get_attachment(ATTACHMENT)
		if warhead != null:
			var cut := float(rules.get(&"jump_damage_scale"))
			warhead.scale = {"damage": cut, "splash_damage": cut}


## [param base] with its self-damage scaled by [param scale]: what a Rocketjump blast hurts its shooter with.
## `sv_rocket_jump_self_damage_scale` 0 (the default) makes it 0, which dot-combat refuses outright.
static func self_scaled_type(base: DotDamageType, scale: float) -> DotDamageType:
	if base == null:
		return null

	var key := "%d:%s" % [base.get_instance_id(), scale]
	var held: DotDamageType = _types.get(key)

	if held == null:
		held = base.duplicate() as DotDamageType
		held.self_scale = base.self_scale * scale
		_types[key] = held

	return held


## The self-damage multiplier for a blast from [param def]: the cvar for a Rocketjump, 1 for anything else.
static func self_damage_scale(def: DotWeaponDef, rules: RefCounted) -> float:
	if rules == null or not is_rocketjump(def):
		return 1.0
	return float(rules.get(&"jump_self_damage_scale"))


## Throws [param player] off their own blast at [param at]: `AwRocketJump.launch_velocity` with their body's
## middle, whether they stand on the floor, and their move input turned by their view. Returns whether it pushed.
static func launch(player: Node, def: DotWeaponDef, rules: RefCounted, at: Vector3) -> bool:
	if player == null or def == null or rules == null or not supported():
		return false

	var controller: DotFpsController = player.get(&"controller")
	if controller == null:
		return false

	var state := controller.state
	var centre := state.position + Vector3.UP * float(player.call(&"eye_height")) * BODY_CENTRE
	var on_floor := state.mode == DotFpsState.Mode.GROUND
	var after: Vector3 = _jump_script().call(
		&"launch_velocity", def, rules, state.velocity, centre, at, on_floor, move_direction(controller)
	)

	if after.is_equal_approx(state.velocity):
		return false

	controller.apply_external_velocity(after - state.velocity)
	return true


## The world direction [param controller]'s last command asked to move in (not normalised; zero standing still).
static func move_direction(controller: DotFpsController) -> Vector3:
	var command := controller.current_command
	if command == null or command.move == Vector2.ZERO:
		return Vector3.ZERO

	var forward := DotFpsMotor.forward_for(controller.state.yaw)
	var right := forward.cross(Vector3.UP)
	return right * command.move.x + forward * command.move.y


static func _jump_script() -> Script:
	if _jump == null:
		_jump = load(JUMP_PATH) as Script
	return _jump
