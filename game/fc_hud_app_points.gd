extends RefCounted
## The app's points balance on the HUD (Gamespice per-app points, fc_app_wiring.gd). The server
## replicates it to its owner only (`net_app_points_on`, `net_app_points`); the label is hidden
## unless the app has points on and the grant verified, so a game with no app shows nothing.

## Where it sits: top left, under the match points count.
const OFFSET := Vector2(0.0, 34.0)
const INK := Color(0.55, 0.85, 1.0)


## The label's text for [param balance].
static func text_of(balance: int) -> String:
	return "App points %d" % balance


## Shows [param player]'s balance on [param label], or hides it. Returns whether it is shown.
static func present(label: Label, player: Object) -> bool:
	var on := player != null and bool(player.get(&"app_points_on"))
	label.visible = on
	label.text = text_of(int(player.get(&"app_points"))) if on else ""
	return on
