extends RefCounted

## cl_scope_body: draw a lens-mode scope as the gun's own scope (body, ocular and magnified glass) rather than a
## flat circle over a hidden gun. Its own script, not FcScopePrefs: a static var there would sit in gs-weapon's shared prefs.

## On by default off the web; the web build keeps the flat lens it had.
static var body := not OS.has_feature("web")


## Gives [param model] this machine's scope-body choice; a view model without the setting (an older fc-weapons) is left alone.
static func apply(model: Object) -> void:
	if model != null and &"scope_body" in model:
		model.set(&"scope_body", body)


## Registers `cl_scope_body` on [param local] (a GSConsoleLocal).
static func bind_cvars(local: Object) -> void:
	local.call(&"add_var", &"cl_scope_body", "Scope lens view (cl_scope_mode 1): 1 shows the rifle's own scope with the zoom in its eyepiece, 0 a flat lens over a hidden gun.",
		func() -> Variant: return 1 if body else 0,
		func(v: Variant) -> Variant:
			body = str(v).to_int() != 0
			return GSResult.success(1 if body else 0)
	)
