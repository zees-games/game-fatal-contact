extends GSGameCheckSuite

const FcBots := preload("../game/fc_bots.gd")
const FcBotLoadouts := preload("../game/fc_bot_loadouts.gd")
const FcContent := preload("../game/fc_content.gd")
const FcGame := preload("../game/fc_game.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcPlayer := preload("../game/fc_player.gd")

## Bot loadouts: the profiles load and fit the owner's rules, draws follow the weights, `sv_bot_loadouts` and the difficulty narrow them, a seed repeats them, and the kit a bot
## draws is the gun it spawns holding and fires. [codeblock]
## ./game.sh test headless_bot_loadouts [/codeblock]

const TICK_RATE := 64
const MAP := &"atrium"
const DRAWS := 6000
const SHARE_SLACK := 0.025
const SPAWNED := 12
const FIGHT_SECONDS := 120.0

## Chained gives per path in the sv_bot_regive section: enough for reserve ammo to reach its cap.
const REGIVES := 4
const SECTIONS := 8
const CHECKS := 27

var _entered := 0
var _completed := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-fatal-contact headless bot loadouts")
	FcBotLoadouts.mode = FcBotLoadouts.ALL
	FcBotLoadouts.seed = 0
	var game := _boot()
	var pool := FcBotLoadouts.new()
	_profiles(game, pool)
	_distribution(pool)
	_restricted(pool)
	_difficulty(pool)
	_determinism(pool)
	await _spawned(game)
	_regive(game)
	_free(game)
	await _fight()
	FcBotLoadouts.mode = FcBotLoadouts.ALL
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _profiles(game: FcGame, pool: FcBotLoadouts) -> void:
	_section("the profiles load and every item fits the owner's rules")
	var n := pool.load_from()
	_check(n >= 8, "at least eight kits load", "%d" % n)
	var unfit: Array[String] = []
	var primaries := {}
	for kit in pool.kits:
		var loadout := FcBotLoadouts.build(kit, game.loadouts, game._loadout_key(FcGame.BOT_SESSION_BASE))
		for slot: StringName in kit.items:
			if loadout.item_in(slot) != kit.items[slot]:
				unfit.append("%s.%s=%s" % [kit.id, slot, kit.items[slot]])
		primaries[kit.items.get(&"primary", &"")] = true
	_check(unfit.is_empty(), "no profile item is replaced by the rules", ", ".join(unfit))
	_check(primaries.size() >= 8, "the kits carry at least eight different primaries", "%d" % primaries.size())
	_check_built_memo(game, pool)
	_done()


## [method FcBotLoadouts.built_for] memoes each kit once, and what it hands out equals a fresh
## build and resolve entry for entry.
func _check_built_memo(game: FcGame, pool: FcBotLoadouts) -> void:
	var key := game._loadout_key(FcGame.BOT_SESSION_BASE)
	var differ: Array[String] = []
	var shared := true
	for kit in pool.kits:
		var built := pool.built_for(kit, game.loadouts, key)
		shared = shared and pool.built_for(kit, game.loadouts, key)[1] == built[1] and is_same(pool.built_for(kit, game.loadouts, key)[0], built[0])
		var fresh := FcContent.in_give_order(game.loadouts.resolve(FcBotLoadouts.build(kit, game.loadouts, key)))
		if _entries_text(built[1]) != _entries_text(fresh):
			differ.append("%s: %s vs %s" % [kit.id, _entries_text(built[1]), _entries_text(fresh)])
	_check(shared and pool.built_count() == pool.kits.size(), "a kit is built once and shared", "%d for %d kits" % [pool.built_count(), pool.kits.size()])
	_check(differ.is_empty(), "the memoed entries equal a fresh build field for field", "; ".join(differ))


func _entries_text(entries: Array) -> String:
	var parts := PackedStringArray()
	for e: Dictionary in entries:
		parts.append("%s/%d/%s/%d" % [e["slot"], int(e["arsenal_slot"]), (e["item"] as GSItem).id, int(e["count"])])
	return ",".join(parts)


func _distribution(pool: FcBotLoadouts) -> void:
	_section("draws follow the profile weights")
	var counts := _count(pool, "")
	var total := 0.0
	for kit in pool.kits:
		total += kit.weight
	var off: Array[String] = []
	for kit in pool.kits:
		var share := float(counts.get(kit.id, 0)) / DRAWS
		if absf(share - kit.weight / total) > SHARE_SLACK:
			off.append("%s %.3f vs %.3f" % [kit.id, share, kit.weight / total])
	_check(counts.size() == pool.kits.size(), "every kit is drawn", "%d of %d" % [counts.size(), pool.kits.size()])
	_check(off.is_empty(), "each kit's share is within %.3f of its weight's" % SHARE_SLACK, ", ".join(off))
	_done()


func _restricted(pool: FcBotLoadouts) -> void:
	_section("sv_bot_loadouts narrows and reweighs the draw")
	FcBotLoadouts.mode = "sniper"
	var only := _count(pool, "")
	_check(only.size() == 1 and int(only.get(&"sniper", 0)) == DRAWS, "'sniper' deals only the sniper kit", str(only))
	FcBotLoadouts.mode = " smg, shotgun:3 "
	var two := _count(pool, "")
	var shotgun := float(two.get(&"shotgun", 0)) / DRAWS
	_check(two.size() == 2 and two.has(&"smg"), "'smg, shotgun:3' deals only those two", str(two))
	_check(absf(shotgun - 0.75) < SHARE_SLACK, "the cvar's weight replaces the profile's", "%.3f" % shotgun)
	FcBotLoadouts.mode = "no_such_kit"
	_check(pool.draw_kit(1) == null, "a list naming no kit draws nothing, so the bot keeps the default loadout")
	FcBotLoadouts.mode = "ALL"
	_check(_count(pool, "").size() == pool.kits.size(), "'ALL' is every kit again")
	_done()


func _difficulty(pool: FcBotLoadouts) -> void:
	_section("a kit tagged with difficulties is dealt only at those")
	var easy := _count(pool, "easy")
	var hard := _count(pool, "nightmare")
	_check(not easy.has(&"sniper") and not easy.has(&"drum_shotgun"), "easy bots never draw sniper or drum_shotgun", str(easy.keys()))
	_check(hard.has(&"sniper") and hard.has(&"drum_shotgun"), "nightmare bots do")
	_done()


func _determinism(pool: FcBotLoadouts) -> void:
	_section("the same seed deals the same kits")
	var a := _sequence(pool)
	var b := _sequence(pool)
	FcBotLoadouts.seed = 41
	var c := _sequence(pool)
	FcBotLoadouts.seed = 0
	_check(a == b, "two runs at one seed match")
	_check(a != c, "another seed deals another sequence")
	_done()


func _spawned(game: FcGame) -> void:
	_section("a spawning bot holds its kit's primary, a human the usual loadout")
	game.match_node.rules.respawn_delay_sec = 1.0
	for i in SPAWNED:
		var _a := game.add_player(FcGame.BOT_SESSION_BASE + 1 + i, "Bot%d" % i)
	var _h := game.add_player(7, "Human")
	game.start(0)
	game.tick({})
	await get_tree().process_frame
	var kinds := {}
	var wrong: Array[String] = []
	for i in SPAWNED:
		var bot := game.player_for(FcGame.BOT_SESSION_BASE + 1 + i)
		var kit := _kit_of(game, bot)
		if kit == null:
			wrong.append("bot %d drew nothing" % i)
			continue
		kinds[kit.id] = true
		var held := bot.arsenal.slot_at(bot.arsenal.current_slot())
		var carried := _carried(bot.arsenal)
		for slot: StringName in kit.items:
			# Gear (armour) is worn, not carried in the arsenal.
			if slot != &"gear" and not carried.has(kit.items[slot]):
				wrong.append("%s lacks %s" % [kit.id, kit.items[slot]])
		if held == null or held.id() != kit.items.get(&"primary", &""):
			wrong.append("%s holds %s" % [kit.id, held.id() if held != null else &"nothing"])
	_check(wrong.is_empty(), "every bot carries its whole kit and holds its primary", "; ".join(wrong))
	_check(kinds.size() >= 4, "%d bots spawn with at least four different kits" % SPAWNED, str(kinds.keys()))
	_check(not game.player_for(7).has_meta(&"bot_loadout"), "a human does not draw a bot kit")
	var bare := _bare_fittings(game)
	_check(bare.is_empty(), "a kit's attachments are fitted to its guns", bare)
	_done()


## `sv_bot_regive`: a bot's re-give that reuses its behaviours (gs-weapon API 56) ends where building them all does.
func _regive(game: FcGame) -> void:
	_section("sv_bot_regive re-gives a bot's kit to the state a fresh give makes")
	var bot := game.player_for(FcGame.BOT_SESSION_BASE + 1)
	if not FcBotLoadouts.regive_supported:
		_check(true, "gs-weapon below API 56: sv_bot_regive does nothing")
		_check(true, "(skipped)")
		_done()
		return
	var was := FcBotLoadouts.regive
	# Each draw is a new life with its own kit; both gives draw the same life so they give the same kit.
	var life := int(game.bot_loadouts._lives.get(bot.player_id, 0))
	# Reserve ammo carries over between gives on both paths (clear() keeps the pools; a give tops them up to the
	# cap), so each chain of gives starts from one restored state and the two are compared give by give.
	var start := bot.arsenal.snapshot()
	var chains: Array[PackedStringArray] = []
	var reused_before := 0
	for reuse: bool in [false, true]:
		var _restored := bot.arsenal.restore(start)
		FcBotLoadouts.regive = reuse
		reused_before = int(bot.arsenal.get(&"behaviours_reused"))
		var chain := PackedStringArray()
		for i in REGIVES:
			game.bot_loadouts._lives[bot.player_id] = life
			var _given := game._give_bot_loadout(bot)
			chain.append(var_to_str(bot.arsenal.snapshot()))
		chains.append(chain)
	FcBotLoadouts.regive = was
	var reused := int(bot.arsenal.get(&"behaviours_reused")) - reused_before
	_check(reused >= REGIVES - 1, "the re-gives reused the bot's behaviours", "%d reused" % reused)
	var first_bad := -1
	for i in REGIVES:
		if chains[0][i] != chains[1][i]:
			first_bad = i
			break
	_check(first_bad < 0, "each of %d chained re-gives' snapshot (reserve ammo too) equals the fresh path's" % REGIVES,
		"give %d: %s vs %s" % [first_bad, chains[0][first_bad], chains[1][first_bad]] if first_bad >= 0 else "")
	_done()


func _fight() -> void:
	_section("bots fire the guns their kit gave them")
	FcBotLoadouts.mode = "smg"
	var game := _boot()
	game.match_node.rules.respawn_delay_sec = 1.0
	var ids: Array[int] = [FcGame.BOT_SESSION_BASE + 1, FcGame.BOT_SESSION_BASE + 2]
	var minds := {}
	for id in ids:
		var _a := game.add_player(id, "Bot%d" % id)
		minds[id] = FcBots.Mind.new()
		minds[id].seed = 7 + id % 13
	game.start(0)
	game.tick({})
	await get_tree().process_frame
	var fired := {}
	var stray: Array[String] = []
	var mags := {}
	for i in range(int(FIGHT_SECONDS * TICK_RATE)):
		var tick := game.current_tick()
		var commands := {}
		for id in ids:
			commands[id] = FcBots.think(game, game.player_for(id), minds[id], tick, float(TICK_RATE))
		game.tick(commands)
		for id in ids:
			var bot := game.player_for(id)
			if bot == null or not bot.is_alive():
				continue
			var slot := bot.arsenal.slot_at(bot.arsenal.current_slot())
			if slot == null or slot.def == null or not slot.def.uses_magazine():
				continue
			var key := "%d/%s" % [id, slot.id()]
			if mags.has(key) and slot.magazine < int(mags[key]):
				fired[slot.id()] = true
				if not _kit_of(game, bot).items.values().has(slot.id()):
					stray.append(String(slot.id()))
			mags[key] = slot.magazine
		if fired.has(&"smg") and i > 10 * TICK_RATE:
			break
		if i % 8 == 0:
			await get_tree().process_frame
	_check(fired.has(&"smg"), "under 'smg' the bots fire the smg", str(fired.keys()))
	_check(stray.is_empty(), "no bot fires a gun its kit did not give", ", ".join(stray))
	var choice := _gun_choices(game.player_for(ids[0]))
	_check(choice.is_empty(), "the smg wears its kit's suppressor, and the gun choice keeps it close and picks a gun that reaches far", choice)
	_free(game)
	await get_tree().process_frame
	_done()


## What [method FcBots.gun_for] gets wrong for an smg bot, or "".
func _gun_choices(bot: FcPlayer) -> String:
	if bot == null or not bot.is_alive():
		return "the bot is dead"
	var arsenal := bot.arsenal
	var smg := _slot_of(arsenal, &"smg")
	if smg == 0:
		return "no smg slot"
	if arsenal.fitting_at(smg).attachment_on(&"muzzle") != &"suppressor":
		return "the kit's suppressor is not on the smg"
	var _e := arsenal.equip(smg)
	if arsenal.current_slot() != smg:
		return "the smg is not held"
	if FcBots.gun_for(arsenal, 8.0) != 0:
		return "it drops the smg at 8 m"
	var far := FcBots.gun_for(arsenal, 100000.0)
	if far == smg:
		return "it keeps the smg out of reach"
	return ""


func _boot() -> FcGame:
	var game := FcGame.new()
	game.tick_rate = TICK_RATE
	game.score_limit = 100000
	game.time_limit_sec = 0.0
	game.headless = true
	game.is_authority = true
	game.register_service = false
	add_child(game)
	_check(game.setup(FcMap.by_id(MAP)).ok, "the game sets up on %s" % MAP)
	game.match_node.rules.warmup_sec = 0.0
	game.match_node.rules.countdown_sec = 0.0
	return game


func _free(game: FcGame) -> void:
	remove_child(game)
	game.queue_free()


func _count(pool: FcBotLoadouts, difficulty: String) -> Dictionary:
	pool.reset()
	var out := {}
	for i in DRAWS:
		var kit := pool.draw_kit(1 + i % 64, difficulty)
		if kit != null:
			out[kit.id] = int(out.get(kit.id, 0)) + 1
	return out


func _sequence(pool: FcBotLoadouts) -> Array[StringName]:
	pool.reset()
	var out: Array[StringName] = []
	for i in 64:
		out.append(pool.draw_kit(FcGame.BOT_SESSION_BASE + i % 4).id)
	return out


func _kit_of(game: FcGame, bot: FcPlayer) -> FcBotLoadouts.Kit:
	if bot == null or game.bot_loadouts == null or not bot.has_meta(&"bot_loadout"):
		return null
	for kit in game.bot_loadouts.kits:
		if kit.id == bot.get_meta(&"bot_loadout"):
			return kit
	return null


## The kit attachments missing from the guns of the spawned bots, or "" (also when no bot drew a kit with any).
func _bare_fittings(game: FcGame) -> String:
	var missing: Array[String] = []
	for i in SPAWNED:
		var bot := game.player_for(FcGame.BOT_SESSION_BASE + 1 + i)
		var kit := _kit_of(game, bot)
		if kit == null:
			continue
		for gun: Variant in kit.attachments:
			var slot := _slot_of(bot.arsenal, StringName(str(gun)))
			var fitting := bot.arsenal.fitting_at(slot)
			var mounts: Dictionary = kit.attachments[gun]
			for mount: Variant in mounts:
				if fitting.attachment_on(StringName(str(mount))) != StringName(str(mounts[mount])):
					missing.append("%s %s.%s" % [kit.id, gun, mount])
	return ", ".join(missing)


func _carried(arsenal: GSWeaponArsenal) -> Dictionary:
	var out := {}
	for slot in arsenal.slots():
		var held := arsenal.slot_at(slot)
		if held != null:
			out[held.id()] = true
	return out


func _slot_of(arsenal: GSWeaponArsenal, id: StringName) -> int:
	for slot in arsenal.slots():
		var held := arsenal.slot_at(slot)
		if held != null and held.id() == id:
			return slot
	return 0


func _section(title: String) -> void:
	_entered += 1
	print("")
	print("-- %s" % title)


func _done() -> void:
	_completed += 1
