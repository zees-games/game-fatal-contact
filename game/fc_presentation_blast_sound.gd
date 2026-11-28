extends "fc_presentation_vars_and_frame.gd"

# The cue ids only (FcVote.CUE_* are these): `fc_vote.gd` is server-side, and preloading it
# here compiled the vote and gs-vote into every client.
const FcVote := preload("fc_vote_cues.gd")
const FcNewerApi := preload("fc_newer_api.gd")
## Ids that play recorded files from the addons: id -> [folder, file stem, how many, gain dB, pitch
## low, pitch high]. Folder: &"weapons", &"stock" (gs-audio `stock/`) or &"toys" (gs-props). The
## recipes in [method sound_recipes] stay for a build that lacks the files.
const RECORDED := {
	&"fire_rifle": [&"weapons", "rifle_fire", 5, 0.0, 0.95, 1.05],
	&"fire_shotgun": [&"weapons", "shotgun_fire", 5, 0.0, 0.95, 1.04],
	# Recorded a few dB hotter on average than the rifle, at a lower peak: level with it here.
	&"fire_rail": [&"weapons", "rail_fire", 4, -3.0, 0.97, 1.03],
	&"explosion": [&"weapons", "explosion", 5, 0.0, 0.9, 1.06],
	&"impact": [&"weapons", "impact", 5, -2.0, 0.9, 1.1],
	# A boot on a head: a meaty smack, not a sweep.
	&"stomp": [&"weapons", "melee_flesh", 5, 2.0, 0.85, 0.95],
	# Recorded about 10 dB under a shot; a pickup is meant to be heard over your own steps.
	&"pickup": [&"weapons", "equip", 3, 6.0, 0.95, 1.08],
	# A bell for the beacon: a ping that says where, and nothing like a hit marker.
	&"beacon": [&"toys", "bell", 2, 0.0, 0.97, 1.03],
	# The wall moves on the stock concrete step and light landing, pitched up a little so a run's
	# first step is not heard as somebody else's footstep.
	&"wall_run": [&"stock", "footsteps/footstep_concrete", 5, -4.0, 1.1, 1.2],
	&"wall_jump": [&"stock", "landing/landing_light", 1, -4.0, 1.12, 1.2],
	# A short tick for a hit and a two-note chime for a kill: information, not a noise in the world.
	# The tick is pitched down to about 0.8 (the recording sounded high and thin to the owner).
	&"hit_marker": [&"fc", "hit_body", 3, 0.0, 0.94, 1.06],
	&"hit_head": [&"fc", "hit_head", 1, 0.0, 0.97, 1.03],
	&"hit_armor": [&"fc", "hit_armor", 1, 0.0, 0.95, 1.05],
	&"kill_confirmed": [&"fc", "hit_kill", 1, 0.0, 0.97, 1.03],
	# The medals are spoken: a word says which medal, where a pitched sweep only said "good".
	&"announce_first_blood": [&"fc", "first_blood", 1, 0.0, 1.0, 1.0],
	&"announce_double_kill": [&"fc", "double_kill", 1, 0.0, 1.0, 1.0],
	&"announce_multi_kill": [&"fc", "multi_kill", 1, 0.0, 1.0, 1.0],
	&"announce_mega_kill": [&"fc", "mega_kill", 1, 0.0, 1.0, 1.0],
	&"announce_ultra_kill": [&"fc", "ultra_kill", 1, 0.0, 1.0, 1.0],
	&"announce_monster_kill": [&"fc", "monster_kill", 1, 0.0, 1.0, 1.0],
	&"announce_killing_spree": [&"fc", "killing_spree", 1, 0.0, 1.0, 1.0],
	&"announce_rampage": [&"fc", "rampage", 1, 0.0, 1.0, 1.0],
	&"announce_dominating": [&"fc", "dominating", 1, 0.0, 1.0, 1.0],
	&"announce_unstoppable": [&"fc", "unstoppable", 1, 0.0, 1.0, 1.0],
	&"announce_godlike": [&"fc", "godlike", 1, 0.0, 1.0, 1.0],
	&"announce_headshot": [&"fc", "headshot", 1, 0.0, 1.0, 1.0],
	&"announce_humiliation": [&"fc", "humiliation", 1, 0.0, 1.0, 1.0],
	&"announce_flawless_victory": [&"fc", "flawless_victory", 1, 0.0, 1.0, 1.0],
	&"announce_prepare_to_fight": [&"fc", "prepare_to_fight", 1, 0.0, 1.0, 1.0],
	&"announce_last_man_standing": [&"fc", "last_man_standing", 1, 0.0, 1.0, 1.0],
	&"medal_first_blood": [&"stock", "announcer/target_eliminated", 1, 0.0, 1.0, 1.0],
	&"medal_headshot": [&"stock", "announcer/perfect", 1, 0.0, 1.0, 1.0],
	&"medal_double_kill": [&"stock", "announcer/combo", 1, 0.0, 1.0, 1.0],
	&"medal_triple_kill": [&"stock", "announcer/multikill", 1, 0.0, 1.0, 1.0],
	&"medal_multi_kill": [&"stock", "announcer/godlike", 1, 0.0, 1.0, 1.0],
	&"medal_revenge": [&"stock", "announcer/eliminated", 1, 0.0, 1.0, 1.0],
	&"medal_shutdown": [&"stock", "announcer/combo_breaker", 1, 0.0, 1.0, 1.0],
	&"medal_point_blank": [&"stock", "announcer/target_destroyed", 1, 0.0, 1.0, 1.0],
	&"medal_no_scope": [&"stock", "announcer/fantastic", 1, 0.0, 1.0, 1.0],
	&"medal_long_shot": [&"stock", "announcer/sniper", 1, 0.0, 1.0, 1.0],
	&"medal_nemesis": [&"stock", "announcer/untouchable", 1, 0.0, 1.0, 1.0],
	# Spoken where a flag changed hands for a team, a plain cue for a drop or a return.
	&"flag_taken_by_me": [&"stock", "announcer/lets_go", 1, 0.0, 1.0, 1.0],
	&"flag_taken": [&"stock", "announcer/go_go_go", 1, 0.0, 1.0, 1.0],
	&"flag_lost": [&"stock", "announcer/enemy_captured", 1, 0.0, 1.0, 1.0],
	&"flag_lost_back": [&"stock", "announcer/target_lost", 1, 0.0, 1.0, 1.0],
	&"flag_dropped": [&"stock", "interface/drop", 1, 0.0, 1.0, 1.0],
	&"flag_returned": [&"stock", "interface/confirm_bright", 1, 0.0, 1.0, 1.0],
	&"flag_captured": [&"stock", "announcer/point_captured", 1, 0.0, 1.0, 1.0],
	&"vote_start": [&"stock", "interface/question", 1, 0.0, 1.0, 1.0],
	&"vote_end": [&"stock", "interface/confirm_long", 1, 0.0, 1.0, 1.0],
	&"vote_warning": [&"stock", "interface/bong", 1, 0.0, 1.0, 1.0],
	&"vote_count": [&"stock", "interface/pluck", 1, 0.0, 1.0, 1.0],
	# Kenney's phase jump peaks near -15 dBFS, well under the rest of the set.
	&"spawned": [&"stock", "interface/phase_jump", 3, 9.0, 0.98, 1.02],
	&"hurt": [&"stock", "body/punch", 5, -3.0, 0.95, 1.08],
	&"died": [&"stock", "body/punch_heavy", 5, 0.0, 0.85, 0.92],
}


