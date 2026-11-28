extends "headless_hitreg_hosted.gd"

## headless_hitreg_hosted with the hosted server's tick in GDScript: gs-sim's motor, mechanics, posture, hull world and
## controller columns off, so the rewind ring, the hitboxes and the trace are what the script path records and moves.
## The same taps must register the same way with the native tick on (headless_hitreg_hosted) and off (here).


func _suite() -> String:
	return "headless_hitreg_hosted_gd"


func _server_cvars() -> PackedStringArray:
	return PackedStringArray(["motor_native=0", "fc_mechanics_native=0", "fc_posture_native=0", "fc_hull_native=0", "ctl_native=0"])
