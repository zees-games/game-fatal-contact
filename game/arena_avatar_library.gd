extends RefCounted

## Fatal Contact's side of the site's avatar library: what a member may equip here, and equipping it.
##
## dot-user-avatar's [DotAvatarLibraryClient] does the calls; this adds what only the game knows. The app id
## ([member app_id], the `sv_avatar_app_id` cvar) goes on every call, and the app's own switches
## ([DotAvatarAppRules]: emotes, poses and gestures each, wearables, and a rule per wearable) are honoured on this side
## as well as the site's. A value of 0 for the equip cap means unlimited. Nothing is clamped: a list over the cap, a kind
## the app has off, a wearable the app hid and an app id that was never set are each a failed [DotResult] that names the
## setting, never a shorter list.

const CHANNEL := "fc.avatar.library"

## The action kinds the library hands out.
const KINDS: Array[StringName] = [DotAvatarAppRules.EMOTE, DotAvatarAppRules.POSE, DotAvatarAppRules.GESTURE]

## The app (game) id on Gamespice that every library call is for. 0 = not set, which refuses every call.
static var app_id: int = 0


## A library client for this game's app. Fails with [code]invalid[/code] while the app id is unset.
static func client_for(http: DotHttp, base_url: String, headers: Dictionary = {}) -> DotResult:
	if app_id <= 0:
		return DotResult.fail(DotError.CODE_INVALID, "sv_avatar_app_id is not set: Fatal Contact cannot read the avatar library", str(app_id))
	return DotResult.success(DotAvatarLibraryClient.make(http, base_url, app_id, headers))


## Sets how many entries one avatar loadout message may carry and how many equipped actions of one kind the server
## accepts, both 0 = unlimited (dot-game's [DotGameAvatarLoadoutMessage] and [DotGameAvatarLoadouts]). A negative
## number is refused and leaves both as they were.
static func apply_loadout_limits(max_entries: int, max_per_kind: int) -> DotResult:
	if max_entries < 0 or max_per_kind < 0:
		return DotResult.fail(DotError.CODE_INVALID, "an avatar loadout limit is negative (0 = unlimited)", "%d, %d" % [max_entries, max_per_kind])
	DotGameAvatarLoadoutMessage.max_entries = max_entries
	DotGameAvatarLoadouts.max_per_kind = max_per_kind
	return DotResult.success(true)


## The actions this member may equip here: `{ max: int (0 = unlimited), by_kind: { emote: [..], pose: [..],
## gesture: [..] } }`. A kind the app has switched off is an empty list, not missing.
static func read_actions(client: DotAvatarLibraryClient, rules: DotAvatarAppRules) -> DotResult:
	var res: DotResult = await client.list_actions()
	if not res.ok:
		return res
	return DotResult.success(offered_actions(res.value, rules))


## [param answer] ([method DotAvatarLibraryClient.read_actions_list]'s value) with every kind the app has off emptied.
static func offered_actions(answer: Dictionary, rules: DotAvatarAppRules) -> Dictionary:
	var by_kind := {}
	for kind: StringName in KINDS:
		by_kind[kind] = (answer["by_kind"][String(kind)] as Array).duplicate() if rules.allows_kind(kind) else []
	return {"max": answer["max"], "by_kind": by_kind}


## Replaces one kind's equipped list. Refused, before any request, when the app has the kind off
## ([code]invalid[/code], naming the setting) or the list is over [param max_equipped] ([code]quota[/code]).
static func equip_actions(client: DotAvatarLibraryClient, rules: DotAvatarAppRules, kind: StringName, action_ids: Array, max_equipped: int) -> DotResult:
	if not KINDS.has(kind):
		return DotResult.fail(DotError.CODE_INVALID, "unknown avatar action kind", String(kind))
	if not rules.allows_kind(kind):
		return DotResult.fail(DotError.CODE_INVALID, "Fatal Contact has %s switched off (app setting actionsEnabled / %s)" % [String(kind), DotAvatarAppRules.KIND_SETTING[kind]], String(kind))
	return await client.equip_actions(String(kind).to_upper(), action_ids, max_equipped)


## The wearables this member may wear here: the site's rows less any the app's rules hide. Empty when wearables are off.
static func read_wearables(client: DotAvatarLibraryClient, rules: DotAvatarAppRules) -> DotResult:
	var res: DotResult = await client.list_wearables()
	if not res.ok:
		return res
	return DotResult.success(rules.filter_wearables(res.value))


## Puts one wearable on, or takes it off. Putting on is refused when wearables are off or the app hid this one;
## taking off is never refused, so a hidden wearable can always be removed.
static func set_wearable(client: DotAvatarLibraryClient, rules: DotAvatarAppRules, wearable_id: int, equipped: bool) -> DotResult:
	if equipped and not rules.allows_wearable(wearable_id):
		return DotResult.fail(DotError.CODE_INVALID, "Fatal Contact does not offer wearable %d (wearablesEnabled or a wearable rule)" % wearable_id, str(wearable_id))
	return await client.set_wearable(wearable_id, equipped)