const STOMP_SOUND := &"stomp"
## Fatal Contact's own generated feedback and announcer audio (tools/make_ui_audio.py).
const FC_AUDIO_DIR := "res://assets/audio"


## Capture the flag's cues (see on_flag_event) and the medals, with the synthesised voice each
## falls back to in a build without gs-audio's stock files; their recordings are in RECORDED.
const FLAG_VOICES := {
	&"flag_taken_by_me": GSAudioSynth.Voice.PICKUP,
	&"flag_taken": GSAudioSynth.Voice.PICKUP,
	&"flag_lost": GSAudioSynth.Voice.DENY,
	&"flag_lost_back": GSAudioSynth.Voice.DENY,
	&"flag_dropped": GSAudioSynth.Voice.BLIP,
	&"flag_returned": GSAudioSynth.Voice.PICKUP,
	&"flag_captured": GSAudioSynth.Voice.SPAWN,
}

const MEDAL_VOICES := {
	&"medal_first_blood": GSAudioSynth.Voice.SPAWN,
	&"medal_headshot": GSAudioSynth.Voice.PICKUP,
	&"medal_double_kill": GSAudioSynth.Voice.SPAWN,
	&"medal_triple_kill": GSAudioSynth.Voice.SPAWN,
	&"medal_multi_kill": GSAudioSynth.Voice.SPAWN,
	&"medal_revenge": GSAudioSynth.Voice.PICKUP,
	&"medal_shutdown": GSAudioSynth.Voice.PICKUP,
	&"medal_point_blank": GSAudioSynth.Voice.IMPACT,
	&"medal_no_scope": GSAudioSynth.Voice.SHOT_TIGHT,
	&"medal_long_shot": GSAudioSynth.Voice.SHOT_TIGHT,
	&"medal_nemesis": GSAudioSynth.Voice.DENY,
}


