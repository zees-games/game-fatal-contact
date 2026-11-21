extends "fc_events_tail.gd"

const MAP_BYTES := 64
## Rows (players, or teams) one SCORE event may carry: the scoreboard's own record limit.
const MAX_SCORE_ROWS := 512

## The score table decoding of the event wire. Split out of fc_events.gd for file size.


static func read_scores(reader: GSNetReader) -> Dictionary:
	var rows: Array[Dictionary] = []
	var teams := {}
	var count := reader.read_varint()
	# A count above any real server is a corrupt body: refuse it rather than loop on it.
	var sane := count <= MAX_SCORE_ROWS
	if reader.ok() and sane:
		for i in count:
			rows.append({
				"session_id": reader.read_varint(),
				"kills": reader.read_varint(),
				"deaths": reader.read_varint(),
				"assists": reader.read_varint(),
				"score": reader.read_svarint(),
				"objectives": reader.read_varint(),
			})
		var team_count := reader.read_varint()
		sane = team_count <= MAX_SCORE_ROWS
		if reader.ok() and sane:
			for i in team_count:
				var team := reader.read_varint()
				teams[team] = reader.read_svarint()
	return {"rows": rows, "teams": teams, "ok": reader.ok() and sane}
