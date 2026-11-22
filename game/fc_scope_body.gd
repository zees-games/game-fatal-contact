extends RefCounted

## cl_scope_body: draw a lens-mode scope as the gun's own scope (body, ocular and magnified glass) rather than a
## flat circle over a hidden gun. Its own script, not FcScopePrefs: a static var there would sit in gs-weapon's shared prefs.

const CHANNEL := &"fc.scope"

## GSWeaponScopeView.FULL: the scope fills the screen. (The view model's own `scope_mode` int.)
const FULL_SCOPE := 2

## On everywhere. Off, the lens view hides the gun and arms and draws only a flat circle: on the web build (where it was
## off) a scoped sniper showed a lens over nothing (2026-11-22).
static var body := default_body(OS.has_feature("web"))

## Scope styles already reported as having no ocular, so the warning prints once per weapon, not every frame.
static var _warned: Dictionary = {}


## The scope-body default for a platform: on for both, so the scoped gun is never hidden behind a bare lens.
static func default_body(_web: bool) -> bool:
	return true


## Gives [param model] this machine's scope-body choice; a view model without the setting (an older fc-weapons) is left alone.
## A scoped lens view that wants the body but cannot draw it (the weapon's own scope style has no `ocular`: a 6x Scope
## attachment on a gun that has no scope of its own) would hide the gun and arms behind a bare lens circle, so that view
## is the full-screen scope instead (logged once per style at info level: it is the design, not a fault).
static func apply(model: Object) -> void:
	if model == null or not &"scope_body" in model:
		return
	model.set(&"scope_body", body)
	if body and model.has_method(&"scope_body_active") and model.call(&"is_scoped") and model.call(&"scope_is_lens") \
			and not model.call(&"scope_body_active"):
		model.set(&"scope_mode", FULL_SCOPE)
		var style: Dictionary = model.call(&"scope_style")
		var key := str(style.hash())
		if not _warned.has(key):
			_warned[key] = true
			GSLog.info(CHANNEL, "scoped lens view with no scope body (no ocular in the scope style): full-screen scope instead", {"style": str(style)})


## Registers `cl_scope_body` on [param local] (a GSConsoleLocal).
static func bind_cvars(local: Object) -> void:
	local.call(&"add_var", &"cl_scope_body", "Scope lens view (cl_scope_mode 1): 1 shows the rifle's own scope with the zoom in its eyepiece, 0 a flat lens over a hidden gun.",
		func() -> Variant: return 1 if body else 0,
		func(v: Variant) -> Variant:
			body = str(v).to_int() != 0
			return GSResult.success(1 if body else 0)
	)
