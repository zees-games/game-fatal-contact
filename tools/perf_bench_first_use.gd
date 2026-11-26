## The first-use rows of tools/perf_bench.gd (`--first-use 1`): blood, decal, impact, hit, footsteps, kill, death and the horde's npc rows,
## each the first of its kind timed through the bench's time_first_use. `--first-use-spans 1` ([member spans]) prints the
## FcFrameProbe sections of every hitch frame in the kill and death rows.
extends RefCounted

const FcNpcs := preload("../game/fc_npcs.gd")

var bench: GSGamePerfBench
## `--first-use-spans 1`: the kill and death rows name the sections of each hitch frame (see traced).
var spans := false


func _init(owner_bench: GSGamePerfBench, with_spans: bool) -> void:
	bench = owner_bench
	spans = with_spans


## A point [param metres] in front of the player's camera and a transform there facing back at it: where a decal or an impact is drawn.
func in_front(metres: float) -> Transform3D:
	var me: Variant = bench.client.get("player")
	var cam: Transform3D = me.camera.global_transform
	return Transform3D(cam.basis, cam.origin - cam.basis.z * metres)


## Rows "control N": the window of a first use with nothing done in it, so the worst frame of a bot-fight spike (a killcam moment, a bot's shot) is not read as the first use's cost.
func control(what: String) -> void:
	var _row := await bench.time_first_use(what, func() -> void: pass, Callable(), 0, 30)
	await bench.wait(0.3)


## Row "blood": the first blood splatter (its decal pool, material and texture) at a point in sight, without the ray or the hit handler.
func blood() -> void:
	var me: Variant = bench.client.get("player")
	var pres: Variant = bench.client.get("presentation")
	if me == null or pres == null or me.camera == null or pres.blood == null:
		return
	var at := in_front(3.0)
	var _row := await bench.time_first_use("blood", func() -> void: pres.blood.decals.splatter(at.origin, at.basis.z), Callable(), 0, 30)
	await bench.wait(0.3)


## Row "decal": the first bullet hole (the decal sheet's first draw), alone.
func decal() -> void:
	var me: Variant = bench.client.get("player")
	var pres: Variant = bench.client.get("presentation")
	if me == null or pres == null or me.camera == null or pres.fx == null:
		return
	var at := in_front(4.0)
	var _row := await bench.time_first_use("decal", func() -> void: var _hole: Variant = pres.fx.spawn_decal(&"bullet_hole", at), Callable(), 0, 30)
	await bench.wait(0.3)


## Row "impact": the first impact through the presentation's own handler (hole, impact sound, spark), after the decal row, so it prices the sound and the spark.
func impact() -> void:
	var me: Variant = bench.client.get("player")
	var pres: Variant = bench.client.get("presentation")
	if me == null or pres == null or me.camera == null:
		return
	var at := in_front(5.0)
	var _row := await bench.time_first_use("impact", func() -> void: pres.on_impact(at, false, &"rifle"), Callable(), 0, 30)
	await bench.wait(0.3)


## Row "hit": the server's HIT event for a body in front of the player, before any shot, through the client's own handler
## (hit marker, damage number, blood decal, body impact), as an in-process host runs it inside the first resolved shot.
func hit() -> void:
	var me: Variant = bench.client.get("player")
	var game: Variant = bench.client.get("game")
	if me == null or game == null or me.camera == null:
		return
	var victim := 0
	for p: Variant in game.players():
		if p != me:
			victim = int(p.player_id)
			break
	var cam: Transform3D = me.camera.global_transform
	var point := cam.origin - cam.basis.z * 3.0
	var _row := await bench.time_first_use("hit", func() -> void:
		bench.client.call(&"_on_hit", {"point": point, "victim_id": victim, "amount": 25.0, "headshot": false, "lethal": false}), Callable(), 0, 30)


## Rows "footstep SURFACE": the first step sound of each surface through the client's audio manager (stream load and decode).
func footsteps() -> void:
	var me: Variant = bench.client.get("player")
	var heard: Variant = bench.client.get("presentation").audio if bench.client.get("presentation") != null else null
	if me == null or heard == null:
		return
	for surface: StringName in GSAudioStock.SURFACES:
		var id := GSAudioStock.footstep_id(surface)
		var _row := await bench.time_first_use("footstep %s" % surface, func() -> void: heard.play_at(id, me.global_position), Callable(), 0, 20)
		await bench.wait(0.3)


## The bot nearest to the player (another seat), or null.
func other_player(me: Variant, game: Variant) -> Variant:
	for p: Variant in game.players():
		if p != me:
			return p
	return null


