extends RefCounted
## Weapon attachments in Fatal Contact (docs/netcode.md, Ask.ATTACH): one attachments catalogue for every player, the
## request a client sends, the server's answer to it, and the suppressed report of a gun with a suppressor on.
## The fitting reaches every machine as `net_fitted`; nothing here touches hit registration.

const FcContent := preload("fc_content.gd")
const FcThrowMeter := preload("fc_throw_meter.gd")

const SLOT_BITS := 5
const NAME_BYTES := 32
## On the holder of an `AwShotFx` (a world model, or the local rig): its gun has a suppressor on.
const SUPPRESSED_META := &"arena_suppressed"

## The Boomerang attachment (dot-weapon API 41: a thrown knife flies a loop back).
## STAND-IN: fc-weapons has no knife socket or Boomerang model yet, so the entry carries no model and the knife
## looks the same fitted or not; the board item fc-knife-throw-1 holds the art request.
const BOOMERANG := &"boomerang"
## The fitted def's param that makes the knife a boomerang (`GSWeaponKnives.PARAM_BOOMERANG`).
const BOOMERANG_PARAM := "boomerang"

static var _catalogue: GSWeaponAttachments = null


## The pack's attachments, built once: `attachment_defs()` makes a new catalogue on every call.
static func catalogue() -> GSWeaponAttachments:
	if _catalogue == null:
		_catalogue = AwSpawnProvider.attachment_defs()
		# The shell's older dot-weapon has no Boomerang throw: offering it there would fit an attachment that does nothing.
		if _catalogue.get_attachment(BOOMERANG) == null and GSAddonApi.build_level("dot_weapon") >= FcThrowMeter.CHARGE_LEVEL:
			var _added := _catalogue.add(boomerang())
	return _catalogue


## The Boomerang attachment: any melee weapon with the knife mount, thrown as a boomerang. No model (see [constant BOOMERANG]).
static func boomerang() -> GSWeaponAttachment:
	var att := GSWeaponAttachment.new()
	att.id = BOOMERANG
	att.display_name = "Boomerang"
	att.description = "A thrown knife flies a loop and comes back to where it was thrown from."
	att.mount = FcContent.KNIFE_MOUNT
	att.fits_weapons = [FcContent.melee_id()] as Array[StringName]
	# GSWeaponKnives.PARAM_BOOMERANG (dot-weapon 41), written out so this parses on an older dot-weapon.
	att.params_set = {BOOMERANG_PARAM: true}
	return att


static func write_request(slot: int, mount: StringName, id: StringName) -> PackedByteArray:
	var w := GSNetWriter.new()
	w.write_uint(clampi(slot, 0, (1 << SLOT_BITS) - 1), SLOT_BITS)
	w.write_string(String(mount), NAME_BYTES)
	w.write_string(String(id), NAME_BYTES)
	return w.to_bytes()


## Reads a request and fits [param arsenal] if the catalogue allows it. Server only: the result is what the
## server decided, and the client sees it through the next snapshot's `net_fitted`.
static func serve(arsenal: GSWeaponArsenal, reader: GSNetReader) -> GSResult:
	var wire := [int(reader.read_uint(SLOT_BITS)), reader.read_string(NAME_BYTES), reader.read_string(NAME_BYTES)]
	if not reader.ok():
		return GSResult.fail(GSError.CODE_INVALID, "A cut-off attach request.")
	var parsed := GSWeaponAttachRequest.from_wire(wire)
	if not parsed.ok:
		return parsed
	return (parsed.value as GSWeaponAttachRequest).apply(arsenal)


## The replicated code of [param arsenal]'s held gun, 0 for none.
static func held_code(arsenal: GSWeaponArsenal) -> int:
	if arsenal == null or arsenal.attachments == null or arsenal.current() == null:
		return 0
	var base := arsenal.catalogue.get_def(arsenal.current().id())
	if base == null or arsenal.attachments.code_bits(base) > GSWeaponNetSync.FITTED_BITS:
		return 0
	return arsenal.attachments.encode(base, arsenal.fitting_at(arsenal.current_slot()))


## Whether [param code] on gun [param id] has a suppressor on.
static func suppressed(id: StringName, code: int) -> bool:
	if code == 0 or id == &"":
		return false
	var base := AwWeaponCatalogue.shared().get_def(id)
	if base == null or catalogue().code_bits(base) > GSWeaponNetSync.FITTED_BITS:
		return false
	var fitted := catalogue().apply(base, catalogue().decode(base, code))
	return fitted.ok and bool((fitted.value as GSWeaponDef).params.get(GSWeaponAttachment.PARAM_SUPPRESSED, false))


## Wraps [param fx]'s report: while its holder carries [constant SUPPRESSED_META], the shot plays through
## [param shots] (`func(at: Vector3) -> bool`); otherwise the report it had. Read at each shot, so a pooled
## effect that moves to another holder follows that holder. Wrapping an effect already wrapped does nothing.
static func wrap_report(fx: AwShotFx, shots: Callable) -> void:
	if fx == null or fx.shot_sound == fx.get_meta(&"fc_attach_wrap", Callable()):
		return
	var base := fx.shot_sound
	var wrap := func(id: StringName, kind: StringName, at: Vector3, indoors: bool) -> bool:
		var holder := fx.get_parent()
		if holder != null and bool(holder.get_meta(SUPPRESSED_META, false)) and shots.is_valid():
			return bool(shots.call(at))
		return base.is_valid() and bool(base.call(id, kind, at, indoors))
	fx.set_meta(&"fc_attach_wrap", wrap)
	fx.shot_sound = wrap


## A suppressed report at [param at] through [param presentation]'s layered shot player; false when it has none
## (layered shots off), and the effect then plays its own report.
static func play_suppressed(presentation: Object, at: Vector3) -> bool:
	var shots: GSShotPlayer = presentation.get(&"shots") if is_instance_valid(presentation) else null
	if shots == null:
		return false
	var res := shots.fire(GSAudioShotStock.id_of(AwShotLayers.shot_class(AwWeaponSound.SUPPRESSED)), at, true)
	return res.ok and int(res.value_or(0)) > 0
