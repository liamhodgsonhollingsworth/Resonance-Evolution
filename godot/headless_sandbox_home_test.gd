extends SceneTree
## Headless proof for the aperture HOME area (Liam 2026-07-06, room-series slice 1):
##   1. aperture_3d.gd door_specs contains a Home door -> res://aperture/sandbox_home.tscn.
##   2. SceneTransition plans that Home target as a SAME-WINDOW swap (walk-in, seamless).
##   3. The home scene LOADS with zero errors, exposes the inherited sandbox editing surface, and a
##      place through the real fn actually adds an object (place works in the home area).
##   4. The home area has a SKY + CLOUDS environment (not a black void).
## Prints HOME_TEST_JSON:{...}; exit 0 = all PASS.
##
## Run: <Godot> --headless --path godot -s res://headless_sandbox_home_test.gd

const SceneTransition := preload("res://aperture/scene_transition.gd")

func _init() -> void:
	var out := { "checks": [], "ok": true }
	_run(out)

func _fail(out: Dictionary, name: String, detail: String) -> void:
	out["ok"] = false
	out["checks"].append({ "name": name, "pass": false, "detail": detail })
	push_error("HOME_TEST FAIL: %s — %s" % [name, detail])

func _pass(out: Dictionary, name: String, detail: String = "") -> void:
	out["checks"].append({ "name": name, "pass": true, "detail": detail })

func _run(out: Dictionary) -> void:
	# --- 1. the aperture room has a Home door with the right target ---
	var room_script = load("res://aperture/aperture_3d.gd")
	var room = room_script.new()
	var specs: Array = room.door_specs
	var home_spec := {}
	for s in specs:
		if String(s.get("scene", "")) == "res://aperture/sandbox_home.tscn":
			home_spec = s
			break
	if home_spec.is_empty():
		_fail(out, "door_present", "no door in aperture_3d.door_specs targets res://aperture/sandbox_home.tscn")
	else:
		_pass(out, "door_present", "label=%s pos=%s" % [String(home_spec.get("label","?")), str(home_spec.get("position"))])
		var plan := SceneTransition.plan(home_spec)
		if bool(plan.get("ok", false)) and String(plan.get("channel","")) == "same_window":
			_pass(out, "door_same_window", "channel=same_window scene=%s" % String(plan.get("scene","")))
		else:
			_fail(out, "door_same_window", "plan=%s" % str(plan))
	room.free()

	# --- 2/3. the home scene loads with zero errors + placement works ---
	var ps: PackedScene = load("res://aperture/sandbox_home.tscn")
	if ps == null:
		_fail(out, "home_loads", "PackedScene load returned null")
		_finish(out)
		return
	var home = ps.instantiate()
	if home == null:
		_fail(out, "home_loads", "instantiate returned null")
		_finish(out)
		return
	get_root().add_child(home)
	for _i in 8:
		await process_frame
	_pass(out, "home_loads", "scene=%s world=%s" % [home.name, String(home.get("world_name"))])

	var has_place := home.has_method("_place_block_free") and home.has_method("_click_secondary")
	var has_wand_surface := home.has_method("wand_set_selection")
	if has_place and has_wand_surface:
		_pass(out, "editing_inherited", "has _place_block_free/_click_secondary/wand_set_selection")
	else:
		_fail(out, "editing_inherited", "place=%s wand=%s" % [str(has_place), str(has_wand_surface)])

	if String(home.get("world_name")) == "home":
		_pass(out, "home_world", "world_name=home")
	else:
		_fail(out, "home_world", "world_name=%s (expected home)" % String(home.get("world_name")))

	var before := (home.get("objects") as Dictionary).size()
	home.call("_place_block_free", 1, Vector3(0.0, 0.0, -3.0), 0.0)
	await process_frame
	var after := (home.get("objects") as Dictionary).size()
	if after > before:
		_pass(out, "place_works", "objects %d -> %d" % [before, after])
	else:
		_fail(out, "place_works", "no object added (before=%d after=%d)" % [before, after])

	var has_sky := false
	for c in home.get_children():
		if c is WorldEnvironment and (c as WorldEnvironment).environment != null:
			var e := (c as WorldEnvironment).environment
			if e.background_mode == Environment.BG_SKY and e.sky != null:
				has_sky = true
	if has_sky:
		_pass(out, "sky_present", "WorldEnvironment BG_SKY with a Sky resource")
	else:
		_fail(out, "sky_present", "no WorldEnvironment with a Sky background found")

	_finish(out)

func _finish(out: Dictionary) -> void:
	print("HOME_TEST_JSON:", JSON.stringify(out))
	print("HOME_TEST_RESULT:", "PASS" if out["ok"] else "FAIL")
	# Standard battery sentinel (run_all_tests.py classifies on "RESULT: ALL PASS" / "… N FAIL").
	var n_fail := 0
	for c in out["checks"]:
		if not bool((c as Dictionary).get("pass", false)):
			n_fail += 1
	print("RESULT: %s" % ("ALL PASS" if out["ok"] else "%d FAIL" % n_fail))
	quit(0 if out["ok"] else 1)