## Lethal damage from [param attacker] to [param victim] through the game's own combat (feed, award, ragdoll, drop), protection off.
func kill(game: Variant, attacker: int, victim: int) -> void:
	var health: GSHealth = game.combat.health_of(victim)
	if health == null:
		return
	health.invulnerable = false
	health.invulnerable_until_tick = -1
	var type: GSDamageType = game.combat.damage_type(&"bullet")
	var hit := GSDamage.make(attacker, victim, health.health + health.armour + 50.0, type)
	hit.tick = game.current_tick()
	hit.weapon_id = &"rifle"
	game.combat.apply_damage(hit)


## Row "kill": a bot put a few metres in front of the player and killed by them (kill feed, award, ragdoll, weapon drop).
func kill_row() -> void:
	var me: Variant = bench.client.get("player")
	var game: Variant = bench.client.get("game")
	if me == null or game == null or me.camera == null:
		return
	var victim: Variant = other_player(me, game)
	if victim == null:
		bench.say("first use: kill skipped (no bot)")
		return
	var cam: Transform3D = me.camera.global_transform
	victim.global_position = me.global_position - Vector3(cam.basis.z.x, 0.0, cam.basis.z.z).normalized() * 4.0
	await bench.wait(0.3)
	var kill := func() -> void: kill(game, int(me.player_id), int(victim.player_id))
	if spans:
		await traced("kill", kill, 90)
	else:
		var _row := await bench.time_first_use("kill", kill, Callable(), 0, 90)
	await bench.wait(1.0)


## Rows "death" (the player killed by a bot: death view, killview, respawn screen) and "respawn". Last: the player is down after it.
func death() -> void:
	var me: Variant = bench.client.get("player")
	var game: Variant = bench.client.get("game")
	if me == null or game == null:
		return
	var killer: Variant = other_player(me, game)
	me.health.invulnerable = false
	var death := func() -> void: kill(game, int(killer.player_id) if killer != null else 0, int(me.player_id))
	if spans:
		await traced("death", death, 120)
	else:
		var _row := await bench.time_first_use("death", death, Callable(), 0, 120)


## `--first-use-spans 1`: [param action] then [param frames] frames, each over [param over_ms] printed with the FcFrameProbe sections
## (DotFrameCost) charged in it, so a hitch row names the section. Replaces time_first_use for the kill and death rows.
func traced(what: String, action: Callable, frames: int, over_ms := 17.0) -> void:
	await bench.wait(0.5)
	DotFrameCost.enabled = true
	var _drop := DotFrameCost.take()
	action.call()
	var last := Time.get_ticks_usec()
	for i in frames:
		await bench.get_tree().process_frame
		var now := Time.get_ticks_usec()
		var ms := (now - last) / 1000.0
		last = now
		var costs := DotFrameCost.take()
		if ms < over_ms:
			continue
		var parts: Array = []
		for key: StringName in costs:
			if float(costs[key].ms) >= 0.8:
				parts.append([float(costs[key].ms), "%s %.1f" % [key, float(costs[key].ms)]])
		parts.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
		var text := ""
		for part: Array in parts.slice(0, 8):
			text += " | " + String(part[1])
		bench.say("SPANS %s f%d %.1f ms%s" % [what, i, ms, text])
	DotFrameCost.enabled = false


## Rows "npc ID" (a monster of each kind placed in sight) and "npc kill ID" (it killed by the player). Needs a mode with a horde
## (`--mode siege`); other modes have no monsters and say so.
func npcs() -> void:
	var me: Variant = bench.client.get("player")
	var game: Variant = bench.client.get("game")
	var horde: Variant = game.get("horde") if game != null else null
	if me == null or horde == null or horde.nav == null or me.camera == null:
		bench.say("first use: npc rows skipped (no horde in mode %s)" % bench.mode)
		return
	var cam: Transform3D = me.camera.global_transform
	var want := cam.origin - cam.basis.z * 8.0
	var at: Vector3 = horde.nav.points[0]
	for point: Vector3 in horde.nav.points:
		if point.distance_squared_to(want) < at.distance_squared_to(want):
			at = point
	for def: GSNpcDef in FcNpcs.catalogue().in_faction(FcNpcs.FACTION):
		var held: Array = []
		var _spawned := await bench.time_first_use("npc %s" % def.id, func() -> void: place_npc(horde, def.id, at, held), Callable(), 0, 45)
		await bench.wait(0.5)
		var npc: GSNpcInstance = held[0] if not held.is_empty() else null
		if npc == null:
			bench.say("first use: npc %s did not spawn" % def.id)
			continue
		var _killed := await bench.time_first_use("npc kill %s" % def.id, func() -> void: kill(game, int(me.player_id), horde.entity_id_for(npc)), Callable(), 0, 90)
		await bench.wait(1.0)


## The siege director keeps the world at its NPC budget, which refuses a hand-placed monster: clear the world and place at once.
func place_npc(horde: Variant, id: StringName, at: Vector3, held: Array) -> void:
	var _cleared: int = horde.clear()
	held.append(horde.spawn_one(id, at))
