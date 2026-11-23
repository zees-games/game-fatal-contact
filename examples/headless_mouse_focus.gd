extends GSGameCheckSuite

## A native window without focus never captures the cursor at load-in. Launched from the app shell the
## game window can load without focus; a captured cursor there is recentred by the OS and the motion
## it reports became random yaw and pitch (nightly fc-native-via-gs-app-1).

const SessionEvents := preload("../game/fc_client_session_events.gd")


func _ready() -> void:
	GSLog.set_level(GSLog.Level.FATAL)
	_run.call_deferred()


func _run() -> void:
	print("arena: the cursor is captured only by a focused native window")
	_check(SessionEvents.mouse_capture_now(false, true), "a focused native window captures the cursor")
	_check(not SessionEvents.mouse_capture_now(false, false), "an unfocused native window waits for a click")
	_check(not SessionEvents.mouse_capture_now(true, true), "a browser always waits for a click")
	_check(not SessionEvents.mouse_capture_now(true, false), "an unfocused browser waits for a click")
	_report()
	get_tree().quit(0 if _failed == 0 else 1)
