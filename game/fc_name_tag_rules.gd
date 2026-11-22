extends RefCounted

## When a name tag and a health bar draw over another player: the pure rules, no nodes. A setting is a set of reasons to show: [constant ALL], [constant TEAM] (a team-mate), [constant HOVER] (the cursor is on the body) and [constant HURT] (hurt in the last few seconds).
## The player's choice (settings `name_tags`, `health_bars`) and the server's (`mp_nametags`, `mp_hpbars`, replicated in RULES as these masks) are both sets, and a tag draws only when BOTH allow it: the server's value is a ceiling the client can narrow and never widen.
## Written as a preset (`smart`) or a list (`team,hover`) in a setting, a cvar or a config.

const ALL := 1
const TEAM := 2
const HOVER := 4
const HURT := 8

## Preset -> mask. `smart` is the bar's default: team-mates always, anybody under the cursor or just hurt.
const PRESETS := {
	&"off": 0, &"always": ALL, &"team": TEAM, &"hover": HOVER, &"hurt": HURT,
	&"team_hover": TEAM | HOVER, &"smart": TEAM | HOVER | HURT,
}
const TOKENS := {
	"off": 0, "none": 0, "all": ALL, "always": ALL, "team": TEAM, "teammates": TEAM,
	"hover": HOVER, "cursor": HOVER, "aim": HOVER, "hurt": HURT, "smart": TEAM | HOVER | HURT,
}

## Farthest a body can be and still count as under the cursor, metres, unless the server's `mp_hover_range` says otherwise.
const MAX_RANGE := 80.0
## Half-width of the body the cursor must touch to count as over it, metres.
const BODY_RADIUS := 0.55

## The player's own picks, the server's ceilings, and who is looking. Written each frame by the client.
static var client_names: int = TEAM | HOVER
static var client_bars: int = TEAM | HOVER | HURT
static var server_names: int = ALL
static var server_bars: int = ALL
static var viewer_id: int = -1
static var viewer_team: int = -1  # -1: a free-for-all, nobody is a team-mate
## Sides in play (spectators not counted) and each side's colour, so a bar can wear a side's colour when there are more than two.
static var team_count: int = 0
static var team_colours: Dictionary = {}
## Bar colour: &"team" (red enemies, light green mates, a side's own colour with 3+ sides) or &"health" (the old green-to-red by health).
static var bar_colour_mode: StringName = &"team"
## Size of the bar and name against the original, and the metres above the feet the tag floats at.
static var tag_scale: float = 0.7
## What size a tag may take ON SCREEN, as a multiple of the size it has at [constant REFERENCE_DISTANCE]: a tag in the world
## grows as you walk up to it (huge at arm's length) and shrinks to nothing far off. The world scale is eased so the picture stays
## between these two. 0 on either side leaves that side unlimited (the tag then follows perspective alone).
static var screen_scale_min: float = 0.4
static var screen_scale_max: float = 1.5
const REFERENCE_DISTANCE := 10.0
static var tag_height: float = 2.0
const ENEMY_COLOUR := Color(1.0, 0.25, 0.22)
const FRIEND_COLOUR := Color(0.55, 1.0, 0.55)
static var occluder_mask: int = 0  # physics layers that hide a body from the cursor; 0 skips the test

## The server's look of the tags (cvars `mp_enemy_*`, `mp_hover_*`, `mp_team_*`, `mp_show_team_names`, `mp_tag_fade_*`; RULES): synced each frame
## with the masks above. An ENEMY's bar and name are their own modes: 0 never, 1 only while the cursor is on them (then it lingers
## [member hover_hold] seconds and fades over [member hover_fade]), 2 always. The defaults show an enemy's name on hover and no bar.
static var enemy_bar_mode: int = 0
static var enemy_name_mode: int = 1
static var hover_range: float = MAX_RANGE  # metres; 0 = unlimited
static var hover_hold: float = 0.35
static var hover_fade: float = 0.25
## A team-mate's tag hangs [member team_offset_y] metres from the head anchor ([member tag_height]; negative = lower), its bar is
## [member team_bar_width] by [member team_bar_height] metres, styled 0 classic glass or 1 modern slim, and wears the name when [member show_team_names].
static var team_offset_y: float = -0.3
static var team_bar_width: float = 0.8
static var team_bar_height: float = 0.065
static var team_bar_style: int = 1
static var show_team_names: bool = true
## Tags fade out between these distances (metres) from the eye; [member fade_end] 0 turns the fade off.
static var fade_start: float = 25.0
static var fade_end: float = 60.0


## The world scale a tag of [param base] gets at [param distance] metres from the eye, so that its size on screen stays within
## [member screen_scale_min] and [member screen_scale_max] times its size at [constant REFERENCE_DISTANCE]. On screen a tag is
## `scale / distance`, so the multiple it would have is `REFERENCE_DISTANCE / distance`; outside the limits it is held at the limit.
static func distance_scale(base: float, distance: float) -> float:
	if distance <= 0.001:
		return base
	var multiple := REFERENCE_DISTANCE / distance
	var held := multiple
	if screen_scale_max > 0.0:
		held = minf(held, screen_scale_max)
	if screen_scale_min > 0.0:
		held = maxf(held, screen_scale_min)
	return base * held / multiple


## Whether an enemy's tag part set to [param mode] (0 never, 1 on hover, 2 always) draws when the cursor is [param hovered].
static func enemy_shows(mode: int, hovered: bool) -> bool:
	return mode >= 2 or (mode == 1 and hovered)


## Whether the player's own mask lets enemies be seen at all (a team-only or off mask narrows them away).
static func client_allows_enemy(mask: int) -> bool:
	return (mask & (ALL | HOVER | HURT)) != 0