## The thrown grenades that have a detonation recording of their own (fc_weapons level 26, `AwGrenadeSound`).
const GRENADE_BLAST_LEVEL := 26
const GRENADE_BLASTS: Array[StringName] = [&"frag", &"sticky", &"flash", &"smoke", &"incendiary"]


## The sound id of [param grenade]'s own detonation, or [constant EXPLOSION] when this build has no recording for it.
static func blast_sound_id(grenade: StringName) -> StringName:
	if not GRENADE_BLASTS.has(grenade) or GSAddonApi.build_level("fc_weapons") < GRENADE_BLAST_LEVEL:
		return EXPLOSION
	if int(FcNewerApi.call_static(&"AwGrenadeSound", &"count", [grenade])) == 0:
		return EXPLOSION
	return StringName("%s_%s" % [EXPLOSION, grenade])


func _blast_sound(weapon_id: StringName) -> StringName:
	return blast_sound_id(weapon_id)


## A blast def for [param grenade] playing its takes from `AwGrenadeSound`, set like the stock [constant EXPLOSION]; null without recordings.
static func grenade_blast(grenade: StringName) -> GSAudioDef:
	var id := blast_sound_id(grenade)
	if id == EXPLOSION:
		return null
	var blast := GSAudioDef.new()
	blast.id = id
	blast.kind = GSAudioDef.Kind.POSITIONAL_3D
	blast.bus = &"SFX"
	blast.unit_size = 22.0
	blast.max_distance = 140.0
	blast.max_concurrent = 3
	blast.priority = 85
	blast.tags = [&"weapon"]
	var takes := PackedStringArray()
	for i in range(int(FcNewerApi.call_static(&"AwGrenadeSound", &"count", [grenade]))):
		takes.append((FcNewerApi.call_static(&"AwGrenadeSound", &"stream", [grenade, i]) as AudioStream).resource_path)
	blast.path = takes[0]
	blast.variants = takes if takes.size() > 1 else PackedStringArray()
	return blast


## What a deathmatch makes a noise about.
static func sound_catalogue() -> GSAudioCatalogue:
	var c := GSAudioCatalogue.new()
	GSAudioStock.add_to(c)

	for id in [&"rifle", &"shotgun", &"rail"]:
		var fire := GSAudioDef.new()
		fire.id = StringName("fire_%s" % id)
		fire.kind = GSAudioDef.Kind.POSITIONAL_3D
		fire.bus = &"SFX"
		fire.unit_size = 14.0
		# Past this it is not a shot you can act on, and it would cost a voice every frame.
		fire.max_distance = 90.0
		# Twelve rifles in one tick is one gunshot, twelve times as loud. Three sounds like a firefight.
		fire.max_concurrent = 3
		fire.priority = 80
		fire.tags = [&"weapon"]
		c.add(recorded(fire))

	# A blast: positional and carrying far, few at once.
	var blast := GSAudioDef.new()
	blast.id = EXPLOSION
	blast.kind = GSAudioDef.Kind.POSITIONAL_3D
	blast.bus = &"SFX"
	blast.unit_size = 22.0
	blast.max_distance = 140.0
	blast.max_concurrent = 3
	blast.priority = 85
	blast.tags = [&"weapon"]
	c.add(recorded(blast))

	for grenade in GRENADE_BLASTS:
		var own := grenade_blast(grenade)
		if own != null:
			c.add(own)

	var impact := GSAudioDef.new()
	impact.id = &"impact"
	impact.kind = GSAudioDef.Kind.POSITIONAL_3D
	impact.bus = &"SFX"
	impact.max_distance = 40.0
	impact.max_concurrent = 4
	impact.priority = 40
	c.add(recorded(impact))

	_add_interface_sounds(c)

	# The wall moves: files and pitch in RECORDED; a cooldown each so a run is a step, not a buzz.
	for wall in [[WALL_RUN_SOUND, 120], [WALL_JUMP_SOUND, 90]]:
		var move := GSAudioDef.new()
		move.id = wall[0]
		move.bus = &"SFX"
		move.cooldown_ms = wall[1]
		move.max_concurrent = 1
		move.priority = 55
		c.add(recorded(move))

	var pickup := GSAudioDef.new()
	pickup.id = &"pickup"
	pickup.kind = GSAudioDef.Kind.POSITIONAL_3D
	pickup.bus = &"SFX"
	pickup.max_distance = 30.0
	pickup.max_concurrent = 3
	pickup.priority = 50
	c.add(recorded(pickup))

	_add_body_sounds(c)

	return c


