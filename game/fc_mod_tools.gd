extends RefCounted

const FcEffects := preload("fc_effects.gd")
const FcGame := preload("fc_game.gd")
const FcPlayer := preload("fc_player.gd")

## What gs-moderation's live tools mean in a deathmatch.
##
## [b]Every verb here is a few lines, because each is an addon's own seam.[/b] Noclip,
## freeze, speed and gravity are gs-player-controller's `GSFpsAdminModifiers`, which the
## owning client predicts rather than rubber-bands against; god and buddha are two flags on
## gs-combat's `GSHealth`; slay and slap are ordinary `GSDamage` through the combat
## manager, so the kill feed, the scoreboard and the stats hear about them the way they
## hear about a rocket; respawn is the match's own respawn path; burn is gs-effects' own
## burning. Nothing here is a second rule about any of those.
##
## Blind and beacon are the two that are about a SCREEN rather than a body, and each is one
## flag on [FcPlayer] that `FcPlayerNet` replicates — the blind to its owner alone,
## the beacon to everybody — and that the client draws: `FcHud` blacks the owner's
## screen out, `GSFxBeacon` (gs-fx) rings the player on every screen and pings. The server decides;
## nothing about either is a client's to choose.
##
## Ids are the session userid as a string, which is `FcPlayer.player_id` — the one id
## space this game has. See the project's docs/architecture.md.

## The damage type a slay or a slap carries. Empty is gs-combat's generic type, which
## armour does not absorb and nothing multiplies — an admin's slap for 10 is 10.
const WORLD_DAMAGE := &""

## How hard a slap shoves, in m/s. Enough to take somebody off a ledge, not off the map.
const SLAP_PUSH := 6.0
const SLAP_LIFT := 5.0

## The ceiling `hp` sets. Health travels as an 11-bit integer (GSCombatNetSync), so a
## value above 2047 would arrive on the client as something else entirely.
const MAX_HEALTH := 2000.0


## The handler table, `{ability: Callable}`.
static func handlers(game: FcGame) -> Dictionary:
	var table := {
		GSModTools.ACTION_NOCLIP: func(id: StringName, args: Dictionary) -> GSResult:
			var player := _player(game, id)
			if player == null:
				return _absent(id)
			return GSFpsAdminModifiers.set_noclip(player.controller, bool(args["on"])),

		GSModTools.ACTION_FREEZE: func(id: StringName, args: Dictionary) -> GSResult:
			var player := _player(game, id)
			if player == null:
				return _absent(id)
			var on := bool(args["on"])
			# A frozen player cannot shoot either. Held still with a working rifle is a
			# turret, which is the opposite of what a freeze is for.
			if player.is_alive():
				player.arsenal.disabled = on
			return GSFpsAdminModifiers.set_frozen(player.controller, on),

		GSModTools.ACTION_GOD: func(id: StringName, args: Dictionary) -> GSResult:
			var player := _player(game, id)
			if player == null:
				return _absent(id)
			player.health.invulnerable = bool(args["on"])
			return GSResult.success(player.health.invulnerable),

		GSModTools.ACTION_BUDDHA: func(id: StringName, args: Dictionary) -> GSResult:
			var player := _player(game, id)
			if player == null:
				return _absent(id)
			player.health.cannot_die = bool(args["on"])
			return GSResult.success(player.health.cannot_die),

		GSModTools.ACTION_SLAY: func(id: StringName, _args: Dictionary) -> GSResult:
			return slay(game, id),

		GSModTools.ACTION_SLAP: func(id: StringName, args: Dictionary) -> GSResult:
			return slap(game, id, float(args.get("damage", 0.0))),

		GSModTools.ACTION_RESPAWN: func(id: StringName, _args: Dictionary) -> GSResult:
			# The spawn sight queries the physics space: on a server, at the top of the next tick (gs_tick_gate.gd).
			if _player(game, id) == null:
				return _absent(id)
			game.tick_gate.run(game.respawn_player.bind(int(String(id))))
			return GSResult.success(id),

		GSModTools.ACTION_HEALTH: func(id: StringName, args: Dictionary) -> GSResult:
			var player := _player(game, id)
			if player == null:
				return _absent(id)
			if not player.is_alive():
				return GSResult.fail(GSError.CODE_STATE, "They are dead. Respawn them first.")
			player.health.health = minf(float(args["value"]), MAX_HEALTH)
			return GSResult.success(player.health.health),

		GSModTools.ACTION_SPEED: func(id: StringName, args: Dictionary) -> GSResult:
			var player := _player(game, id)
			if player == null:
				return _absent(id)
			return GSFpsAdminModifiers.set_speed(player.controller, float(args["scale"])),

		GSModTools.ACTION_GRAVITY: func(id: StringName, args: Dictionary) -> GSResult:
			var player := _player(game, id)
			if player == null:
				return _absent(id)
			return GSFpsAdminModifiers.set_gravity(player.controller, float(args["scale"])),
	}
	table.merge(_item_handlers(game))
	return table


