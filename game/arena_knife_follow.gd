extends RefCounted
## Keeps the client's copy of the knife rules on the server's `fc_knife_*` cvars, which are replicated
## (the throw meter's length and the boomerang's curve have to match what the server simulates).

const PREFIX := "fc_knife"


## [param source] is a client link with `replicated_cvar(name, fallback)` and a `replicated_cvar_changed(name, value)`
## signal. Call once per link. Applies what it holds now and every change after. False when it cannot follow.
static func follow(rules: Dictionary, source: Object) -> bool:
	if source == null or not is_instance_valid(source):
		return false
	if not source.has_method(&"replicated_cvar") or not source.has_signal(&"replicated_cvar_changed"):
		return false
	for suffix: String in DotWeaponKnives.CVAR_SPECS:
		var held := String(source.call(&"replicated_cvar", PREFIX + suffix, ""))
		if held != "":
			apply(rules, PREFIX + suffix, held)
	var on_change := func(cvar_name: String, value: String) -> void: apply(rules, cvar_name, value)
	source.connect(&"replicated_cvar_changed", on_change)
	return true


## One cvar into [param rules]; false for a name that is not a knife rule.
static func apply(rules: Dictionary, cvar_name: String, value: String) -> bool:
	if not cvar_name.begins_with(PREFIX):
		return false
	var spec: Variant = DotWeaponKnives.CVAR_SPECS.get(cvar_name.substr(PREFIX.length()), null)
	if spec == null:
		return false
	var key: String = spec[0]
	rules[key] = value.to_float() != 0.0 if rules.get(key, 0.0) is bool else value.to_float()
	return true
