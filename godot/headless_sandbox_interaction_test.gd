extends SceneTree
## ADVERSARIAL headless verification of the creative sandbox INTERACTION layer (sandbox-live-verify lane,
## 2026-07-02). The existing headless_sandbox_test.gd proves the DATA core; this suite drives the layers a
## player actually touches, without a display:
##
##   godot --headless --path godot -s res://headless_sandbox_interaction_test.gd
##
##   A) The REAL scene boots headless and seeds a world from the committed params file.
##   B) The camera raycast (_raycast_grid) places/removes against actual world geometry: place onto a block
##      face, remove the pointed-at block, ground-place into empty space, remove-on-nothing is a no-op.
##   C) The INPUT ROUTING (_unhandled_input) with synthesized InputEventKey / InputEventMouseButton events:
##      number keys + mouse wheel (wrap) select hotbar slots, E toggles the inventory, clicks route to
##      place/remove only when the pointer-capture gate allows (documented headless limitation below).
##   D) The MINECRAFT-CREATIVE INVENTORY UI, built for real (forced non-headless HUD path): category tabs
##      match the palette categories, the grid shows the active category's blocks, clicking a block loads
##      it into the ACTIVE hotbar slot.
##   E) Malformed params entries (junk rows, short cells, unknown block names) are skipped, never crash.
##   F) Every placed block is UNTEXTURED (no albedo_texture) and the _apply_material seam honours a richer
##      descriptor (roughness/metallic) when one is written - the live-texturing attachment point.
##
## HEADLESS LIMITATION (documented, asserted): Input.mouse_mode cannot become MOUSE_MODE_CAPTURED under the
## headless DisplayServer, so the LEFT-click branch takes the recapture path instead of placing. The suite
## asserts whichever behaviour the platform reports, and tests placement itself via _place_active (the same
## method the click branch calls) with the camera genuinely aimed.

const SandboxScene := preload("res://examples/sandbox_creative.tscn")

var _fails := 0

