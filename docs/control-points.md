# Control points in a map manifest

A map hosts Fatal Contact's control point mode (`cp`, [modes](modes.md#control-point)) when its manifest lists `cp` in `modes` and carries a `control_points` list. This page is the schema, for anybody writing a map importer or converter. The reader is `FcBspMap.control_points_of` (`maps/fc_bsp_map.gd`); it reads the same manifest the spawns and `flag_spawns` come from, and depends on no map name prefix.

```json
{
  "modes": ["tdm", "ctf", "cp"],
  "control_points": [
    {"id": "cp1", "name": "Red base", "index": 1, "origin": [-2944, 0, 128], "radius": 160, "owner": "red"},
    {"id": "cp2", "index": 2, "origin": [-1200, 0, 64]},
    {"id": "cp3", "index": 3, "origin": [0, 0, 0], "capture_seconds": 12},
    {"id": "cp4", "index": 4, "origin": [1200, 0, 64]},
    {"id": "cp5", "name": "Blue base", "index": 5, "origin": [2944, 0, 128], "owner": "blue"}
  ]
}
```

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `index` | int | its place in the list, from 1 | the point's place in the line, 1 at red's end |
| `order` | int | `index` | sort key when it differs from `index` (lowest first) |
| `id` | string | `cp<index>` | stable id; it travels on the wire, so keep it across map versions |
| `name` | string | `Point <index>` | display name in chat ("Red captured Red base"); a trailing `!` is dropped |
| `origin` | [x, y, z] | [0, 0, 0] | the point's centre, in the manifest's own axes and units, exactly like a spawn `origin` |
| `radius` | number | 160 | capture radius in map units (the cylinder is 5 m tall about the origin) |
| `owner` | `"red"`, `"blue"` or `""` | `""` | who holds it at round start |
| `capture_seconds` | number | 8 | time for one capper to take it (more cappers are faster) |

Rules a converter should keep:

- The line runs from red's end to blue's: the lowest `order` should be owned by red and the highest by blue. Red takes a point only when it holds the one before it, blue only when it holds the one after it, so an owner in the middle of the line splits it.
- Write at least two points, each with an `origin`: one without it sits at the map origin.
- Source-engine maps: `team_control_point` entities give `index` (`point_index`), `name` (`point_printname`) and `owner` (`point_default_owner`: 2 is red, 3 is blue); the radius is the matching `trigger_capture_area`'s extent if you read it, else leave it out.
- Add `cp` to `modes` only once the points are right: the vote offers the mode on a map only then.

A map without `control_points` still runs the mode (three points along its longest axis), which is how the built-in maps host it; that is a fallback, not a layout.