## The give, strip, rename, burn, blind and beacon handlers.
static func _item_handlers(game: FcGame) -> Dictionary:
	return {
		GSModTools.ACTION_GIVE: func(id: StringName, args: Dictionary) -> GSResult:
			var player := _player(game, id)
			if player == null:
				return _absent(id)
			var item := StringName(str(args["item"]).strip_edges().to_lower())
			if not player.arsenal.catalogue.has(item):
				return GSResult.fail(
					GSError.CODE_INVALID, "There is no weapon called %s." % String(item),
					", ".join(item_ids(game))
				)
			return player.arsenal.give(item),

		GSModTools.ACTION_STRIP: func(id: StringName, _args: Dictionary) -> GSResult:
			var player := _player(game, id)
			if player == null:
				return _absent(id)
			player.arsenal.clear()
			return GSResult.success(null),

		GSModTools.ACTION_RENAME: func(id: StringName, args: Dictionary) -> GSResult:
			var player := _player(game, id)
			if player == null:
				return _absent(id)
			var new_name := str(args["name"]).strip_edges().substr(0, 32)
			player.display_name = new_name
			# The scoreboard keeps its own copy, and a rename that stopped at the body is
			# a player called one thing on the board and another in the kill feed.
			var record := game.match_node.scoreboard.find(str(player.player_id))
			if record != null:
				record.display_name = new_name
			return GSResult.success(new_name),

		GSModTools.ACTION_BURN: func(id: StringName, _args: Dictionary) -> GSResult:
			if _player(game, id) == null:
				return _absent(id)
			if game.effects == null:
				return GSResult.fail(GSError.CODE_UNSUPPORTED, "This server has no status effects.")
			# The map's own fire, for its own duration: an admin's burn is the same
			# afterburn a plasma splash leaves, so it hurts exactly as much as it looks.
			return game.effects.apply(FcEffects.BURNING, int(String(id)), 0),

		GSModTools.ACTION_BLIND: func(id: StringName, args: Dictionary) -> GSResult:
			var player := _player(game, id)
			if player == null:
				return _absent(id)
			# The screen and nothing else. A blinded player still moves, shoots and is
			# shot; an admin who wants them to stop as well has freeze, and one verb that
			# did both would be a verb nobody could use for only the first.
			player.blinded = bool(args["on"])
			return GSResult.success(player.blinded),

		GSModTools.ACTION_BEACON: func(id: StringName, args: Dictionary) -> GSResult:
			var player := _player(game, id)
			if player == null:
				return _absent(id)
			player.beacon = bool(args["on"])
			return GSResult.success(player.beacon),
	}


## Why the rest are refused. Nothing is, now that blind and beacon have a client to draw
## them; kept as a table because a new gs-moderation ability arrives unsupported, and the
## place its reason goes is here.
static func unsupported() -> Dictionary:
	return {}


## Toggles that outlive a respawn here, beyond gs-moderation's own god and buddha.
##
## [b]Blind and beacon are about the person, not the body.[/b] Freeze and noclip end with
## the body because arriving in a spawn room frozen, or falling through its floor, is the
## respawn broken; a player an admin blinded or wanted the room to watch is still that
## player after they die, and a death is exactly what a player being punished would
## otherwise use to end it.
const PERSIST_ON_RESPAWN: Array[String] = ["blind", "beacon"]


## What `give` can hand out, for its completion and its refusal.
static func item_ids(game: FcGame) -> PackedStringArray:
	var out := PackedStringArray()

	for player in game.players():
		for id in player.arsenal.catalogue.ids():
			out.append(String(id))
		break

	return out


