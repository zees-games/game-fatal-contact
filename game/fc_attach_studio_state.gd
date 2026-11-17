extends Control

const Dress := preload("res://addons/fc_weapons/view/aw_attachment_dress.gd")

## Asks for [param id] on [param mount]; an empty id takes it off.
signal requested(mount: StringName, id: StringName)
## The screen wants to close (ui_cancel, the Attachments key or the pad's B).
signal closed

## Seconds a slide or fade takes to settle (most of the way: an exponential approach).
@export var ease_seconds := 0.16
## Turns per second the right stick or arrow-drag spins the gun.
@export var spin_speed := 2.4

## The six bars: label, what feeds them, and whether less is better.
const STATS := [
	["Damage", &"damage"],
	["Accuracy", &"accuracy"],
	["Recoil control", &"recoil"],
	["Range", &"range"],
	["Handling", &"handling"],
	["Ammo", &"ammo"],
]
## Field names as a player reads them, and whether a smaller number is the better one.
const FIELDS := {
	"damage": ["Damage", false], "splash_damage": ["Splash damage", false], "recoil_pitch": ["Vertical recoil", true],
	"recoil_yaw": ["Horizontal recoil", true], "spread": ["Hip spread", true], "spread_moving": ["Moving spread", true],
	"magazine": ["Magazine", false], "reload_ticks": ["Reload time", true], "max_range": ["Range", false],
	"falloff_start": ["Falloff start", false], "pellets": ["Pellets", false],
}
const MOUNT_NAMES := {
	&"optic": "Optic", &"muzzle": "Muzzle", &"underbarrel": "Underbarrel", &"side": "Side rail",
	&"magazine": "Magazine", &"warhead": "Warhead",
}
## Chips above the gun; the rest go below it.
const TOP_LANE: Array[StringName] = [&"optic", &"muzzle", &"side", &"warhead"]

const INK := Color(0.93, 0.95, 0.97)
const DIM := Color(0.62, 0.66, 0.72)
const FAINT := Color(0.42, 0.46, 0.52)
const ACCENT := Color(1.0, 0.72, 0.18)
const GOOD := Color(0.36, 0.86, 0.48)
const BAD := Color(0.96, 0.36, 0.32)
const PLATE := Color(0.07, 0.08, 0.1, 0.82)
const PLATE_HI := Color(0.16, 0.17, 0.2, 0.92)

var _catalogue: DotWeaponAttachments
var _base: DotWeaponDef
var _fitting: DotWeaponFitting
var _peers: Array[DotWeaponDef] = []
var _choices: Dictionary = {}
var _mounts: Array[StringName] = []
var _slot := 0
var _row := 0
var _hover_row := -1
var _hover_chip := -1
var _shown := [&"", &""]  ## The [mount, id] the studio's gun wears beyond the fitting (none: the fitting itself).
var _pending := {}  ## mount -> id asked for and not yet answered.
var _pad := false
var _dragging := false
var _drag_moved := 0.0

# The studio.
var _port_box: SubViewportContainer
var _port: SubViewport
var _camera: Camera3D
var _pivot: Node3D
var _model: Node3D
var _art: AwWeaponVisual
var _dress := {}
var _box := AABB()
var _overlay: Control

# Eased state: target and shown.
var _yaw := -0.45
var _yaw_to := -0.45
var _pitch := -0.16
var _pitch_to := -0.16
var _zoom := 1.0
## Framing that keeps the chip rows clear of the gun: a distance factor (1 = the plain framing, more = further) and a
## vertical camera shift (world units), both eased toward what the last layout measured.
var _fit := 1.0
var _lift := 0.0
var _zoom_to := 1.0
var _user_zoom := 1.0
var _focus := Vector3.ZERO
var _focus_to := Vector3.ZERO
var _open_t := 0.0
var _slot_t := 1.0
var _bars_now: Array[float] = []
var _bars_then: Array[float] = []
var _bars_now_to: Array[float] = []
var _bars_then_to: Array[float] = []
var _row_glow: Array[float] = []
var _chips: Dictionary = {}  ## mount -> Rect2 as drawn (eased).
var _sockets: Dictionary = {}  ## mount -> Vector2 on screen.
var _time := 0.0

var _font: Font
var _font_bold: Font

## Scratch the per-frame layout and the option list fill and reuse, so a frame allocates nothing.
var _option_list: Array[StringName] = []
var _lane_top: Array = []
var _lane_low: Array = []
var _placed: Array[float] = []
