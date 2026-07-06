extends Node
## DEMO CONTROLLER — the runnable, VISIBLE Slice-5 interaction demo (Dreams-arc Slice 5).
##
## This is the single-owned INTEGRATION PAYOFF: it COMPOSES the landed pieces (it builds NOTHING new about
## the room or the primitives) into the one thing Liam opens and tries. It:
##   1. builds the REAL Aperture3D room (the same scene the shortcut opens) as a child, so the demo runs
##      inside the actual walkable room — additive, no mutation of aperture_3d.gd;
##   2. boots the ui.* + device.* host op families (register_ui_ops / register_device_ops), so a
##      WorldAction node honours dialogue.show / ui.menu.open / device.set_led;
##   3. mounts the minimal in-world UI renderer (ui_action_renderer.gd) on the room — additive overlay;
##   4. loads the THREE demo arrangements into three room-owned GraphRuntimes (A button->dialogue,
##      B area->menu, C live band->led);
##   5. each tick, INJECTS the per-frame input frame each arrangement reads (the F2 portability seam):
##      the interact keypress, the live player position (for the area proximity), and a band oscillator;
##      then EVALUATES each runtime and routes the WorldAction receipts to the UI renderer / the LED chip.
##
## CONTROLS (kept obvious; also printed to stdout + documented in DEMO-slice5.md):
##   • WASD + mouse            — walk / look (the room's own first-person controller).
##   • E                       — INTERACT: shows the dialogue box (demo A). Dismiss with E or the button.
##   • walk to the RED marker  — enter the area (~centre-front): the menu opens (demo B); leave to close.
##   • the LED swatch (top-L)  — driven by a slow band oscillator (demo C); watch it fade warm<->cool.
##   • hold B                  — force the band HIGH (warm) so you can see the LED flip on demand.
##   • ESC                     — release the mouse (room default).
##
## Open live (GUI, windowed):
##   C:\Users\Liam\godot\Godot_v4.6.3-stable_win64.exe --path godot res://demo_interactions.tscn
## (the GUI exe, NOT the console one — the console exe is for headless stdout tests.)

const Aperture3D := preload("res://aperture/aperture_3d.gd")
const UiActionRenderer := preload("res://aperture/ui_action_renderer.gd")
const UiActions := preload("res://runtime/ui_actions.gd")
const DeviceActions := preload("res://runtime/device_actions.gd")
const WorldActions := preload("res://runtime/world_actions.gd")

# The area centre for demo B (matches demo_area_menu.json's `area` Const). A visible red marker is placed
# here so the player can SEE where to walk. y is the player's eye height so the proximity distance is planar.
const AREA_CENTRE := Vector3(4.0, 1.7, -4.0)

var room: Node3D = null
var _rt_dialogue: GraphRuntime = null
var _rt_menu: GraphRuntime = null
var _rt_led: GraphRuntime = null

var _interact_pulse := false   # set for exactly one evaluate when E is pressed (edge-triggered)
var _force_high := false       # hold B => band forced high (warm)
var _t := 0.0
var _headless := false

# The on-screen LED indicator (demo C): a small ColorRect tinted from the device.set_led receipt so the
# mapped colour is VISIBLE without real hardware. Mounted on its own CanvasLayer (additive to the room).
var _led_swatch: ColorRect = null
var _led_label: Label = null


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	# 1. the REAL room, as a child (the demo runs inside the actual walkable Aperture3D).
	room = Aperture3D.new()
	room.name = "Aperture3DRoom"
	add_child(room)

	# 2. boot the ui.* + device.* host op families so a WorldAction honours dialogue.show / ui.menu.open /
	#    device.set_led. The builtin-shadow guard in register_host keeps this safe (no ui.* masks a builtin).
	UiActions.register_ui_ops(WorldActions)
	DeviceActions.register_device_ops(WorldActions)

	# 3. mount the minimal UI renderer overlay on the room (force=true is only for headless; live uses false).
	UiActionRenderer.mount(room, _headless)
	_build_led_indicator()

	# 4. load the three demo arrangements into three room-owned runtimes.
	_rt_dialogue = _load_runtime("res://arrangements/demo_button_dialogue.json")
	_rt_menu = _load_runtime("res://arrangements/demo_area_menu.json")
	_rt_led = _load_runtime("res://arrangements/demo_band_led.json")

	# 5. a visible red marker at the area centre so the player can see where to walk (demo B). Additive.
	if not _headless:
		_place_area_marker()
		_print_controls()


func _process(delta: float) -> void:
	if room == null or not is_instance_valid(room):
		return
	_t += delta
	drive_once(_player_pos(), delta)
	_interact_pulse = false   # the interact pulse lasts exactly one evaluate (edge-triggered)


