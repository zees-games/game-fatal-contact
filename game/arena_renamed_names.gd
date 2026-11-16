extends RefCounted

## The console names that were `arena_*` before the game became Fatal Contact, kept as loud
## shims for one release: typing an old name runs the new one, after an ERR in the log and a
## reply that both name the new name. Nothing old works silently, and nothing old is listed
## (every shim is a hidden command, so `cvarlist` and `cmdlist` show only the new names).
##
## [b]Remove this file[/b] (and its call at the end of `ArenaModule._module_load`) once the
## deployed configs say `fc_*`; the nightly board tracks it.

const OLD_PREFIX := "arena_"
const NEW_PREFIX := "fc_"

## Old names whose new name is not `fc_` + the rest: the map change is dot-map's `map`
## (`arena_maps` is `fc_maps`, the listing that credits authors) and the stats report is dot-game's family cvar.
const MOVED := {
	"arena_map": "map",
	"arena_stats_report": "stats_report",
}


## Registers a shim for every `fc_*` name on the console (the module's own and the ones its
## binders put there) whose `arena_*` twin is free, plus [constant MOVED], through
## [param module] so they unload with it. Returns the old names it registered.
static func install(module: DotModule) -> PackedStringArray:
	var made := PackedStringArray()
	var console: DotConsole = module.console
	if console == null:
		return made

	var pairs := {}
	for name: String in console.cvar_names() + console.command_names():
		if name.begins_with(NEW_PREFIX):
			pairs[OLD_PREFIX + name.substr(NEW_PREFIX.length())] = name
	for old: String in MOVED:
		pairs[old] = MOVED[old]

	for old: String in pairs:
		var target: String = pairs[old]
		if console.has_name(old) or not console.has_name(target):
			continue
		var cmd := module.add_command(old, _forward.bind(console, old, target), "Renamed: use %s" % target, "")
		if cmd == null:
			continue
		cmd.hidden = true
		var real := console.find_command(target)
		if real != null:
			cmd.chat_policy = real.chat_policy
			cmd.rcon_allowed = real.rcon_allowed
		made.append(old)

	return made


## Runs [param target] with the caller's own context (so its permission, cheat and chat gates
## apply as if the new name was typed), after saying loudly that the name changed.
static func _forward(ctx: DotCmdContext, console: DotConsole, old: String, target: String) -> void:
	var why := "%s was renamed to %s; update your config" % [old, target]
	DotLog.error("console", why, {"old": old, "new": target})
	ctx.reply("ERROR: " + why)

	var line := target
	for arg: String in ctx.args:
		line += " " + (arg if not (arg.contains(" ") or arg.contains(";") or arg.is_empty()) else "\"%s\"" % arg)
	var _ran := console.execute(line, ctx)
