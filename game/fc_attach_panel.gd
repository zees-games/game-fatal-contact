extends CanvasLayer
## The attachments screen over the game (docs/client.md, the Attachments key): the gun in hand in a studio of its own, what fits each mount and what it does to the stats (fc_attach_studio.gd).
## A pick goes to the server as Ask.ATTACH through [member send_fn]; offline, it is served here by the same `FcAttach.serve`. The rows follow the arsenal, which takes the server's fitting from the snapshot.

const FcAttach := preload("fc_attach.gd")
const FcAttachStudio := preload("fc_attach_studio.gd")

signal open_changed(open: bool)

## The arsenal whose gun in hand the menu fits; `func() -> GSWeaponArsenal`.
var arsenal_fn: Callable = Callable()
## Sends a request body to the server; left empty offline, where the pick is served at once.
var send_fn: Callable = Callable()

var menu: FcAttachStudio = null
var _slot := -1
var _code := -1


func _ready() -> void:
	layer = 20
	menu = FcAttachStudio.new()
	menu.name = "AttachStudio"
	menu.hide()
	add_child(menu)
	menu.requested.connect(_on_requested)
	menu.closed.connect(close)
	set_process(false)


func is_open() -> bool:
	return menu != null and menu.visible


## Opens the menu on the gun in hand; false (and nothing shown) when it has no mounts or there is no gun.
func open() -> bool:
	var arsenal := _arsenal()
	if arsenal == null or arsenal.attachments == null or arsenal.current() == null:
		return false
	var base := arsenal.catalogue.get_def(arsenal.current().id())
	if base == null or base.mounts.is_empty():
		return false
	_slot = arsenal.current_slot()
	_code = FcAttach.held_code(arsenal)
	var peers: Array[GSWeaponDef] = []
	for id: StringName in arsenal.catalogue.ids():
		peers.append(arsenal.catalogue.get_def(id))
	menu.open(arsenal.attachments, base, arsenal.fitting_at(_slot), peers)
	set_process(true)
	open_changed.emit(true)
	return true


func close() -> void:
	if not is_open():
		return
	menu.close()
	set_process(false)
	open_changed.emit(false)


func _process(_delta: float) -> void:
	var arsenal := _arsenal()
	# A switch, a drop or a death takes the gun the rows were for.
	if arsenal == null or arsenal.current() == null or arsenal.current_slot() != _slot:
		close()
		return
	var code := FcAttach.held_code(arsenal)
	if code != _code:
		_code = code
		menu.show_fitting(arsenal.fitting_at(_slot))


func _on_requested(mount: StringName, id: StringName) -> void:
	var body := FcAttach.write_request(_slot, mount, id)
	if send_fn.is_valid():
		send_fn.call(body)
		return
	var arsenal := _arsenal()
	if arsenal != null:
		var _fitted := FcAttach.serve(arsenal, GSNetReader.new(body))


func _arsenal() -> GSWeaponArsenal:
	return arsenal_fn.call() as GSWeaponArsenal if arsenal_fn.is_valid() else null