## THE ONE BACKEND STEP (text-equivalence anchor, gate T): inject the per-frame frame each arrangement
## reads, evaluate the three runtimes, and route their WorldAction receipts to the UI renderer + LED. The
## headless #049 test calls THIS EXACT fn (driving the same runtimes + renderer) — there is no GUI-only
## path. Returns the three receipts { dialogue, menu, led } so a test can assert on them directly.
func drive_once(player_pos: Vector3, dt: float) -> Dictionary:
	# --- demo A: inject the interact pulse; evaluate; render the dialogue receipt --------------------
	_rt_dialogue.set_input_frame({ "action.interact": (1.0 if _interact_pulse else 0.0) })
	var out_a := _rt_dialogue.evaluate()
	var say: Dictionary = out_a.get("say", {}).get("result", {})
	if str(say.get("op", "")) == "dialogue.show" and str(say.get("text", "")) != "":
		UiActionRenderer.render_receipt(room, say)

	# --- demo B: inject the live player position; evaluate; render the menu receipt ------------------
	_rt_menu.set_input_frame({ "player.pos": [player_pos.x, player_pos.y, player_pos.z] })
	var out_b := _rt_menu.evaluate()
	var open_r: Dictionary = out_b.get("open", {}).get("result", {})
	# open with items => inside the area; empty items => outside => close the menu.
	if str(open_r.get("op", "")) == "ui.menu.open" and (open_r.get("items", []) as Array).size() > 0:
		UiActionRenderer.render_receipt(room, open_r)
	elif UiActionRenderer.menu_visible(room):
		UiActionRenderer.render_receipt(room, { "op": "ui.menu.close" })

	# --- demo C: inject the band oscillator (or forced-high); evaluate; tint the LED swatch ----------
	var band := 1.0 if _force_high else (0.5 + 0.5 * sin(_t * 1.5))
	_rt_led.set_input_frame({ "signal.band.high": band })
	var out_c := _rt_led.evaluate()
	var led: Dictionary = out_c.get("led", {}).get("result", {})
	_apply_led(led)

	return { "dialogue": say, "menu": open_r, "led": led }


## Fire the interact pulse for exactly the next evaluate (demo A). The GUI calls this on the E key; a test
## calls it directly. Edge-triggered so one press = one dialogue.show, not a held stream.
func pulse_interact() -> void:
	_interact_pulse = true


func _unhandled_input(event: InputEvent) -> void:
	if _headless:
		return
	if event is InputEventKey and not event.echo:
		match event.keycode:
			KEY_E:
				if event.pressed:
					pulse_interact()
			KEY_B:
				_force_high = event.pressed   # hold B => band high


# --- setup helpers ---------------------------------------------------------------------------------

## Build a runtime + load an arrangement file into it, parented so the tree owns it. The runtime is
## room-owned (a child of THIS demo node, which owns the room) — the same load_arrangement path the room
## itself drives, so the demo runs on real runtimes, not throwaway ones.
func _load_runtime(path: String) -> GraphRuntime:
	var rt := GraphRuntime.new()
	add_child(rt)
	rt.load_json(path)
	return rt


## The player's live position, read off the room's first-person controller (its `_pos` var). Headless
## callers pass a position into drive_once directly; live, the room integrates _pos every frame.
func _player_pos() -> Vector3:
	if room != null and is_instance_valid(room):
		var p = room.get("_pos")
		if typeof(p) == TYPE_VECTOR3:
			return p
	return Vector3.ZERO


## The minimal on-screen LED indicator (demo C): a small labelled ColorRect on its own CanvasLayer so the
## mapped device.set_led colour is VISIBLE with no real hardware. Additive — a plain swatch, top-left.
func _build_led_indicator() -> void:
	if _headless:
		return
	var layer := CanvasLayer.new()
	layer.name = "__demo_led_layer"
	layer.layer = 40
	add_child(layer)
	var box := VBoxContainer.new()
	box.position = Vector2(16, 16)
	layer.add_child(box)
	_led_label = Label.new()
	_led_label.text = "LED (demo C): device.set_led"
	_led_label.add_theme_font_size_override("font_size", 13)
	box.add_child(_led_label)
	_led_swatch = ColorRect.new()
	_led_swatch.custom_minimum_size = Vector2(120, 40)
	_led_swatch.color = Color(0.1, 0.1, 0.1)
	box.add_child(_led_swatch)


## Tint the LED swatch from a device.set_led receipt (r,g,b in 0..1). A no-op receipt (host with no LED)
## or a non-led op leaves the swatch as-is. Headless-safe (no swatch => nothing to tint).
func _apply_led(receipt: Dictionary) -> void:
	if _led_swatch == null:
		return
	if str(receipt.get("op", "")) != "device.set_led" or receipt.get("noop", false):
		return
	_led_swatch.color = Color(
		clampf(float(receipt.get("r", 0)), 0.0, 1.0),
		clampf(float(receipt.get("g", 0)), 0.0, 1.0),
		clampf(float(receipt.get("b", 0)), 0.0, 1.0))


## A visible red marker at the area centre (demo B) so the player can SEE where to walk. A plain unshaded
## red box on the floor under the area; additive geometry, not part of any arrangement.
func _place_area_marker() -> void:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(1.0, 0.1, 1.0)
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.9, 0.15, 0.15)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	mi.position = Vector3(AREA_CENTRE.x, 0.06, AREA_CENTRE.z)
	room.add_child(mi)


func _print_controls() -> void:
	print("[demo_interactions] Slice-5 interaction demo ready.")
	print("  E                 -> INTERACT: shows the dialogue (demo A). E/Dismiss to close.")
	print("  walk to RED marker -> opens the Area Menu (demo B); leave to close.")
	print("  LED swatch (top-L) -> band oscillator drives device.set_led (demo C). Hold B = force warm.")
	print("  ESC               -> release mouse.")