## Hit, kill, medal, flag, vote, beacon and body-state cues: flat on the interface bus unless noted.
static func _add_interface_sounds(c: GSAudioCatalogue) -> void:
	# Flat, not positional: a hit marker is about your own shot and must not fade with distance.
	var hit := GSAudioDef.new()
	hit.id = &"hit_marker"
	hit.bus = &"UI"
	hit.cooldown_ms = 60
	hit.max_concurrent = 2
	hit.priority = 95
	c.add(recorded(hit))

	# Headshot and armour hits: the same flat marker with its own low sound.
	for id in [&"hit_head", &"hit_armor"]:
		var variant := GSAudioDef.new()
		variant.id = id
		variant.bus = &"UI"
		variant.cooldown_ms = 60
		variant.max_concurrent = 2
		variant.priority = 95
		c.add(recorded(variant))

	# The announcer's spoken lines: one at a time (FcAnnouncer queues), on the interface bus.
	for line: StringName in FcAnnouncer.LINES:
		var said := GSAudioDef.new()
		said.id = FcAnnouncer.sound_id(line)
		said.bus = &"UI"
		said.max_concurrent = 1
		said.priority = 97
		c.add(recorded(said))

	# A hit that killed: the same flat information, longer than the tick.
	var killed := GSAudioDef.new()
	killed.id = KILL_CONFIRMED
	killed.bus = &"UI"
	killed.max_concurrent = 1
	killed.priority = 96
	c.add(recorded(killed))

	# The medals: flat, on the interface bus, one at a time each. Information about your
	# own kill, like the hit marker; louder than the world so a medal is never lost in it.
	for id in MEDAL_VOICES:
		var medal := GSAudioDef.new()
		medal.id = id
		medal.bus = &"UI"
		medal.max_concurrent = 1
		medal.priority = 92
		c.add(recorded(medal))

	for id in FLAG_VOICES:
		var cue := GSAudioDef.new()
		cue.id = id
		cue.bus = &"UI"
		cue.max_concurrent = 2
		cue.priority = 93
		c.add(recorded(cue))

	var stomp := GSAudioDef.new()
	stomp.id = STOMP_SOUND
	stomp.bus = &"SFX"
	stomp.max_concurrent = 3
	stomp.priority = 88
	c.add(recorded(stomp))

	var hurt := GSAudioDef.new()
	hurt.id = &"hurt"
	hurt.bus = &"SFX"
	hurt.cooldown_ms = 180
	hurt.max_concurrent = 1
	hurt.priority = 90
	c.add(recorded(hurt))

	var died := GSAudioDef.new()
	died.id = &"died"
	died.bus = &"SFX"
	died.priority = 100
	c.add(recorded(died))

	var spawn := GSAudioDef.new()
	spawn.id = &"spawned"
	spawn.bus = &"UI"
	spawn.priority = 60
	c.add(recorded(spawn))
	_add_vote_sounds(c)


