extends RefCounted

const FcPlayer := preload("fc_player.gd")

## The batched players' loop's event table dispatched by row (gs-player-controller 54): loaded by path only when the
## shell's controller has [code]dispatch_row[/code] ([method FcNativeTick.rows_dispatch]), so an older shell never
## parses the call. From level 54 a controller's end_tick holds its surface, modifier and simulated signals in its
## row instead of emitting them; [method dispatch] emits each row's events and those signals in roster order.


## Row by row: the derived events of each row's player, then the signals its end_tick held. [param ids] is the loop's
## roster (a row's entity is its index); a player gone since its row was recorded has its events skipped.
static func dispatch(events: GSFpsTickEvents, ids: Array[int], players: Dictionary) -> void:
	var cursor := 0
	for r in range(events.row_count):
		var e := events.entity_at(r)
		var player: FcPlayer = players.get(ids[e])
		if player == null:
			cursor = events.skip(cursor, e)
			continue
		cursor = player.controller.dispatch_row(events, r, cursor)