static func position_of(game: FcGame, id: StringName) -> Variant:
	var player := _player(game, id)
	return player.controller.state.position if player != null else null


## A teleport keeps where they are looking, which is what makes a bring readable: the
## player lands facing the way they were, not snapped to north.
static func teleport(game: FcGame, id: StringName, to: Variant) -> void:
	var player := _player(game, id)

	if player == null or not (to is Vector3):
		return

	player.controller.teleport(to as Vector3, player.controller.state.yaw, player.controller.state.pitch)


## Kills a player through the combat manager, whatever protects them.
##
## God, buddha and spawn protection are all switched off for the one event and put back,
## because a slay that god mode refused would make god mode a way to be unslayable — and
## the god flag must survive it, since the tools re-apply it on the respawn. Spawn
## protection is three records: `GSHealth`'s window is cleared here, and the effect and
## the spawn ledger let the damage through on [constant FcEffects.ADMIN_KILL].
static func slay(game: FcGame, id: StringName) -> GSResult:
	return _kill_as_world(game, id, &"slay")


## A player's own `kill` command: the same world death as a slay (attacker 0, so the match
## counts a death and a suicide, the kill feed names the world, and the respawn flow is the
## ordinary one), but the weapon id is `suicide`. Nobody else may trigger it: the console
## command passes the caller's own session id.
static func suicide(game: FcGame, id: StringName) -> GSResult:
	return _kill_as_world(game, id, &"suicide")


static func _kill_as_world(game: FcGame, id: StringName, weapon: StringName) -> GSResult:
	var player := _player(game, id)

	if player == null:
		return _absent(id)

	if not player.is_alive():
		return GSResult.fail(GSError.CODE_STATE, "They are already dead.")

	var was_god := player.health.invulnerable
	var was_buddha := player.health.cannot_die
	player.health.invulnerable = false
	player.health.cannot_die = false
	player.health.invulnerable_until_tick = -1

	var damage := GSDamage.make(
		0, player.player_id, player.health.health + player.health.armour * 4.0 + 1000.0,
		game.combat.damage_type(WORLD_DAMAGE)
	)
	damage.weapon_id = weapon
	damage.tick = game.current_tick()
	# The other two thirds of spawn protection — the effect and the ledger — are vetoes in
	# `FcEffects.adjust_damage`, and this is how that hook knows to let it through.
	damage.context[FcEffects.ADMIN_KILL] = true
	game.combat.apply_damage(damage)

	player.health.invulnerable = was_god
	player.health.cannot_die = was_buddha

	if not damage.lethal:
		return GSResult.fail(GSError.CODE_STATE, "The %s was refused: %s" % [weapon, damage.refusal])

	return GSResult.success(null)


## A shove, and optionally some damage.
##
## The push is written into the SIMULATED velocity, which replicates: the owning client
## reconciles to it on the next snapshot and replays from there, so the slap is felt as a
## shove rather than as a snap. The direction comes from the tick, not from a random
## stream — it only has to be different each time, and a slap that could be replayed
## differently is a slap two machines disagree about.
static func slap(game: FcGame, id: StringName, amount: float) -> GSResult:
	var player := _player(game, id)

	if player == null:
		return _absent(id)

	if not player.is_alive():
		return GSResult.fail(GSError.CODE_STATE, "They are dead.")

	var angle := deg_to_rad(float((game.current_tick() * 137) % 360))
	var state := player.controller.state
	state.velocity += Vector3(sin(angle) * SLAP_PUSH, SLAP_LIFT, cos(angle) * SLAP_PUSH)
	state.mode = GSFpsState.Mode.AIR

	if amount > 0.0:
		var damage := GSDamage.make(0, player.player_id, amount, game.combat.damage_type(WORLD_DAMAGE))
		damage.weapon_id = &"slap"
		damage.tick = game.current_tick()
		game.combat.apply_damage(damage)

	return GSResult.success(state.velocity)


static func _player(game: FcGame, id: StringName) -> FcPlayer:
	if game == null or not String(id).is_valid_int():
		return null

	return game.player_for(String(id).to_int())


static func _absent(id: StringName) -> GSResult:
	return GSResult.fail(GSError.CODE_STATE, "Player %s is not in the match." % String(id))
