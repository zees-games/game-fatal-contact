extends Node

const FcBrowser := preload("fc_browser.gd")

## The server browser: gs-browser's client half, on a screen a player can open.
##
## [b]gs-server has answered queries since it was written and nothing had ever
## asked one.[/b] `FcModule` contributes a query provider, so a browser reading this
## server gets the mode, the map, the round and how far through it is — and until this
## file existed, the only thing in this family that could read it was a test. That is
## the family's own "produced correctly and consumed by nobody" with the ends swapped,
## and the answer is a client that asks.
##
## [b]Three protocols, and the reason there are three is deployment rather than
## taste.[/b] gs-browser speaks DQP over UDP for a desktop client, DQP as JSON over a
## WebSocket for a browser build — which cannot open a UDP socket at all — and A2S for
## the twenty years of trackers and tooling that speak nothing else.
## [constant GSBrowserTarget.Protocol.AUTO] picks, and it picks by asking
## [GSPlatform] what this build can do rather than by asking what platform it is on.
##
## [b]Filtering is local, and that is a rule rather than an optimisation.[/b] A server
## does not get to decide whether it appears in your list; you queried it, you hold the
## answer, and `GSBrowserFilter` runs over what you hold. A filter the server applied
## would be a filter the server could lie about.
##
## [codeblock]
## var browser := FcBrowser.new()
## add_child(browser)
## browser.setup()
## browser.add("play.example.com:27015")
## await browser.refresh()
## [/codeblock]

const CHANNEL := "arena.browser"

## The list changed: a refresh finished, or an entry answered.
signal listing_changed()

## The player asked to join one.
signal join_requested(entry: GSBrowserEntry)

@export_group("Querying")

## How many servers are asked at once.
@export_range(1, 64, 1) var concurrency: int = 8

@export_range(200, 15000, 100) var timeout_ms: int = 2500

@export_group("Favourites")

## Where favourites and history live. Empty keeps them in memory only.
@export var favourites_path: String = "user://arena/servers.json"

var browser: GSBrowser = null
var filter: GSBrowserFilter = null

var _started: bool = false


func setup() -> GSResult:
	if _started:
		return GSResult.success(self)

	browser = GSBrowser.new()
	browser.name = "Browser"
	browser.concurrency = concurrency
	browser.timeout_ms = timeout_ms
	browser.retries = 1
	# Info, players and the GAME section. Not rules: those are a server's whole cvar
	# table and a list does not draw them, so asking is a packet per server per refresh
	# for something nobody reads until they have picked one.
	#
	# [b]The game section is the reason `FcModule` has a query provider at all.[/b]
	# `info.map` is gs-server's, and gs-server means by it "the content id of the
	# game that is loaded" — which on a server that never `changegame`s is empty. What
	# a player wants to see is `atrium`, and that is the game's own fact, which is
	# why it arrives under `rules["game"]` rather than overwriting `info.map`.
	# gs-browser nests it deliberately: flattening would collide the first time a
	# game put a field called `map` in it, which is the first time.
	browser.sections = PackedStringArray(["info", "players", "game"])
	browser.conditional = true
	browser.favourites_path = favourites_path
	browser.register_as = GSBrowser.SERVICE
	add_child(browser)

	var started := browser.start()

	if not started.ok:
		return started.wrap("The server browser could not start")

	filter = GSBrowserFilter.new()
	filter.online_only = true
	filter.sort = GSBrowserFilter.Sort.PLAYERS
	filter.favourites_first = true
	browser.filter = filter

	browser.refresh_finished.connect(
		func(_online: int, _total: int) -> void: listing_changed.emit()
	)
	browser.entry_updated.connect(
		func(_entry: GSBrowserEntry) -> void: listing_changed.emit()
	)

	# Whatever the player kept last time. Loaded rather than assumed empty, because a
	# browser that forgot your favourites every launch is one nobody uses twice.
	var loaded := browser.load_favourites()

	GSLog.info(CHANNEL, "the server browser is up", {"favourites": loaded})

	_started = true
	return GSResult.success(self)


## Adds a server by address: `host`, `host:port`, or an IPv6 `[::1]:27015`.
##
## [b]The query port is a separate argument and not a third field in the string.[/b]
## `GSBrowserTarget.parse` takes `host:port` and a three-part string parses as a
## malformed IPv6 address — which fails at `connect_to_host` with "Invalid IPv6
## address", several layers below anything that could say what was wrong.
##
## Zero means "ask the game port", which is what a server that has not moved its query
## listener does. gs-server's default moves it, so a caller that knows both passes
## both: a browser asking the game port of a server whose queries are elsewhere gets
## no answer, and reports it as offline.
func add(address: String, query_port: int = 0) -> GSResult:
	if browser == null:
		return GSResult.fail(GSError.CODE_STATE, "The browser is not up.")

	var parsed := GSBrowserTarget.parse(address, FcBrowser.default_port())

	if not parsed.ok:
		return parsed

	var target := parsed.value as GSBrowserTarget

	if query_port > 0:
		target.query_port = query_port

	var entry := browser.add_target(target)
	listing_changed.emit()

	return GSResult.success(entry)


## The port a bare host is assumed to be on.
##
## gs-server's own default, not the long-standing 27015. A list that guessed the wrong
## port would report every server on it as offline, which reads as the browser being
## broken.
static func default_port() -> int:
	return 27015


func refresh() -> GSResult:
	if browser == null:
		return GSResult.fail(GSError.CODE_STATE, "The browser is not up.")

	var res: GSResult = await browser.refresh()
	return res


## What the list should show, filtered and sorted the way the player asked.
func listing() -> Array[GSBrowserEntry]:
	return browser.filtered() if browser != null else []


func favourite(key: String, on: bool) -> void:
	if browser == null:
		return

	if on:
		browser.favourite(key)
	else:
		browser.unfavourite(key)

	listing_changed.emit()


## Records that the player joined one, so it lands in their history.
func note_connected(key: String) -> void:
	if browser != null:
		browser.note_connected(key)


## What the game says about itself, from the query's `game` section.
##
## [b]Not `entry.map`.[/b] That is gs-server's `info.map`, which means "the content id
## of the loaded game" and is empty on a server that has never switched games. The map
## a player wants to read is the game's own, and it arrives nested so it cannot
## overwrite the other.
static func game_field(entry: GSBrowserEntry, key: String, fallback: String = "") -> String:
	if entry == null:
		return fallback

	var section: Variant = entry.rules.get("game")

	if not (section is Dictionary):
		return fallback

	return str((section as Dictionary).get(key, fallback))


func describe_lines() -> PackedStringArray:
	return browser.describe_lines() if browser != null else PackedStringArray()
