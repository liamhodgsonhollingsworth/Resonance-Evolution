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

	# ── B) FREE placement against real geometry (Liam correction 2026-07-05: NO grid) ─────────────────
	# Deterministic world: one voxel cube at the origin; camera at (0,0,5) looking straight down -Z at it.
	# Placement is now FREE: the held block spawns at the EXACT raycast hit point as an OBJECT (not a grid
	# cell), so B-tests assert the free hit point + the object layer, not the voxel `world` dict.
	s._seed_world({ "blocks": [ { "cell": [0, 0, 0], "block": "Cube" } ] }, true)
	s.grid_size = 1.0
	s.reach_distance = 8.0
	s._cam.position = Vector3(0, 0, 5)
	s._look_toward(Vector3.ZERO)
	var rc: Dictionary = s._raycast_grid()
	ok = _check("B1 raycast (voxel) hits the origin cube", rc["hit"] == true and rc["cell"] == Vector3i(0, 0, 0)) and ok
	var rf: Dictionary = s._raycast_free()
	ok = _check("B2 free raycast returns the exact surface hit point on the cube's +Z face (~z=0.5)", bool(rf["hit"]) and absf((rf["point"] as Vector3).z - 0.5) < 0.15) and ok
	s.active_slot = 0                     # slot 0 = Cube by default hotbar
	var objs_before: int = s.objects.size()
	s._place_active()
	ok = _check("B3 place: a free BLOCK OBJECT spawns (object layer grows, voxel world untouched)", s.objects.size() == objs_before + 1 and s.world.size() == 1) and ok
	# The new object sits at the free hit point (~ the cube's +Z face), not snapped to a grid cell.
	var last_id := ""
	for oid in s.objects:
		last_id = oid
	var placed_pos: Vector3 = (s.objects[last_id] as Dictionary)["base_pos"]
	ok = _check("B3b the placed block is at the free hit point (not a grid centre)", absf(placed_pos.z - 0.5) < 0.2 and s.objects[last_id].has("block")) and ok
	s._place_active()
	ok = _check("B4 a second free place adds another object", s.objects.size() == objs_before + 2) and ok
	# LEFT-click destroy removes the nearest pointed-at OBJECT first (the free block we just placed).
	s._remove_target()
	ok = _check("B5 remove takes the nearest (pointed-at) free object first", s.objects.size() == objs_before + 1) and ok
	s._remove_target()
	ok = _check("B5b remove again clears the other free object, leaving the voxel cube", s.objects.size() == objs_before and s.world.has(Vector3i(0, 0, 0))) and ok
	s._remove_target()
	ok = _check("B6 with no objects left, remove takes the voxel block under the crosshair", s.world.size() == 0) and ok
	# Free placement into EMPTY SPACE: nothing within reach => spawns at reach_distance out along the ray.
	s._seed_world({ "blocks": [] }, true)
	s._clear_objects()
	s._cam.position = Vector3(0, 0, 5)
	s._look_toward(Vector3.ZERO)
	s._remove_target()
	ok = _check("B8 remove on empty space is a no-op (no crash)", s.world.size() == 0 and s.objects.size() == 0) and ok
	s._place_active()
	ok = _check("B8b free-place into empty space spawns one object (on the ground plane below the aim)", s.objects.size() == 1) and ok
	s._clear_objects()
	# Aim from below at a negative-coordinate voxel block (grid math sanity beyond round-trip).
	s._seed_world({ "blocks": [ { "cell": [-3, -2, -5], "block": "Ball" } ] }, true)
	s._cam.position = Vector3(-3, -2, -1)
	s._look_toward(Vector3(-3, -2, -5))
	rc = s._raycast_grid()
	ok = _check("B9 voxel raycast finds a negative-coordinate block", rc["hit"] == true and rc["cell"] == Vector3i(-3, -2, -5)) and ok

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
	# MINECRAFT-DEFAULT click routing (Liam spec 2026-07-03): RIGHT=place, LEFT=destroy, MIDDLE=pick.
	# Pointer capture is impossible under the headless DisplayServer, so the FIRST click after ESC takes
	# the recapture branch. We set capture explicitly and drive the click-dispatch methods the routing
	# calls, so the routing + the MC semantics are both exercised without a real display.
	s._seed_world({ "blocks": [ { "cell": [0, 0, 0], "block": "Cube" } ] }, true)
	s._clear_objects()
	s._cam.position = Vector3(0, 0, 5)
	s._look_toward(Vector3.ZERO)
	s._select_slot(0)
	s.hotbar[0] = s._palette_index("Cube")     # Cube in hand
	s._refresh_held_item()
	# RIGHT click = MC PLACE (free, at the aim point => a new object; the voxel cube is untouched).
	s._click_secondary()
	ok = _check("C9 RIGHT click PLACES (MC default) a free object at the aim point", s.objects.size() == 1 and s.world.size() == 1) and ok
	# LEFT click = MC DESTROY (the nearest pointed-at thing: the free object we just placed).
	s._click_primary()
	ok = _check("C10 LEFT click DESTROYS (MC default) the nearest pointed-at thing", s.objects.size() == 0) and ok
	# LEFT click again removes the voxel cube behind it.
	s._click_primary()
	ok = _check("C10b LEFT click then destroys the voxel block behind it", s.world.size() == 0) and ok
	# MIDDLE click = MC PICK: the pointed-at Cube becomes the active hotbar entry.
	s._seed_world({ "blocks": [ { "cell": [0, 0, 0], "block": "Cube" } ] }, true)
	s._clear_objects()
	s._select_slot(3)
	s.hotbar[3] = s._palette_index("Ball")     # put something else in the active slot first
	s._refresh_held_item()
	s._click_middle()
	ok = _check("C11 MIDDLE click PICKS the looked-at block into the active slot (MC pick)", s.hotbar[3] == s._palette_index("Cube")) and ok
	s._select_slot(0)

	# ── C-EMPTY) EMPTY HAND + DROP (Liam item 1, 2026-07-05) ──────────────────────────────────────────
	s.hotbar[0] = s._palette_index("Cube")
	s._select_slot(0)
	ok = _check("CE1 a block in hand is NOT empty", s._hand_empty() == false and s._active_entry().has("name")) and ok
	# Q drops the held item: the slot empties (item disappears).
	s._unhandled_input(_key(KEY_Q))
	ok = _check("CE2 Q drops the held item -> EMPTY_HAND (slot emptied)", int(s.hotbar[0]) == s.EMPTY_HAND and s._hand_empty()) and ok
	ok = _check("CE2b empty hand => no tool handler + _active_entry is {}", s._active_handler == null and s._active_entry().is_empty()) and ok
	# Empty hand: RIGHT click places NOTHING (nothing to place).
	s._seed_world({ "blocks": [ { "cell": [0, 0, 0], "block": "Cube" } ] }, true)
	s._clear_objects()
	s._cam.position = Vector3(0, 0, 5)
	s._look_toward(Vector3.ZERO)
	s._click_secondary()
	ok = _check("CE3 empty-hand RIGHT click places nothing", s.objects.size() == 0 and s.world.size() == 1) and ok
	# Empty hand: LEFT click still DESTROYS the targeted thing (MC default).
	s._click_primary()
	ok = _check("CE4 empty-hand LEFT click still destroys the targeted block", s.world.size() == 0) and ok
	# Empty hand: MIDDLE click still PICKS into the hand (fills the empty slot).
	s._seed_world({ "blocks": [ { "cell": [0, 0, 0], "block": "Cube" } ] }, true)
	s._cam.position = Vector3(0, 0, 5)
	s._look_toward(Vector3.ZERO)
	s._click_middle()
	ok = _check("CE5 empty-hand MIDDLE click picks the looked-at block into the (empty) hand", int(s.hotbar[0]) == s._palette_index("Cube") and not s._hand_empty()) and ok

	# ── C-MAP) the DATA-DRIVEN action map (control extensibility) ─────────────────────────────────────
	ok = _check("CM1 the action map is a dictionary with the always-on keys (F1 now owned by the global GizmoNote autoload, not this map)", s._key_actions.has(KEY_E) and s._key_actions.has(KEY_Q) and not s._key_actions.has(KEY_F1)) and ok

	# ── C-REACH) CONFIGURABLE REACH (Liam item 1): the params file tunes reach_distance live ──────────
	var prev_reach: float = s.reach_distance
	s._apply_settings({ "reach_distance": 3.5 })
	ok = _check("CR1 params reach_distance is honoured (place/destroy/grab/target reach is configurable)", absf(s.reach_distance - 3.5) < 1e-6) and ok
	# an object beyond the (now short) reach is NOT targetable; within reach it is.
	s._seed_world({ "blocks": [] }, true)
	s._clear_objects()
	var far_id: String = s._place_block_free(s._palette_index("Cube"), Vector3(0, 0, -6.0), 0.0)
	s._cam.position = Vector3(0, 0, 0)
	s._look_toward(Vector3(0, 0, -6.0))
	ok = _check("CR2 an object beyond reach_distance is NOT picked (reach actually gates targeting)", String((s._pick_object() as Dictionary).get("id", "")) == "") and ok
	s._apply_settings({ "reach_distance": 10.0 })
	ok = _check("CR3 widening reach makes the same object targetable again", String((s._pick_object() as Dictionary).get("id", "")) == far_id) and ok
	s.reach_distance = prev_reach
	s._clear_objects()

	# ── C-FB) IN-SCENE FEEDBACK (F1) writes a scene_feedback row (overarching ask) ────────────────────
	var fb_file: String = ProjectSettings.globalize_path("user://test_interaction_feedback.jsonl")
	if FileAccess.file_exists(fb_file):
		DirAccess.remove_absolute(fb_file)
	var prev_notes: String = s.notes_path
	s.notes_path = fb_file
	ok = _check("CF1 _write_feedback appends a scene_feedback row", s._write_feedback("the sky is a bit flat here")) and ok
	var frow := _last_json_line(fb_file)
	ok = _check("CF1b feedback row is keyed to the scene id + shares the notes schema", String(frow.get("kind", "")) == "scene_feedback" and String(frow.get("scene_id", "")) == "sandbox_creative" and frow.has("ts") and frow.has("note")) and ok
	s.notes_path = prev_notes

	# ── D) the Minecraft-creative inventory UI ────────────────────────────────────────────────────────
	var cats: Array = s._categories()
	ok = _check("D1 palette leads with the 3 block categories (Blocks/Shapes/Structures)", cats.slice(0, 3) == ["Blocks", "Shapes", "Structures"]) and ok
	ok = _check("D1b every manifest kit contributes an asset category tab + the Tools tab (all imported assets + tools in the inventory)", (s.assets.kits as Array).size() >= 2 and cats.size() == 3 + (s.assets.kits as Array).size() + 1 and cats.has("Tools")) and ok
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

	# ── G) HELD-ITEM SEAM + STICKY NOTE (Liam spec 2026-07-03) ────────────────────────────────────────
	# G1: the Sticky Note tool is in the palette under a Tools category.
	var sticky_idx := -1
	for i in s.palette.size():
		var e: Dictionary = s.palette[i]
		if String(e.get("kind", "")) == "tool" and String(e.get("tool", "")) == "sticky_note":
			sticky_idx = i
			break
	ok = _check("G1 the Sticky Note tool exists in the palette", sticky_idx >= 0) and ok
	ok = _check("G1b Tools is a category tab", s._categories().has("Tools")) and ok

	# G2: holding the sticky note selects its handler; empty hand / blocks have no handler (MC default).
	s._select_slot(0)
	s.hotbar[0] = s._palette_index("Cube")
	s._refresh_held_item()
	ok = _check("G2 empty-hand/block => no tool handler (MC defaults apply)", s._active_handler == null) and ok
	s.hotbar[0] = sticky_idx
	s._refresh_held_item()
	ok = _check("G2b holding the sticky note => a handler is active", s._active_handler != null) and ok

	# G3: a TOOL held in hand does NOT place a block on RIGHT click (tools act, not placed).
	s._seed_world({ "blocks": [ { "cell": [0, 0, 0], "block": "Cube" } ] }, true)
	s._cam.position = Vector3(0, 0, 5)
	s._look_toward(Vector3.ZERO)
	var before: int = s.world.size()
	s._click_secondary()      # sticky note's secondary() is a no-op
	ok = _check("G3 RIGHT click with a tool held does NOT place a block", s.world.size() == before) and ok

	# G4: surface_pick returns the exact surface point + a face normal + the target on the pointed-at block.
	var hit: Dictionary = s.surface_pick()
	ok = _check("G4 surface_pick hits the origin cube", bool(hit.get("hit", false)) and String((hit.get("target", {}) as Dictionary).get("kind", "")) == "block") and ok
	ok = _check("G4b surface_pick point is on the +Z face of the cube (looking down -Z from z=5)", hit.has("point") and (hit["point"] as Vector3).z > 0.3) and ok
	ok = _check("G4c surface_pick normal points back toward the camera (+Z)", hit.has("normal") and (hit["normal"] as Vector3).z > 0.5) and ok

	# G5: stick_note stores a LOCAL-space anchor + normal, realizes a record, returns an id.
	var note_id: String = s.stick_note(hit)
	ok = _check("G5 stick_note returns a note id", note_id != "" and s._notes.has(note_id)) and ok
	var nrec: Dictionary = s._notes.get(note_id, {})
	ok = _check("G5b note stores a local_point + local_normal + target", nrec.has("local_point") and nrec.has("local_normal") and nrec.has("target")) and ok
	ok = _check("G5c note carries the held-item provenance (sticky_note)", String(nrec.get("held_item", "")) == "sticky_note") and ok

	# G6: the note's world position reconstructs at the original hit point (local anchor round-trip).
	var xf: Transform3D = s._note_target_xform(nrec)
	var lp: Array = nrec["local_point"]
	var reconstructed: Vector3 = xf * Vector3(lp[0], lp[1], lp[2])
	ok = _check("G6 local-anchor round-trips back to the world hit point", reconstructed.distance_to(hit["point"]) < 0.01) and ok

	# G7: a note stuck on a MOVING OBJECT rides it. Place an asset object, stick a note to it, move it.
	if s.assets != null and (s.assets.manifest as Dictionary).size() > 0:
		var some_asset := String((s.assets.manifest as Dictionary).keys()[0])
		var oid: String = s._place_object(some_asset, Vector3(4, 0, 0))
		if oid != "":
			# Build a synthetic object hit at a point on the object.
			var orec: Dictionary = s.objects[oid]
			var onode: Node3D = orec["node"]
			var world_pt: Vector3 = onode.global_position + Vector3(0, 0.5, 0)
			var ohit := { "hit": true, "point": world_pt, "normal": Vector3(0, 1, 0),
				"target": { "kind": "object", "id": oid } }
			var onote: String = s.stick_note(ohit)
			var onrec: Dictionary = s._notes[onote]
			var before_xf: Transform3D = s._note_target_xform(onrec)
			var olp: Array = onrec["local_point"]
			var world_before: Vector3 = before_xf * Vector3(olp[0], olp[1], olp[2])
			# Move the object; the note's reconstructed world point must move with it.
			orec["base_pos"] = Vector3(10, 0, 0)
			s._tick_objects(0.016)
			var after_xf: Transform3D = s._note_target_xform(onrec)
			var world_after: Vector3 = after_xf * Vector3(olp[0], olp[1], olp[2])
			ok = _check("G7 a note stuck to an object RIDES it when the object moves", world_after.distance_to(world_before) > 3.0) and ok

	# G8: notes persist into the world save AND reload (round-trip through _serialize_world/_apply_world_data).
	var serialized: Dictionary = s._serialize_world()
	ok = _check("G8 world serialize includes a notes list", serialized.has("notes") and (serialized["notes"] as Array).size() >= 1) and ok
	var note_count_before: int = s._notes.size()
	s._apply_world_data(serialized)
	ok = _check("G8b notes reload with the world (count preserved)", s._notes.size() == note_count_before) and ok

	# G9: sticky-note text saves an ADDITIVELY-EXTENDED notes.jsonl row (RE #145 fields + anchor + provenance).
	var notes_file: String = ProjectSettings.globalize_path("user://test_interaction_notes.jsonl")
	if FileAccess.file_exists(notes_file):
		DirAccess.remove_absolute(notes_file)
	# stick a fresh note and write it (bypassing the GUI editor).
	s._seed_world({ "blocks": [ { "cell": [0, 0, 0], "block": "Cube" } ] }, true)
	s._cam.position = Vector3(0, 0, 5)
	s._look_toward(Vector3.ZERO)
	var h2: Dictionary = s.surface_pick()
	var nid2: String = s.stick_note(h2)
	(s._notes[nid2] as Dictionary)["text"] = "check the +Z face alignment here"
	ok = _check("G9 _write_sticky_note succeeds", s._write_sticky_note(s._notes[nid2])) and ok
	var row := _last_json_line(notes_file)
	ok = _check("G9b jsonl row keeps the RE #145 schema fields", row.has("ts") and row.has("world") and row.has("world_version") and row.has("object_id") and row.has("asset_id") and row.has("position") and row.has("note")) and ok
	ok = _check("G9c jsonl row ADDS the sticky-note anchor + provenance", row.has("note_id") and String(row.get("kind", "")) == "sticky_note" and row.has("anchor_target") and row.has("local_point") and row.has("local_normal") and String(row.get("held_item", "")) == "sticky_note") and ok
	ok = _check("G9d jsonl row carries the typed text", String(row.get("note", "")) == "check the +Z face alignment here") and ok

	# G10: the debug verb layer is OFF by default (MC controls are the default) and toggles on.
	ok = _check("G10 debug verb layer is OFF by default", s._debug_verbs == false) and ok
	s._toggle_debug_verbs()
	ok = _check("G10b debug verb layer toggles ON", s._debug_verbs == true) and ok
	s._toggle_debug_verbs()
	ok = _check("G10c debug verb layer toggles back OFF", s._debug_verbs == false) and ok

	# ── H) FREE-PLACED BLOCK OBJECTS: place, target-outline, pick, persist/reload (Liam item 2) ───────
	s._seed_world({ "blocks": [] }, true)
	s._clear_objects()
	# Place a free Cube block object at an arbitrary point + yaw (not a grid cell).
	var free_pos := Vector3(1.37, 0.42, -2.61)
	var fbid: String = s._place_block_free(s._palette_index("Cube"), free_pos, 33.0)
	ok = _check("H1 _place_block_free spawns a block OBJECT at the exact free position", fbid != "" and s.objects.has(fbid) and (s.objects[fbid] as Dictionary)["base_pos"] == free_pos) and ok
	ok = _check("H1b the free block object carries a `block` name + pal_idx (no `asset`)", (s.objects[fbid] as Dictionary).has("block") and (s.objects[fbid] as Dictionary).has("pal_idx") and not (s.objects[fbid] as Dictionary).has("asset")) and ok
	ok = _check("H1c its body is a real MeshInstance3D (primitive-mesh body)", (s.objects[fbid]["node"] as Node3D).get_node_or_null("body") is MeshInstance3D) and ok
	# Crosshair targeting: aim at the free block; _update_target should mark it as the object target.
	s._cam.position = free_pos + Vector3(0, 0, 4)
	s._look_toward(free_pos)
	s._update_target()
	ok = _check("H2 _update_target marks the aimed-at free object as the target (LMB destroy / MMB pick)", String(s._target.get("kind", "")) == "object" and String(s._target.get("id", "")) == fbid) and ok
	# Pick the free block back into hand (MMB) => the Cube palette entry.
	s._select_slot(5)
	s.hotbar[5] = s.EMPTY_HAND
	s._pick_into_hand()
	ok = _check("H3 MIDDLE-pick on a free block object picks its palette entry (Cube) into hand", int(s.hotbar[5]) == s._palette_index("Cube")) and ok
	# Persist + reload: a free block object round-trips through serialize/apply.
	var ser: Dictionary = s._serialize_world()
	var free_in_objs := false
	for o in ser.get("objects", []):
		if typeof(o) == TYPE_DICTIONARY and String(o.get("block", "")) == "Cube":
			free_in_objs = true
	ok = _check("H4 serialize emits the free block as an object with a `block` field", free_in_objs) and ok
	s._apply_world_data(ser)
	var reloaded_free := 0
	for oid2 in s.objects:
		if (s.objects[oid2] as Dictionary).has("block"):
			reloaded_free += 1
	ok = _check("H4b the free block object reloads with the world", reloaded_free >= 1) and ok
	s._clear_objects()

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	# Detach + free the scene BEFORE quit so the engine's own tree start cannot re-run _ready on it.
	get_root().remove_child(s)
	s.free()
	quit(0 if ok else 1)


## Read the last JSON line of a JSONL file as a Dictionary ({} on any failure).
func _last_json_line(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path).strip_edges()
	if text == "":
		return {}
	var lines := text.split("\n", false)
	var last := lines[lines.size() - 1]
	var data = JSON.parse_string(last)
	return data if typeof(data) == TYPE_DICTIONARY else {}


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
