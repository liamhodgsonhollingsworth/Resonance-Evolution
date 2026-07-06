extends SceneTree
## HEADLESS verification of the PRECISE MANIPULATION WAND (Liam item 3, 2026-07-05).
##
##   godot --headless --path godot -s res://headless_sandbox_wand_test.gd
##
## The task requires: "grab→move→rotate must change the object's Transform3D as intended — assert
## transform deltas (position + rotation) programmatically". This suite does exactly that: it boots the
## real sandbox scene headless, places an object, drives the WAND handler through the same controller API
## + input-routing the player's clicks/keys/drags hit, and asserts the object's live Transform3D changed
## by the intended deltas — position for MOVE, rotation for ROTATE, on each of the 3 axes — and that the
## precise edits round-trip through world save/reload.
##
## The wand writes DATA (base_pos + yaw/pitch/roll_deg); sandbox_behaviors.tick composes it onto the
## node's Transform3D each frame. So after each edit we tick once and read node.global_transform.

const SandboxScene := preload("res://examples/sandbox_creative.tscn")

var _fails := 0


func _initialize() -> void:
	var ok := true
	OS.set_environment("SANDBOX_WORLDS_DIR", ProjectSettings.globalize_path("user://test_wand_worlds"))
	OS.set_environment("SANDBOX_NOTES_PATH", ProjectSettings.globalize_path("user://test_wand_notes.jsonl"))

	var s = SandboxScene.instantiate()
	get_root().add_child(s)
	await process_frame
	# Force the interaction layer on (headless _ready gates it off) so held-item + HUD paths run for real.
	s._headless = false
	s._build_hud()
	s._refresh_held_item()

	# ── W0) the wand is a real inventory tool + selecting it activates its handler ────────────────────
	var wand_idx := -1
	for i in s.palette.size():
		var e: Dictionary = s.palette[i]
		if String(e.get("kind", "")) == "tool" and String(e.get("tool", "")) == "wand":
			wand_idx = i
			break
	ok = _check("W0 the Manipulation Wand tool exists in the palette (Tools tab)", wand_idx >= 0 and s._categories().has("Tools")) and ok

	# Place ONE free block object to manipulate; camera aims at it so _pick_object() returns it.
	s._seed_world({ "blocks": [] }, true)
	s._clear_objects()
	var start_pos := Vector3(0.0, 0.0, 0.0)
	var oid: String = s._place_block_free(s._palette_index("Cube"), start_pos, 0.0)
	s._cam.position = Vector3(0, 0, 5)
	s._look_toward(start_pos)
	ok = _check("W0b a placed object exists to manipulate", oid != "" and s.objects.has(oid)) and ok

	# Hold the wand.
	s._select_slot(0)
	s.hotbar[0] = wand_idx
	s._refresh_held_item()
	var wand = s._active_handler
	ok = _check("W1 holding the wand activates its handler", wand != null and wand.has_method("engaged_id")) and ok

	# ── W2) RIGHT-click ENGAGES the aimed-at object (controls appear on right click) ──────────────────
	s._click_secondary()
	ok = _check("W2 RIGHT-click grabs the aimed-at object", wand.engaged_id() == oid and s.selected_id == oid) and ok
	ok = _check("W2b default active axis is X (index 0)", wand.active_axis() == 0) and ok

	# ── W3) PRECISE MOVE along X: assert the node's Transform3D ORIGIN moves by the intended delta ────
	var t_before: Transform3D = _node_xform(s, oid)
	# Drag: simulate 200 px rightward mouse motion while LEFT is held (a drag-move along X).
	wand._dragging = true                        # a LEFT-press would set this; set it directly for the test
	var moved: bool = wand.mouse_motion(s, _motion(Vector3(200, 0, 0)))
	wand._dragging = false
	s._tick_objects(0.016)                       # behaviors.tick applies base_pos -> node.position
	var t_after: Transform3D = _node_xform(s, oid)
	var dx := t_after.origin.x - t_before.origin.x
	# move_sensitivity default 0.01 m/px, delta uses (relative.x - relative.y) = 200 => +2.0 m along +X.
	ok = _check("W3 drag MOVES the object precisely along +X (Transform3D origin.x delta ≈ +2.0m)", moved and absf(dx - 2.0) < 0.001) and ok
	ok = _check("W3b move is grid-FREE (origin.x is the exact continuous value, not a grid centre)", absf(t_after.origin.x - 2.0) < 0.001) and ok
	ok = _check("W3c move did NOT change Y or Z (single-axis precision)", absf(t_after.origin.y - t_before.origin.y) < 1e-6 and absf(t_after.origin.z - t_before.origin.z) < 1e-6) and ok

	# ── W4) fine keyboard nudge move (, / .) along the active axis ────────────────────────────────────
	var before_nudge: Transform3D = _node_xform(s, oid)
	# route through the real input path: the wand's key() is dispatched by _unhandled_input.
	s._unhandled_input(_key(KEY_PERIOD))         # nudge +move_step (0.05m) along +X
	s._tick_objects(0.016)
	var after_nudge: Transform3D = _node_xform(s, oid)
	ok = _check("W4 '.' key nudges the object one precise step (+0.05m along +X) via the real input path", absf((after_nudge.origin.x - before_nudge.origin.x) - 0.05) < 1e-6) and ok

	# ── W5) LEFT-click CYCLES the active axis X→Y→Z ───────────────────────────────────────────────────
	s._click_primary()
	ok = _check("W5 LEFT-click cycles axis to Y (index 1)", wand.active_axis() == 1) and ok

	# ── W6) PRECISE ROTATE around Y (yaw): assert the node's BASIS rotates by the intended step ───────
	var basis_before: Basis = _node_xform(s, oid).basis
	# scroll up once = +rotate_step_deg (5°) around the active axis (Y => yaw).
	s._unhandled_input(_click_ev(MOUSE_BUTTON_WHEEL_UP))
	s._tick_objects(0.016)
	var basis_after: Basis = _node_xform(s, oid).basis
	var yaw_delta := _rel_yaw(basis_before, basis_after)
	ok = _check("W6 scroll ROTATES the object +5° around Y (Transform3D basis yaw delta ≈ 5°)", absf(rad_to_deg(yaw_delta) - 5.0) < 0.01) and ok
	# The data field the wand wrote:
	ok = _check("W6b the wand wrote yaw_deg = 5.0 as DATA on the record", absf(float(s.objects[oid].get("yaw_deg", 0.0)) - 5.0) < 1e-6) and ok

	# ── W7) PRECISE ROTATE around X (pitch) and Z (roll) — the 3-axis capability ──────────────────────
	# cycle to Z: currently Y(1) -> left-click -> Z(2)
	s._click_primary()
	ok = _check("W7 LEFT-click cycles axis to Z (index 2)", wand.active_axis() == 2) and ok
	s._unhandled_input(_key(KEY_BRACKETRIGHT))    # ] = +5° around Z (roll)
	s._unhandled_input(_key(KEY_BRACKETRIGHT))    # again => +10° total
	s._tick_objects(0.016)
	ok = _check("W7b ']' rotates around Z: roll_deg = 10.0 as DATA", absf(float(s.objects[oid].get("roll_deg", 0.0)) - 10.0) < 1e-6) and ok
	# cycle back to X and pitch it
	s._click_primary()                            # Z(2) -> X(0)
	ok = _check("W7c axis wraps Z→X", wand.active_axis() == 0) and ok
	s._unhandled_input(_key(KEY_BRACKETLEFT))     # [ = -5° around X (pitch)
	s._tick_objects(0.016)
	ok = _check("W7d '[' rotates around X: pitch_deg = -5.0 as DATA", absf(float(s.objects[oid].get("pitch_deg", 0.0)) + 5.0) < 1e-6) and ok
	# The node's basis is now a genuine 3-axis composite (not identity, not single-axis).
	var comp: Basis = _node_xform(s, oid).basis
	var euler := comp.get_euler()
	ok = _check("W7e node Transform3D is a real 3-axis rotation (all of pitch/yaw/roll non-zero)", absf(euler.x) > 1e-3 and absf(euler.y) > 1e-3 and absf(euler.z) > 1e-3) and ok

	# ── W8) SNAP toggle (G): rotate snaps to snap_rot_deg, move snaps to snap_move_m ──────────────────
	ok = _check("W8 snap is OFF by default (grid-free precision default)", wand.snap_on() == false) and ok
	s._unhandled_input(_key(KEY_G))
	ok = _check("W8b G toggles snap ON", wand.snap_on() == true) and ok
	# with snap on, a rotate snaps yaw to the nearest snap_rot_deg (15°). cycle to Y first.
	s._click_primary()                            # X(0) -> Y(1)
	# yaw is currently 5.0; +5 (scroll) => 10, snapped to nearest 15 => 15.
	s._unhandled_input(_click_ev(MOUSE_BUTTON_WHEEL_UP))
	s._tick_objects(0.016)
	ok = _check("W8c with snap ON, rotate snaps yaw_deg to a 15° multiple (15.0)", absf(float(s.objects[oid].get("yaw_deg", 0.0)) - 15.0) < 1e-6) and ok
	s._unhandled_input(_key(KEY_G))               # snap back off

	# ── W9) RIGHT-click again RELEASES the object ─────────────────────────────────────────────────────
	s._click_secondary()
	ok = _check("W9 RIGHT-click on the engaged object again releases it", wand.engaged_id() == "" and s.selected_id == "") and ok

	# ── W10) precise edits ROUND-TRIP through world save/reload (pitch/roll persist additively) ───────
	var saved_pitch := float(s.objects[oid].get("pitch_deg", 0.0))
	var saved_roll := float(s.objects[oid].get("roll_deg", 0.0))
	var saved_yaw := float(s.objects[oid].get("yaw_deg", 0.0))
	var saved_x := float((s.objects[oid]["base_pos"] as Vector3).x)
	var ser: Dictionary = s._serialize_world()
	# The sandbox now serializes to a resonance.arrangement/v1 graph (every room is a node arrangement).
	# The object's edit metadata (incl. the wand's extra axes) rides on the "_sandbox" block of its
	# Transform node — assert the axes are carried there.
	var found := {}
	for n in ser.get("nodes", []):
		if typeof(n) == TYPE_DICTIONARY and n.has("_sandbox") and String((n["_sandbox"] as Dictionary).get("id", "")) == oid:
			found = n["_sandbox"]
	ok = _check("W10 serialize emits the wand's pitch_deg + roll_deg on the object (in the arrangement's _sandbox metadata)", found.has("pitch_deg") and found.has("roll_deg")) and ok
	s._apply_world_data(ser)
	# find the reloaded object (id preserved).
	ok = _check("W10b object reloads with the world", s.objects.has(oid)) and ok
	var r: Dictionary = s.objects.get(oid, {})
	ok = _check("W10c reloaded object keeps yaw/pitch/roll + moved position (precise transform round-trips)",
		absf(float(r.get("yaw_deg", 0.0)) - saved_yaw) < 1e-6
		and absf(float(r.get("pitch_deg", 0.0)) - saved_pitch) < 1e-6
		and absf(float(r.get("roll_deg", 0.0)) - saved_roll) < 1e-6
		and absf(float((r["base_pos"] as Vector3).x) - saved_x) < 1e-6) and ok

	# ── W11) BACKWARD-COMPAT: an object with ONLY yaw_deg (no pitch/roll) rotates exactly as before ───
	var y_only := {
		"base_pos": Vector3.ZERO, "yaw_deg": 30.0, "scale": 1.0, "behaviors": [],
	}
	var probe := Node3D.new()
	s.add_child(probe)
	var Behaviors = load("res://runtime/sandbox_behaviors.gd")
	Behaviors.tick(y_only, probe, { "t": 0.0, "delta": 0.0 })
	var e2 := probe.rotation
	ok = _check("W11 yaw-only record => rotation is pure Y (pitch=roll=0), identical to pre-wand behavior",
		absf(e2.x) < 1e-6 and absf(rad_to_deg(e2.y) - 30.0) < 1e-4 and absf(e2.z) < 1e-6) and ok
	probe.queue_free()

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	get_root().remove_child(s)
	s.free()
	quit(0 if ok else 1)


# ── helpers ──
func _node_xform(s, id: String) -> Transform3D:
	var rec: Dictionary = s.objects[id]
	return (rec["node"] as Node3D).global_transform

## Relative yaw (Y-euler) delta between two bases, robust for small angles.
func _rel_yaw(a: Basis, b: Basis) -> float:
	return wrapf(b.get_euler().y - a.get_euler().y, -PI, PI)

func _key(code: Key) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.pressed = true
	return ev

func _click_ev(button: MouseButton) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = true
	return ev

func _motion(rel: Vector3) -> InputEventMouseMotion:
	var ev := InputEventMouseMotion.new()
	ev.relative = Vector2(rel.x, rel.y)
	return ev

func _check(label: String, cond: bool) -> bool:
	print(("  PASS " if cond else "  FAIL ") + label)
	if not cond:
		_fails += 1
	return cond
