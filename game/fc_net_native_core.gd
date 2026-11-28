extends RefCounted

## gs-sim's snapshot core (`GSSimNetCore`, gs-net's `GSNetNativeCore` in Rust, the same bytes) handed to the server's [GSNetManager],
## so a release build without gs-net's own library still builds snapshots natively.
## cvar [code]sv_native_snapshots[/code]: 1 (default) the native core, 0 gs-net's GDScript path.

## The class, reached by name only: scripts parse and run without gs-sim.
const CHANNEL := "fc.net_core"
const CORE_CLASS := &"GSSimNetCore"
## `GSNetNative.ABI`: the method set and argument shapes gs-net's manager calls.
const ABI := 5
## Every method gs-net's manager and behaviours call on a core.
const METHODS: Array[StringName] = [
	&"begin_snapshot", &"submit_peer", &"submit_peer_interest", &"take_ready", &"finish_snapshot",
	&"set_interest", &"expire_interest", &"forget_peer", &"export_budget", &"forget_view",
	&"view_snapshot", &"view_state", &"describe",
]

## cvar `sv_native_snapshots`, read when the netcode is built and on every change.
static var enabled := true
static var _missing_warned := false


## A new core, or null (warned once) when gs-sim is absent, older, or lacks a method.
static func make_core() -> Object:
	var why := ""
	if not ClassDB.class_exists(CORE_CLASS):
		why = "gs-sim has no %s" % CORE_CLASS
	else:
		var core: Object = ClassDB.instantiate(CORE_CLASS)
		if core == null:
			why = "%s did not instantiate" % CORE_CLASS
		elif int(core.call(&"abi_version")) != ABI:
			why = "%s speaks ABI %d, gs-net wants %d" % [CORE_CLASS, int(core.call(&"abi_version")), ABI]
		else:
			for m in METHODS:
				if not core.has_method(m):
					why = "%s has no %s" % [CORE_CLASS, m]
					break
			if why.is_empty():
				return core
	if not _missing_warned:
		_missing_warned = true
		GSLog.warn(CHANNEL, "sv_native_snapshots: gs-sim cannot build them; snapshots are built in GDScript", {"why": why})
	return null


## Points [param net] at gs-sim's core ([member enabled]) or at the GDScript path. Before the first
## snapshot, so gs-net never looks for its own library; after a switch every view is resent.
static func install(net: GSNetManager) -> bool:
	if net == null or net.config == null:
		return false
	var core: Object = make_core() if enabled else null
	if core == null:
		# GDScript snapshots, said once above; gs-net's own library is not looked for either.
		net.config.native = false
		if net._native != null:
			net._reset_send_views()
			net._native = null
		net._native_tried = true
		net._native_note = "off (sv_native_snapshots 0)" if not enabled else "asked, GDScript in use: no %s" % CORE_CLASS
		return false
	net.config.native = true
	net._reset_send_views()
	net._native = core
	net._native_tried = true
	net._native_note = "on (gs-sim %s)" % CORE_CLASS
	return true


## `sv_native_snapshots`, live: a change rebuilds the hold on every behaviour (both paths resend everything).
static func bind_cvar(add_cvar: Callable, net_fn: Callable) -> void:
	var cv: GSConVar = add_cvar.call("sv_native_snapshots", "1" if enabled else "0",
		"Build snapshots in gs-sim's native core (1, default; the same bytes) or in GDScript (0)",
		GSConVar.FLAG_ARCHIVE)
	cv.with_min(0.0).with_max(1.0).changed.connect(
		func(_old: String, new_value: String) -> void:
			enabled = new_value.to_float() != 0.0
			install(net_fn.call() as GSNetManager))
