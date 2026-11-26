extends "fc_presentation_setup.gd"

const FcAwardStore := preload("fc_award_store.gd")


# --- Settings ---------------------------------------------------------------


## Points every [FcPresentation] made after this at a fresh, empty settings directory named
## [param tag], and returns it. Achievement progress the game keeps moves to one of its own, [code]<tag>_awards[/code].
static func use_scratch_settings(tag: String) -> String:
	# One directory per process (gs-settings' GSSettingsScratch): user:// is shared by every run on the machine.
	var dir := GSSettingsScratch.use(tag)
	settings_directory = dir
	FcAwardStore.suite_directory = GSSettingsScratch.use(tag + "_awards")
	return dir


## Points the look settings at the tunables the client's sampler reads, and applies them.
func bind_look(tunables: GSFpsTunables) -> void:
	_look = tunables
	_apply_look()


# --- The events a deathmatch has -------------------------------------------


func on_server_clamps(request: Dictionary) -> PackedStringArray:
	return settings.apply_server_clamps(request)
