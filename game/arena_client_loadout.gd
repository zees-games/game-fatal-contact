extends "arena_client_state.gd"

## dot-auth's client, as the shell that signed the player in registers it. Absent solo
## without a shell, or from a shell that predates it: then every loadout is "local".
const AUTH_SERVICE := &"dot_auth_client"
var _account_auth: Object = null
var _loadout_restored := false
var _loadout_scratch := false
var _previews: Node = null
var _weapon_table: Dictionary = {}
## dot-menu's loadout menu, or null on a host whose dot-menu predates it (API 6).
var loadout_menu: Object = null

## The client's loadout menu: offering, choosing, restoring and keying a player's loadout to their account. Split out of arena_client_view.gd for file size.


## B: primary, sidearm, melee, grenades and gear, as cards with each weapon's picture and numbers. Solo the game's own loadouts answer; connected the server does (dot-loadout's
## `/loadout`), under the owner's `mp_loadout_*` rules. Guarded on the host's dot-menu and dot-loadout levels, so an older client shell still runs the game without it.
func _use_loadout_menu() -> void:
	if DotAddonApi.build_level("dot_menu") < 6 or DotAddonApi.build_level("dot_loadout") < 2:
		return
	if not game_menu.has_method(&"use_loadout"):
		return
	loadout_menu = game_menu.call(&"use_loadout", loadout_offer, choose_loadout, decorate_loadout_choice)
	if loadout_menu != null:
		_link_menu(loadout_menu)
		# Items the player does not own, greyed with a store button, solo and connected.
		if DotAddonApi.build_level("dot_game") >= 40:
			platform.add_loadout_store(loadout_menu, func() -> Object: return game.loadout_command if game != null else null,
					func() -> String: return ArenaGame.storage_key(player.player_id) if player != null else "")
		loadout_menu.set(&"random_fn", random_loadout)
		loadout_menu.set(&"random_spawn_fn", random_spawn_loadout)
		# Remembered under the signed-in site account (or "local" as a guest), and never
		# from a suite or a render on scratch settings: those must not write, or read back, a
		# player's real choice.
		_loadout_scratch = DotSettingsScratch.is_scratch(ArenaPresentation.settings_directory)
		follow_account(DotRegistry.get_node_service(AUTH_SERVICE))


## Joined to its own server process, nobody registers `dot_client_link`, so a menu that asks the
## server is handed the host's link; without it B took the solo path on a client with no loadouts.
func _link_menu(menu_part: Object) -> void:
	if menu_part != null and link != null and not _offline and &"link" in menu_part:
		menu_part.set(&"link", link)


## The key a loadout is remembered under for [param auth] (a DotAuthClient, or null): its
## account's public id when signed in, "local" for a guest or a client with no auth. Never a
## token. Untyped because a shell older than dot-auth's `account_key` has no such method.
static func loadout_account_key(auth: Object) -> String:
	if auth == null or not is_instance_valid(auth) or not auth.has_method(&"account_key"):
		return "local"
	var key := str(auth.call(&"account_key"))
	return key if key != "" else "local"


## Files the loadout under [param auth]'s account from now on, and again whenever the player
## signs in or out mid-session (a different account's choice is then the one restored).
func follow_account(auth: Object) -> void:
	if _account_auth != null and is_instance_valid(_account_auth):
		for sig: StringName in [&"signed_in", &"signed_out"]:
			if _account_auth.is_connected(sig, _on_account_changed):
				_account_auth.disconnect(sig, _on_account_changed)
	_account_auth = auth
	if auth != null and is_instance_valid(auth):
		for sig: StringName in [&"signed_in", &"signed_out"]:
			if auth.has_signal(sig):
				auth.connect(sig, _on_account_changed)
	_rekey_loadout()


func _on_account_changed(_identity: Variant = null) -> void:
	_rekey_loadout()
	if _loadout_restored:
		_loadout_restored = false
		_restore_loadout()


func _rekey_loadout() -> void:
	if loadout_menu != null:
		loadout_menu.call(&"remember_as", "" if _loadout_scratch else "arena", loadout_account_key(_account_auth))


## Solo: what this player may pick, from the game's own manager.
func loadout_offer() -> Variant:
	if game == null or game.loadout_command == null or player == null:
		return DotResult.fail(DotError.CODE_STATE, "Join the match first.")
	return await game.loadout_command.call(&"offer", ArenaGame.storage_key(player.player_id))


## Solo: saves [param picks], and hands them over now in warmup or spawn protection.
func choose_loadout(picks: Dictionary) -> Variant:
	if game == null or game.loadout_command == null or player == null:
		return DotResult.fail(DotError.CODE_STATE, "Join the match first.")
	return await game.loadout_command.call(&"choose", null, ArenaGame.storage_key(player.player_id), picks)


## Solo: rolls a random loadout under the same `mp_loadout_random*` rules the server applies.
func random_loadout() -> Variant:
	if game == null or game.loadout_command == null or player == null:
		return DotResult.fail(DotError.CODE_STATE, "Join the match first.")
	return await game.loadout_command.call(&"choose_random", null, ArenaGame.storage_key(player.player_id))


## Solo: the "random every spawn" toggle, under the same `mp_loadout_random_on_spawn` rule.
func random_spawn_loadout(on: bool) -> Variant:
	if game == null or game.loadout_command == null or player == null:
		return DotResult.fail(DotError.CODE_STATE, "Join the match first.")
	return await game.loadout_command.call(&"set_random_spawn", ArenaGame.storage_key(player.player_id), on)


## The card pictures' cache, made on first use. The load cover has it render every weapon through one viewport
## ([method AwWeaponPreview.warm]), so pressing B finds them all drawn instead of making 27 render targets.
func weapon_previews() -> AwWeaponPreview:
	if _previews == null:
		_previews = AwWeaponPreview.new()
		_previews.name = "WeaponPreviews"
		add_child(_previews)
	return _previews


## A card's picture (the HUD's rendered weapon silhouettes) and numbers (fc-weapons' cards).
func decorate_loadout_choice(_slot_id: String, choice: Dictionary) -> Dictionary:
	var id := StringName(str(choice.get("id", "")))
	var out: Dictionary = {}
	var icon: Texture2D = weapon_previews().texture(id)
	if icon == null:
		icon = ArenaWeaponIcons.shared.menu_texture(id)
	if icon == null:
		icon = ArenaHudGlance.Ink.weapon_icon(id)
	if icon != null:
		out["icon"] = icon
	if id == &"armour":
		out["detail"] = "Takes half of every hit until it wears through."
		out["kind"] = "Gear"
		out["stats"] = [{"label": "Armour", "value": 1.0, "text": "100"}]
		return out
	if _weapon_table.is_empty():
		_weapon_table = ArenaContent.weapon_table()
	if _weapon_table.has(id):
		out.merge(AwWeaponCards.card(_weapon_table[id]))
	return out


## Sends the choice this player saved last time (dot-menu remembers it on this device), once
## per join: solo into the game's own manager, connected to the server.
func _restore_loadout() -> void:
	if loadout_menu == null or _loadout_restored:
		return
	_loadout_restored = true
	var _sent: Variant = await loadout_menu.call(&"restore")
