extends RefCounted

const FcNewerApi := preload("fc_newer_api.gd")

## The gs-weapon level with charged throws; below it there is no wind-up and no meter.
const CHARGE_LEVEL := 41
## The knife throw's power meter on the client: how long the local player has held the aim key with the knife in hand, and the fill that is under the followed rules (gs-weapon's
## `GSWeaponKnives.fill_fraction`). The server owns the throw; this only mirrors its wind-up (`fc_knife_throw_charge`, `_charge_sec`) so the bar needs no network traffic. Plain values in and out, so a
## suite can drive it without a frame.

var held: float = 0.0


## Adds [param delta] seconds while [param winding] (aim held, knife in hand, charge on), else resets.
## Returns the meter's fill 0..1, or -1 when there is no wind-up to show.
func advance(delta: float, winding: bool, rules: Dictionary) -> float:
	if not winding or not bool(rules.get("enabled", true)) or not bool(rules.get("charge", false)) \
			or GSAddonApi.build_level("gs_weapon") < CHARGE_LEVEL:
		held = 0.0
		return -1.0
	held += maxf(delta, 0.0)
	return float(FcNewerApi.call_static(&"GSWeaponKnives", &"fill_fraction", [rules, held]))


## The throw speed the release would leave with now, as a fraction of the full throw.
func power(rules: Dictionary) -> float:
	if GSAddonApi.build_level("gs_weapon") < CHARGE_LEVEL:
		return 1.0
	return float(FcNewerApi.call_static(&"GSWeaponKnives", &"power_fraction", [rules, held]))