## The map vote's cues and the administrator's beacon ping.
static func _add_vote_sounds(c: GSAudioCatalogue) -> void:
	# The map vote's cues. Flat and on the interface bus: a ballot is about the server, not about a
	# place in the world, and a countdown that got quieter the further you stood from the origin
	# would be a countdown some players never heard.
	for vote_id in [FcVote.CUE_START, FcVote.CUE_END, FcVote.CUE_WARNING, FcVote.CUE_COUNT]:
		var cue := GSAudioDef.new()
		cue.id = vote_id
		cue.bus = &"UI"
		cue.max_concurrent = 1
		cue.priority = 70
		c.add(recorded(cue))

	# An administrator's beacon: a ping once a second from the beaconed player, heard by everybody.
	# Positional, because the beacon's whole job is to say WHERE somebody is and a flat ping would
	# say only that somebody somewhere is beaconed.
	var ping := GSAudioDef.new()
	ping.id = BEACON_SOUND
	ping.kind = GSAudioDef.Kind.POSITIONAL_3D
	ping.bus = &"SFX"
	ping.unit_size = 20.0
	ping.max_distance = 160.0
	ping.max_concurrent = 4
	ping.priority = 45
	c.add(recorded(ping))


## The addon-shipped fall and toy sounds.
static func _add_body_sounds(c: GSAudioCatalogue) -> void:
	# A body landing: gs-player-char's stock death sounds (Kenney, CC0), the thud, the face
	# plant's smack, a crumple's slump and a launch's whoosh. Positional, because they say
	# where somebody went down; the files ship in the addon, so the paths are its own.
	for row: Dictionary in GSPlayerDeathSounds.rows():
		var fall := GSAudioDef.new()
		fall.id = row["id"]
		fall.path = row["path"]
		fall.variants = row["variants"]
		fall.kind = GSAudioDef.Kind.POSITIONAL_3D
		fall.bus = &"SFX"
		fall.gain_db = float(row["gain_db"])
		fall.pitch_min = float(row["pitch_min"])
		fall.pitch_max = float(row["pitch_max"])
		fall.cooldown_ms = int(row["cooldown_ms"])
		fall.max_distance = 45.0
		fall.max_concurrent = 3
		fall.priority = 45
		c.add(fall)

	# The map's toys: gs-props' stock toy sounds (Kenney, CC0, and a horn made for it),
	# shipped in the addon. Under the fight in priority: a ball bouncing never takes a voice
	# from a shot.
	for row: Dictionary in GSPropBodySounds.rows():
		var toy := GSAudioDef.new()
		toy.id = row["id"]
		toy.path = row["path"]
		toy.variants = row["variants"]
		toy.kind = GSAudioDef.Kind.POSITIONAL_3D
		toy.bus = &"SFX"
		toy.gain_db = float(row["gain_db"])
		toy.pitch_min = float(row["pitch_min"])
		toy.pitch_max = float(row["pitch_max"])
		toy.cooldown_ms = int(row["cooldown_ms"])
		toy.max_distance = float(row["distance"])
		toy.max_concurrent = 3
		toy.priority = 30
		c.add(toy)


## [param def] with its [constant RECORDED] files, gain and pitch spread; unchanged for an id that has none.
static func recorded(def: GSAudioDef) -> GSAudioDef:
	var row: Array = RECORDED.get(def.id, [])
	if row.is_empty():
		return def
	var dir := recorded_directory(row[0])
	var variants := PackedStringArray()
	for i in range(int(row[2])):
		variants.append(dir.path_join("%s_%d.ogg" % [row[1], i]) if int(row[2]) > 1 else dir.path_join("%s.ogg" % row[1]))
	def.path = variants[0]
	def.variants = variants if variants.size() > 1 else PackedStringArray()
	def.gain_db = float(row[3])
	def.pitch_min = float(row[4])
	def.pitch_max = float(row[5])
	return def


## Where a [constant RECORDED] folder is in this build.
static func recorded_directory(folder: StringName) -> String:
	match folder:
		&"weapons":
			return GSAudioWeaponStock.directory()
		&"toys":
			return GSPropBodySounds.directory()
		&"fc":
			return FC_AUDIO_DIR
	return GSAudioStock.directory()


