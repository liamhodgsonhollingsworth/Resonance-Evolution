extends SceneTree
## HEADLESS SELF-TEST for the VISI-SONOR SANDBOX PICK-UP/MOVE layer (REQ 3), WITHOUT a window.
##
##   <godot> --headless --path godot -s res://headless_visisonor_sandbox_test.gd
##
## Judge PASS by the sentinel "RESULT: ALL PASS" (NOT the exit code — Godot's is unreliable headless).
##
## Liam (REQ 3): "the demo must let me adjust and change the scene using the sandbox tools where all the
## furniture and lamps act as nodes that I can pick up and move." This drives the REAL DemoInteractions
## controller (the one the shortcut opens) and asserts the pick-up-and-MOVE (live reposition, NOT
## inventory-remove) contract, via the pure grab/move/drop seams (no window, mirroring headless_pickup_test):
##   (1) every fixture (3 lamps + 3 furniture + screen) is registered as a movable node;
##   (2) grab_nearest reuses the PickupInteractor proximity seam — walking up to lamp_a grabs it;
##   (3) move_grabbed LIVE-repositions it: its global_position CHANGES, and its glow bulb follows;
##   (4) drop leaves it at the new spot (empty hand) — it was moved, not removed;
##   (5) the moved lamp's LIGHT STILL RESPONDS to its band (the SAME node, re-driven at its new position:
##       a bass frame brightens the bass-bound lamp far more than a treble frame does).

const DemoScript := preload("res://aperture/demo_interactions.gd")
const DeviceActions := preload("res://runtime/device_actions.gd")

var _fail := 0

func _check(name: String, cond: bool) -> bool:
	print(("PASS  " if cond else "FAIL  ") + name)
	if not cond:
		_fail += 1
	return cond

func _initialize() -> void:
	_run()

func _run() -> void:
	await _test_sandbox_move()
	print("RESULT: ", "ALL PASS" if _fail == 0 else ("%d FAIL" % _fail))
	quit(0 if _fail == 0 else 1)


func _test_sandbox_move() -> void:
	DeviceActions.unregister_device_ops_host()
	var demo = DemoScript.new()
	get_root().add_child(demo)
	await process_frame
	await process_frame
	_check("demo built the room + sandbox layer", demo.room != null and is_instance_valid(demo.room))

	# (1) every fixture is a registered movable node.
	var ids: Array = demo.movable_ids()
	_check("(1) lamps are movable (lamp_a/b/c)",
		ids.has("lamp_a") and ids.has("lamp_b") and ids.has("lamp_c"))
	_check("(1) furniture is movable (furniture_lamp_a/b/c)",
		ids.has("furniture_lamp_a") and ids.has("furniture_lamp_b") and ids.has("furniture_lamp_c"))
	_check("(1) the TV screen is movable", ids.has("screen"))

	# (2) proximity grab: walk up to lamp_a (authored at (-2.5, 2.2, -2.5)) and grab the NEAREST fixture.
	# Reuses PickupInteractor.refresh/available_ids — only lamp_a is inside the 3.0m radius from here.
	var near_lamp_a := Vector3(-2.5, 2.2, -2.0)
	var grabbed := demo.grab_nearest(near_lamp_a)
	_check("(2) grab_nearest (proximity seam) grabs the lamp we walked up to", grabbed == "lamp_a")
	_check("(2) grabbed_id reflects the held fixture", demo.grabbed_id() == "lamp_a")

	# (3) LIVE move: reposition lamp_a; its primary position CHANGES and its glow bulb follows by the delta.
	var before := demo.fixture_position("lamp_a")
	var light = _lamp_light(demo)
	var glow_before: Vector3 = _glow(demo).global_position if _glow(demo) != null else Vector3.ZERO
	var target := Vector3(1.5, 2.6, 1.0)
	_check("(3) move_grabbed returns true", demo.move_grabbed(target))
	var after := demo.fixture_position("lamp_a")
	_check("(3) the lamp's global_position CHANGED (live move, not inventory-remove)",
		before.distance_to(after) > 0.5 and after.distance_to(target) < 0.001)
	_check("(3) the lamp's live Light3D node itself moved to the new spot",
		light != null and light.global_position.distance_to(target) < 0.001)
	var glow_after: Vector3 = _glow(demo).global_position if _glow(demo) != null else Vector3.ZERO
	_check("(3) the lamp's glow bulb followed by the same delta",
		glow_after.distance_to(glow_before) > 0.5)

	# (4) drop: empty hand, lamp stays where it was moved (moved, not removed).
	demo.drop()
	_check("(4) drop clears the held fixture (empty hand)", demo.grabbed_id() == "")
	_check("(4) the dropped lamp stays at its new position (not removed from the world)",
		demo.fixture_position("lamp_a").distance_to(target) < 0.001 and is_instance_valid(light))

	# (5) the MOVED lamp's light STILL RESPONDS to its band: lamp_a is bass-bound (addr 0), so a bass frame
	# brightens it far more than a treble frame — proving the same node, at its new position, re-drives.
	var bass := { "signal.band.low": 0.95, "signal.band.mid": 0.1, "signal.band.high": 0.05,
		"signal.band.sub": 0.9, "signal.band.lowmid": 0.2, "signal.band.highmid": 0.05, "signal.energy": 0.6 }
	var treble := { "signal.band.low": 0.05, "signal.band.mid": 0.1, "signal.band.high": 0.95,
		"signal.band.sub": 0.05, "signal.band.lowmid": 0.1, "signal.band.highmid": 0.9, "signal.energy": 0.6 }
	demo.drive_visisonor(bass)
	var e_bass: float = light.light_energy
	var col_bass: Color = light.light_color
	var pos_after_drive: Vector3 = light.global_position
	demo.drive_visisonor(treble)
	var e_treble: float = light.light_energy
	_check("(5) moved lamp still responds: BRIGHTER on its bass frame than a treble frame",
		e_bass > e_treble + 1.0)
	_check("(5) moved lamp is WARM on a bass frame (r > b) — the reactive tint still drives",
		col_bass.r > col_bass.b)
	_check("(5) driving the light show did NOT snap the lamp back (it stays where it was moved)",
		pos_after_drive.distance_to(target) < 0.001)

	demo.queue_free()
	DeviceActions.unregister_device_ops_host()


# --- helpers: reach the moved lamp's live nodes for direct assertions -------------------------------

func _lamp_light(demo):
	# lamp_a's primary node IS its live Light3D (registered movable). Read it via the renderer's _lights.
	return demo._resolve_fixture_light("r:lamp_a_light/light")

func _glow(demo):
	var gm: Dictionary = demo.get("_lamp_glow_meshes")
	return gm.get("r:lamp_a_light/light")