func _initialize() -> void:
	var ok := true

	# Keep the test OFF the real Wavelet state: the scene honours these env overrides for the
	# world store + the notes file, so a test run never touches Alethea-cc/state/sandbox.
	OS.set_environment("SANDBOX_WORLDS_DIR", ProjectSettings.globalize_path("user://test_interaction_worlds"))
	OS.set_environment("SANDBOX_NOTES_PATH", ProjectSettings.globalize_path("user://test_interaction_notes.jsonl"))

	# ── A) the real scene boots headless ─────────────────────────────────────────────────────────────
	var s = SandboxScene.instantiate()
	get_root().add_child(s)
	# NOTE: during SceneTree._initialize the tree has not STARTED: _ready does not fire on add_child
	# and every global_transform is identity (Node3D warns !is_inside_tree). Await one frame so the
	# tree starts, _ready fires naturally (exactly once), and camera global transforms become real.
	# (An aborted _initialize leaves a headless SceneTree idling forever — the runner uses a timeout.)
	await process_frame
	ok = _check("A1 scene boots headless (_headless detected)", s._headless == true) and ok
	ok = _check("A2 camera exists", s._cam is Camera3D) and ok
	ok = _check("A3 world seeded from params (>0 blocks)", s.world.size() > 0) and ok
	ok = _check("A4 every seeded block has a live MeshInstance3D", _all_nodes_alive(s)) and ok

	# ── B) raycast placement against real geometry ────────────────────────────────────────────────────
	# Deterministic world: one cube at the origin; camera at (0,0,5) looking straight down -Z at it.
	s._seed_world({ "blocks": [ { "cell": [0, 0, 0], "block": "Cube" } ] }, true)
	s.grid_size = 1.0
	s._cam.position = Vector3(0, 0, 5)
	s._look_toward(Vector3.ZERO)
	var rc: Dictionary = s._raycast_grid()
	ok = _check("B1 raycast hits the origin cube", rc["hit"] == true and rc["cell"] == Vector3i(0, 0, 0)) and ok
	ok = _check("B2 raycast place cell is the adjacent face cell", rc["place"] == Vector3i(0, 0, 1)) and ok
	s.active_slot = 0                     # slot 0 = Cube by default hotbar
	s._place_active()
	ok = _check("B3 place: block lands on the adjacent cell", s.world.has(Vector3i(0, 0, 1)) and s.world.size() == 2) and ok
	s._place_active()
	ok = _check("B4 second place extends a column toward the camera (MC-like)", s.world.has(Vector3i(0, 0, 2)) and s.world.size() == 3) and ok
	s._remove_target()
	ok = _check("B5 remove takes the nearest (pointed-at) block first", not s.world.has(Vector3i(0, 0, 2)) and s.world.size() == 2) and ok
	s._remove_target()
	s._remove_target()
	ok = _check("B6 repeated remove empties the whole column", s.world.size() == 0) and ok
	# The occupied-place-cell no-op guard: with the camera INSIDE a block, hit cell == place cell.
	s._seed_world({ "blocks": [ { "cell": [0, 0, 0], "block": "Cube" } ] }, true)
	s._cam.position = Vector3.ZERO
	s._place_active()
	ok = _check("B7 place from inside a block is a no-op (occupied place cell)", s.world.size() == 1) and ok
	s._seed_world({ "blocks": [] }, true)
	s._cam.position = Vector3(0, 0, 5)
	s._look_toward(Vector3.ZERO)
	s._remove_target()
	ok = _check("B8 remove on empty space is a no-op (no crash)", s.world.size() == 0) and ok
	s._place_active()
	ok = _check("B8b ground-place into empty space lands at half reach", s.world.has(Vector3i(0, 0, 1)) and s.world.size() == 1) and ok
	# Aim from below at a negative-coordinate build (grid math sanity beyond round-trip).
	s._seed_world({ "blocks": [ { "cell": [-3, -2, -5], "block": "Ball" } ] }, true)
	s._cam.position = Vector3(-3, -2, -1)
	s._look_toward(Vector3(-3, -2, -5))
	rc = s._raycast_grid()
	ok = _check("B9 raycast finds a negative-coordinate block", rc["hit"] == true and rc["cell"] == Vector3i(-3, -2, -5)) and ok

	# ── C) input ROUTING with synthesized events ──────────────────────────────────────────────────────
	# The interaction layer is gated off in headless _ready; force it on and build the HUD for real.
	s._headless = false
	s._build_hud()
	ok = _check("C1 HUD builds (hotbar UI has 9 slots)", s._hotbar_ui.get_child_count() == 9) and ok
	# Number keys 1..9 -> slot select.
	s._unhandled_input(_key(KEY_5))
	ok = _check("C2 number key 5 selects slot index 4", s.active_slot == 4) and ok
	s._unhandled_input(_key(KEY_1))
	ok = _check("C3 number key 1 selects slot index 0", s.active_slot == 0) and ok
	# Mouse wheel wraps around the 9 slots in both directions.
	s._unhandled_input(_click(MOUSE_BUTTON_WHEEL_UP))
	ok = _check("C4 wheel up from slot 0 wraps to slot 8", s.active_slot == 8) and ok
	s._unhandled_input(_click(MOUSE_BUTTON_WHEEL_DOWN))
	ok = _check("C5 wheel down wraps back to slot 0", s.active_slot == 0) and ok
	# E toggles the inventory open/closed.
	s._unhandled_input(_key(KEY_E))
	ok = _check("C6 E opens the inventory", s._inv_open == true and s._inv_panel.visible == true) and ok
	s._unhandled_input(_click(MOUSE_BUTTON_WHEEL_UP))
	ok = _check("C7 wheel is ignored while the inventory is open", s.active_slot == 0) and ok
	s._unhandled_input(_key(KEY_E))
	ok = _check("C8 E closes the inventory", s._inv_open == false and s._inv_panel.visible == false) and ok
	# The click place/remove gate: pointer capture is impossible under the headless DisplayServer, so
	# assert the gate takes the RECAPTURE branch (no placement) there - and the place branch if a real
	# display ever runs this suite. Either way the routing is exercised, nothing crashes.
	s._seed_world({ "blocks": [ { "cell": [0, 0, 0], "block": "Cube" } ] }, true)
	s._cam.position = Vector3(0, 0, 5)
	s._look_toward(Vector3.ZERO)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	s._unhandled_input(_click(MOUSE_BUTTON_LEFT))
	if captured:
		ok = _check("C9 LEFT click places when the pointer is captured", s.world.size() == 2) and ok
	else:
		ok = _check("C9 LEFT click without capture takes the recapture branch (no placement; headless limitation)", s.world.size() == 1) and ok
	s._unhandled_input(_click(MOUSE_BUTTON_RIGHT))
	ok = _check("C10 RIGHT click removes the pointed-at block (no capture gate)", s.world.size() == (1 if captured else 0)) and ok

	# ── D) the Minecraft-creative inventory UI ────────────────────────────────────────────────────────
	var cats: Array = s._categories()
	ok = _check("D1 palette leads with the 3 block categories (Blocks/Shapes/Structures)", cats.slice(0, 3) == ["Blocks", "Shapes", "Structures"]) and ok
	ok = _check("D1b every manifest kit contributes an asset category tab (all imported assets in the inventory)", (s.assets.kits as Array).size() >= 2 and cats.size() == 3 + (s.assets.kits as Array).size()) and ok
	ok = _check("D2 inventory has one tab per category", _live_children(s._inv_tabs).size() == cats.size()) and ok
	s._populate_inventory("Shapes")
	var shapes_count := 0
	for e in s.palette:
		if e["category"] == "Shapes":
			shapes_count += 1
	ok = _check("D3 grid shows exactly the Shapes blocks after tab switch", _live_children(s._inv_grid).size() == shapes_count) and ok
	# Clicking a block loads it into the ACTIVE hotbar slot (MC creative behaviour).
	s._select_slot(2)
	var torus: int = s._palette_index("Torus")
	s._pick_into_hotbar(torus)
	ok = _check("D4 picking a block loads it into the active hotbar slot", s.hotbar[2] == torus) and ok
	ok = _check("D5 other hotbar slots untouched", s.hotbar[0] == 0 and s.hotbar[8] == 8) and ok

	# ── E) malformed params never crash, valid rows still apply ───────────────────────────────────────
	s._seed_world({ "blocks": [
		"junk-string",
		42,
		{ "cell": [1, 2], "block": "Cube" },              # short cell -> skipped
		{ "cell": [9, 9, 9], "block": "NoSuchBlock" },    # unknown name -> skipped
		{ "block": "Cube" },                              # defaults cell [0,0,0] -> placed
		{ "cell": [1, 0, 0], "block": "Ball" },           # valid -> placed
	] }, true)
	ok = _check("E1 malformed entries skipped, valid entries placed (2 blocks)", s.world.size() == 2 and s.world.has(Vector3i(1, 0, 0)) and s.world.has(Vector3i(0, 0, 0))) and ok
	s._seed_world({ "blocks": "not-an-array" }, true)
	ok = _check("E2 non-array blocks value clears then no-ops (0 blocks, no crash)", s.world.size() == 0) and ok

	# ── F) untextured start + the live-texturing seam honours richer descriptors ─────────────────────
	s._seed_world({ "blocks": [ { "cell": [0, 0, 0], "block": "Cube" } ] }, true)
	var mi: MeshInstance3D = s.world[Vector3i(0, 0, 0)]["node"]
	var mat := mi.material_override as StandardMaterial3D
	ok = _check("F1 placed block is untextured (no albedo_texture)", mat != null and mat.albedo_texture == null) and ok
	s._apply_material(mi, { "albedo": [1.0, 0.0, 0.0], "roughness": 0.2, "metallic": 0.9 })
	mat = mi.material_override as StandardMaterial3D
	ok = _check("F2 seam applies a richer descriptor (albedo+roughness+metallic)", mat.albedo_color.r > 0.99 and absf(mat.roughness - 0.2) < 0.001 and absf(mat.metallic - 0.9) < 0.001) and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	# Detach + free the scene BEFORE quit so the engine's own tree start cannot re-run _ready on it.
	get_root().remove_child(s)
	s.free()
	quit(0 if ok else 1)


func _key(code: Key) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.pressed = true
	return ev

func _click(button: MouseButton) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = true
	return ev

## Children not already queue_freed (tab/grid rebuilds queue_free the old buttons; they stay children
## until the frame ends, so raw child counts overcount in a same-frame test).
func _live_children(n: Node) -> Array:
	var out := []
	for c in n.get_children():
		if not c.is_queued_for_deletion():
			out.append(c)
	return out

func _all_nodes_alive(s) -> bool:
	for cell in s.world.keys():
		var n = s.world[cell].get("node", null)
		if n == null or not is_instance_valid(n):
			return false
	return true

func _check(label: String, cond: bool) -> bool:
	print(("  PASS " if cond else "  FAIL ") + label)
	if not cond:
		_fails += 1
	return cond
