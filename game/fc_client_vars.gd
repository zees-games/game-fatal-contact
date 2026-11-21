extends "fc_client_bots.gd"

const FcFlashlight := preload("fc_flashlight.gd")
const FcMatchText := preload("fc_match_text.gd")
const FcTeamMenu := preload("fc_team_menu.gd")
const FcWeaponDropWiring := preload("fc_weapon_drop_wiring.gd")
const FcTouch := preload("fc_touch.gd")

## Offline only: the team menu's rules run in this process (online the server's do).
var _local_team_menu: FcTeamMenu = null

## Whether the local player was alive last frame, for [method _face_a_respawn].
var _was_alive: bool = true

## How near a respawn has to land to a map spawn to take its yaw, in metres. The server
## puts a player exactly on one; anything further is somewhere else entirely.
const SPAWN_FACE_REACH := 2.0

## The roof probe's mask, looked up once per layout rather than built every frame.
var _roof_layout: GSPhysicsLayout = null
var _roof_mask := 0
var _tag_mask := 0

const OWN_BODY_CHOICES: Array[StringName] = [&"auto", &"off", &"legs", &"body"]

## Set by a headless suite to answer [method mouse_drives_view] without a display
## server. Left null in play, where the real mouse mode is the only honest answer.
var mouse_capture_override: Variant = null
