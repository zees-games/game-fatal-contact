extends GSGameCheckSuite

const FcAwards := preload("../game/fc_awards.gd")
const FcBoards := preload("../game/fc_boards.gd")
const FcContent := preload("../game/fc_content.gd")
const FcEffects := preload("../game/fc_effects.gd")
const FcEvents := preload("../game/fc_events.gd")
const FcFlashlight := preload("../game/fc_flashlight.gd")
const FcGame := preload("../game/fc_game.gd")
const FcHorde := preload("../game/fc_horde.gd")
const FcHud := preload("../game/fc_hud.gd")
const FcMap := preload("../maps/fc_map.gd")
const FcMapDirector := preload("../game/fc_map_director.gd")
const FcWeaponRoles := preload("../game/fc_weapon_roles.gd")
const FcMapLighting := preload("../maps/fc_map_lighting.gd")
const FcMapPaint := preload("../maps/fc_map_paint.gd")
const FcMaps := preload("../game/fc_maps.gd")
const FcMapSurvey := preload("../maps/fc_map_survey.gd")
const FcHudGlance := preload("../game/fc_hud_glance.gd")
const FcMenus := preload("../game/fc_menus.gd")
const FcMode := preload("../game/fc_mode.gd")
const FcModes := preload("../game/fc_modes.gd")
const FcModule := preload("../game/fc_module.gd")
const FcNpcs := preload("../game/fc_npcs.gd")
const FcPlayer := preload("../game/fc_player.gd")
const FcProjectiles := preload("../game/fc_projectiles.gd")
const FcProps := preload("../game/fc_props.gd")
const FcStats := preload("../game/fc_stats.gd")
const FcVote := preload("../game/fc_vote.gd")
const WallRouteDriver := preload("wall_route_driver.gd")
const FcWeaponIcons := preload("res://game/fc_weapon_icons.gd")

## A whole deathmatch played out headlessly with nothing called by hand; exits non-zero on failure.

const TICK_RATE := 64
const BOTS := 4
var _stats_errors: PackedStringArray = []

const SCORE_LIMIT := 6

## Enough ticks for six kills at FC pace. Bounded rather than "until it ends", so a
## match that never ends fails the test instead of hanging the run. 150 s since head x2
## (fc-weapon-damage-audit-1): a rifle needs 3 head rounds, not 2, and 90 s left the leader at 5.
const MAX_TICKS := 64 * 150

const CHECKS := 732

## Sections entered against sections that ran to their last line. A runtime error aborts a section silently, and a section that
## bailed out after a failed guard counts as unfinished on purpose. The CHECKS total is the other half (docs/testing.md).
const SECTIONS := 47

var _entered := 0
var _completed := 0

var _game: FcGame = null

## Observations gathered while the match runs. Arrays rather than counters: a lambda captures locals by value, so an int
## incremented in a signal handler stays zero outside it and the assertion blames a signal that fired.
var _kills: Array[GSKillFeed.Entry] = []

## The map vote riding along on the real match: what state the match was in, and what the
## leader had, each time a ballot opened. See [method _build_vote].
var _vote: FcVote = null
var _vote_seen: Array = []
var _spawns: Array[int] = []
var _states: Array[String] = []

var _toy_views: Array = []

var _lowest_y := INF
var _furthest := 0.0
var _grounded_ticks := 0