## Which synthesised voice stands in for each id in a build that lacks its file. Which noise belongs
## to which id is this game's decision, not an addon's guess from an id like `fire_rail`.
static func sound_recipes() -> Dictionary:
	var out := _base_recipes()
	for grenade in GRENADE_BLASTS:
		if blast_sound_id(grenade) != EXPLOSION:
			out[blast_sound_id(grenade)] = GSAudioSynth.Voice.BOOM
	out[KILL_CONFIRMED] = GSAudioSynth.Voice.IMPACT
	out[&"hit_head"] = GSAudioSynth.Voice.IMPACT
	out[&"hit_armor"] = GSAudioSynth.Voice.IMPACT
	for line: StringName in FcAnnouncer.LINES:
		out[FcAnnouncer.sound_id(line)] = GSAudioSynth.Voice.IMPACT
	out[STOMP_SOUND] = GSAudioSynth.Voice.IMPACT
	for id in MEDAL_VOICES:
		out[id] = MEDAL_VOICES[id]
	for id in FLAG_VOICES:
		out[id] = FLAG_VOICES[id]
	return out


static func _base_recipes() -> Dictionary:
	return {
		&"fire_rifle": GSAudioSynth.Voice.SHOT,
		&"fire_shotgun": GSAudioSynth.Voice.SHOT_HEAVY,
		&"fire_rail": GSAudioSynth.Voice.SHOT_TIGHT,
		&"impact": GSAudioSynth.Voice.IMPACT,
		EXPLOSION: GSAudioSynth.Voice.BOOM,
		&"hit_marker": GSAudioSynth.Voice.IMPACT,
		&"hurt": GSAudioSynth.Voice.HURT,
		&"died": GSAudioSynth.Voice.DIE,
		&"spawned": GSAudioSynth.Voice.SPAWN,
		&"pickup": GSAudioSynth.Voice.PICKUP,
		WALL_RUN_SOUND: GSAudioSynth.Voice.STEP,
		WALL_JUMP_SOUND: GSAudioSynth.Voice.IMPACT,
		BEACON_SOUND: GSAudioSynth.Voice.BLIP,
		# Up for a ballot opening, the one upward sweep, because up reads as "on"; a
		# blip for the warning and a click per second, so a countdown is heard without
		# being mistaken for a hit marker.
		FcVote.CUE_START: GSAudioSynth.Voice.SPAWN,
		FcVote.CUE_END: GSAudioSynth.Voice.PICKUP,
		FcVote.CUE_WARNING: GSAudioSynth.Voice.BLIP,
		FcVote.CUE_COUNT: GSAudioSynth.Voice.CLICK,
		# Stand-ins only for a build without gs-props' toy files.
		GSPropBodySounds.BOUNCE: GSAudioSynth.Voice.IMPACT,
		GSPropBodySounds.THUMP: GSAudioSynth.Voice.IMPACT,
		GSPropBodySounds.KNOCK: GSAudioSynth.Voice.IMPACT,
		GSPropBodySounds.PIN: GSAudioSynth.Voice.CLICK,
		GSPropBodySounds.WOOD: GSAudioSynth.Voice.IMPACT,
		GSPropBodySounds.RUBBER: GSAudioSynth.Voice.IMPACT,
		GSPropBodySounds.PUNCH: GSAudioSynth.Voice.HURT,
		GSPropBodySounds.METAL: GSAudioSynth.Voice.CLICK,
		GSPropBodySounds.BELL: GSAudioSynth.Voice.PICKUP,
		GSPropBodySounds.CLICK: GSAudioSynth.Voice.CLICK,
		GSPropBodySounds.WATER: GSAudioSynth.Voice.STEP,
		GSPropBodySounds.BOING: GSAudioSynth.Voice.SPAWN,
		GSPropBodySounds.HORN: GSAudioSynth.Voice.BLIP,
		# A body landing. The real files ship in gs-player-char; these stand in only on a
		# build that lacks them.
		GSPlayerDeathReactions.SOUND_THUD: GSAudioSynth.Voice.IMPACT,
		GSPlayerDeathReactions.SOUND_FACE_PLANT: GSAudioSynth.Voice.IMPACT,
		GSPlayerDeathReactions.SOUND_SLUMP: GSAudioSynth.Voice.STEP,
		GSPlayerDeathReactions.SOUND_WHOOSH: GSAudioSynth.Voice.SPAWN,
	}