## Opacity of a hover reveal [param age] seconds after the cursor left: 1 for [member hover_hold], then down to 0 over [member hover_fade].
static func hover_opacity(age: float) -> float:
	if age <= hover_hold:
		return 1.0
	if hover_fade <= 0.0 or age >= hover_hold + hover_fade:
		return 0.0
	return 1.0 - (age - hover_hold) / hover_fade


## Opacity of a tag [param distance] metres from the eye: 1 up to [member fade_start], 0 from [member fade_end], smooth between (no fade when [member fade_end] is 0).
static func distance_opacity(distance: float) -> float:
	if fade_end <= 0.0 or distance <= fade_start:
		return 1.0
	if distance >= fade_end:
		return 0.0
	var t := (distance - fade_start) / (fade_end - fade_start)
	return 1.0 - t * t * (3.0 - 2.0 * t)


## A mask from [param text] (a preset or tokens split on , + | space _), or -1 when anything in it is unknown.
static func parse(text: String) -> int:
	var clean := text.strip_edges().to_lower()
	if clean == "":
		return -1
	if PRESETS.has(StringName(clean)):
		return PRESETS[StringName(clean)]
	var mask := 0
	for token in clean.replace("+", ",").replace("|", ",").replace(" ", ",").replace("_", ",").split(",", false):
		if not TOKENS.has(token):
			return -1
		mask |= int(TOKENS[token])
	return mask


## [param mask] as a cvar echoes it.
static func describe(mask: int) -> String:
	if mask == 0:
		return "off"
	if mask & ALL:
		return "always"
	var parts: PackedStringArray = []
	for part: String in ["team", "hover", "hurt"]:
		if mask & int(TOKENS[part]):
			parts.append(part)
	return ",".join(parts)


## Whether [param mask] admits somebody who is (or is not) a team-mate, under the cursor, recently hurt.
static func admits(mask: int, is_team: bool, hovered: bool, hurt: bool) -> bool:
	return (mask & ALL) != 0 or (is_team and (mask & TEAM) != 0) \
		or (hovered and (mask & HOVER) != 0) or (hurt and (mask & HURT) != 0)


## Whether a tag draws, given the player's mask and the server's.
static func shows(client: int, server: int, is_team: bool, hovered: bool, hurt: bool) -> bool:
	return admits(client, is_team, hovered, hurt) and admits(server, is_team, hovered, hurt)


## The colour of the bar over somebody on [param other_team]: red for an enemy, light green for a team-mate, and
## their own side's colour when more than two sides play.
static func bar_tone(friend: bool, other_team: int) -> Color:
	if team_count > 2 and team_colours.has(other_team):
		return team_colours[other_team]
	return FRIEND_COLOUR if friend else ENEMY_COLOUR


## Whether either mask needs the cursor test at all (it costs a ray).
static func needs_hover(a: int, b: int) -> bool:
	return ((a | b) & HOVER) != 0 and ((a & b) & ALL) == 0


## Whether somebody with [param other_id] on [param other_team] is a team-mate of the viewer.
static func is_teammate(other_id: int, other_team: int) -> bool:
	return viewer_team >= 0 and other_id != viewer_id and other_team == viewer_team


## Whether the ray [param from] along [param dir] (unit) passes within [constant BODY_RADIUS] of the upright
## body standing at [param feet] and [param height] tall, in front of the eye and within [param max_range] (0 = unlimited).
static func ray_hits_body(from: Vector3, dir: Vector3, feet: Vector3, height: float, max_range: float = MAX_RANGE) -> bool:
	# Closest points of a ray and a vertical segment: solve for the segment's parameter, clamp, then the ray's.
	var w := from - feet
	var denom := height * (dir.y * dir.y - 1.0)
	var s := 0.5 if absf(denom) < 0.0001 else (dir.y * dir.dot(w) - w.y) / denom
	s = clampf(s, 0.0, 1.0)
	var on_segment := feet + Vector3(0.0, height * s, 0.0)
	var t := dir.dot(on_segment - from)
	if t <= 0.0 or (max_range > 0.0 and t > max_range):
		return false
	return (from + dir * t).distance_to(on_segment) <= BODY_RADIUS


## The two player settings, declared into the presentation schema.
static func declare_settings(s: DotSettingsSchema) -> void:
	s.add(DotSettingsDef.number(&"nametag_min_scale", screen_scale_min, 0.0, 10.0, &"video").with_description("Smallest a name tag may look on screen, against its size 10 m away. Far tags stop shrinking here. 0 is no limit."))
	s.add(DotSettingsDef.number(&"nametag_max_scale", screen_scale_max, 0.0, 10.0, &"video").with_description("Largest a name tag may look on screen, against its size 10 m away. Close tags stop growing here. 0 is no limit."))
	s.add(DotSettingsDef.choice(&"name_tags", &"team_hover", [&"always", &"team", &"team_hover", &"hover", &"off"], &"video").with_description("Names over other players' heads: everybody, team-mates, team-mates and whoever your cursor is on, only the cursor, or none. A server may allow fewer (mp_nametags)."))
	s.add(DotSettingsDef.choice(&"health_bar_colour", &"team", [&"team", &"health"], &"video").with_description("Health bar colour: team colours (enemies red, team-mates light green, a side's own colour with more than two sides) or by how much health is left."))
	s.add(DotSettingsDef.choice(&"health_bars", &"smart", [&"always", &"smart", &"team", &"team_hover", &"hover", &"off"], &"video").with_description("Health bars over other players: smart is team-mates, whoever your cursor is on and anybody just hurt. A server may allow fewer (mp_hpbars)."))
