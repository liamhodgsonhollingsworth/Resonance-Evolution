extends SceneTree
## Headless verification of the WORLD-BUILDER systems (spec apx_e5c6f8dc), no display needed:
##
##   godot --headless --path godot -s res://headless_world_builder_test.gd
##
## Covers the four new seams the sandbox composes:
##   A) AssetLibrary sync core — manifest-only startup, on-demand load, template cache
##      (N placements = 1 load), unknown ids fail clean, evict frees.
##   B) AssetLibrary ASYNC lazy path — zero assets loaded at startup, background request,
##      preload_set warms an arrangement's set, evict_except releases on scene switch.
##   C) WorldStore — seed-on-first-touch, APPEND-ONLY versioned saves (v1 immutable after
##      v2 lands), per-version load, preload-set derivation from world data.
##   D) Behaviors — data descriptors, toggle round-trip, DETERMINISTIC pure-offset ticks
##      (spin/orbit/bob), stateful follow, light child sync add/remove.
##   E) Sandbox integration (script-level, detached) — all-assets palette, world load with
##      placeholder objects, lazy swap-in, rearrange verbs, serialize round-trip, and the
##      notes-on-things JSONL handoff channel.

const AssetLibraryScript := preload("res://runtime/asset_library.gd")
const WorldStoreScript := preload("res://runtime/world_store.gd")
const Behaviors := preload("res://runtime/sandbox_behaviors.gd")
const SandboxScript := preload("res://examples/sandbox_creative.gd")

var _fails := 0


func _initialize() -> void:
	var ok := true

	# ══ A) AssetLibrary — sync core ═══════════════════════════════════════════════════════
	var lib = AssetLibraryScript.new()
	var n: int = lib.load_manifest()
	ok = _check("A1 manifest indexes 34 assets", n == 34 and lib.manifest.size() == 34) and ok
	ok = _check("A2 manifest carries 2 kits", (lib.kits as Array).size() == 2) and ok
	var per_kit_total := 0
	for kit in lib.kits:
		per_kit_total += (lib.kit_assets(String(kit)) as Array).size()
	ok = _check("A3 every asset belongs to a kit tab (34 across kits)", per_kit_total == 34) and ok
	var sample := String((lib.kit_assets(String(lib.kits[0]))[0] as Dictionary)["id"])
	ok = _check("A4 startup loads NOTHING (metadata only)", lib.loaded_count() == 0) and ok
	ok = _check("A5 request_sync loads a real GLB on demand", lib.request_sync(sample) and lib.is_loaded(sample)) and ok
	var i1: Node3D = lib.instantiate(sample)
	var i2: Node3D = lib.instantiate(sample)
	ok = _check("A6 instantiate hands out DISTINCT instances", i1 != null and i2 != null and i1 != i2 and i1.get_child_count() > 0) and ok
	i1.free()
	i2.free()
	lib.request_sync(sample)
	ok = _check("A7 cache: N placements cost ONE load", lib.loads_completed == 1) and ok
	ok = _check("A8 unknown id fails clean", not lib.request_sync("no_such_asset") and lib.instantiate("no_such_asset") == null and not lib.has_asset("no_such_asset")) and ok
	var freed: int = lib.evict_except([])
	ok = _check("A9 evict_except([]) frees everything", freed == 1 and lib.loaded_count() == 0 and not lib.is_loaded(sample)) and ok
	lib.free()

	# ══ B) AssetLibrary — ASYNC lazy path (in-tree, background threads) ═══════════════════
	var alib = AssetLibraryScript.new()
	get_root().add_child(alib)
	await process_frame                      # tree starts; _ready/_process become live
	alib.load_manifest()
	ok = _check("B1 async lib starts with zero assets loaded", alib.loaded_count() == 0 and alib.pending_count() == 0) and ok
	var kit0: Array = alib.kit_assets(String(alib.kits[0]))
	var a_id := String((kit0[0] as Dictionary)["id"])
	var b_id := String((kit0[1] as Dictionary)["id"])
	alib.request(a_id)
	ok = _check("B2 request goes pending (placeholder path)", alib.is_pending(a_id) and not alib.is_loaded(a_id)) and ok
	var deadline := Time.get_ticks_msec() + 20000
	while not alib.is_loaded(a_id) and Time.get_ticks_msec() < deadline:
		await process_frame
	ok = _check("B3 background load lands (asset usable)", alib.is_loaded(a_id) and alib.instantiate(a_id) is Node3D) and ok
	alib.preload_set([a_id, b_id])
	deadline = Time.get_ticks_msec() + 20000
	while alib.pending_count() > 0 and Time.get_ticks_msec() < deadline:
		await process_frame
	ok = _check("B4 preload_set warms an arrangement's asset set", alib.is_loaded(a_id) and alib.is_loaded(b_id)) and ok
	var kept: int = alib.evict_except([a_id])
	ok = _check("B5 scene-switch evict keeps the new set only", kept == 1 and alib.is_loaded(a_id) and not alib.is_loaded(b_id)) and ok
	alib.evict_except([])
	get_root().remove_child(alib)
	alib.free()

	# ══ C) WorldStore — append-only versioned arrangements ════════════════════════════════
	var tmp_worlds := ProjectSettings.globalize_path("user://test_wb_worlds")
	_rm_rf(tmp_worlds)
	var store = WorldStoreScript.new(tmp_worlds)
	ok = _check("C1 fresh store is empty", (store.list_worlds() as Array).is_empty() and store.latest_version("starter") == 0) and ok
	var seeded: Array = store.seed_from()
	ok = _check("C2 first touch seeds the committed worlds", seeded.size() == 2 and store.list_worlds() == ["nature_gallery", "starter"]) and ok
	var w: Dictionary = store.load_world("starter")
	ok = _check("C3 starter loads (40 blocks, 5 objects, v1)", (w.get("blocks", []) as Array).size() == 40 and (w.get("objects", []) as Array).size() == 5 and int(w.get("version", 0)) == 1) and ok
	var pre: Array = WorldStoreScript.preload_set_of(w)
	ok = _check("C4 preload set derives 5 unique asset ids from the world", pre.size() == 5) and ok
	var v1_path := String(store.version_path("starter", 1))
	var v1_before := FileAccess.get_file_as_string(v1_path)
	var w2 := w.duplicate(true)
	w2["marker"] = "edited"
	var v: int = store.save_version("starter", w2)
	ok = _check("C5 save is APPEND-ONLY (writes v2)", v == 2 and store.latest_version("starter") == 2) and ok
	ok = _check("C6 v1 is untouched after v2 lands", FileAccess.get_file_as_string(v1_path) == v1_before) and ok
	ok = _check("C7 latest load returns v2, explicit load returns v1", String(store.load_world("starter").get("marker", "")) == "edited" and not store.load_world("starter", 1).has("marker")) and ok
	ok = _check("C8 re-seeding never overwrites store content", (store.seed_from() as Array).is_empty() and store.latest_version("starter") == 2) and ok
	ok = _check("C9 a brand-new world starts at v1", store.save_version("fresh_world", { "blocks": [], "objects": [] }) == 1 and store.list_worlds().has("fresh_world")) and ok

	# ══ D) Behaviors — data descriptors + deterministic ticks ═════════════════════════════
	var d: Dictionary = Behaviors.make("spin")
	ok = _check("D1 make() normalizes with defaults", String(d["type"]) == "spin" and float(d["params"]["speed_deg"]) == 45.0) and ok
	ok = _check("D2 unknown behavior type is rejected", (Behaviors.make("bogus") as Dictionary).is_empty()) and ok
	var bl: Array = Behaviors.toggle([], "bob")
	ok = _check("D3 toggle attaches", Behaviors.has_behavior(bl, "bob") and bl.size() == 1) and ok
	ok = _check("D4 toggle again detaches", (Behaviors.toggle(bl, "bob") as Array).is_empty()) and ok
	var node := Node3D.new()
	# spin: pure function of t — two ticks at the same t give the SAME transform.
	var rec := { "base_pos": Vector3.ZERO, "yaw_deg": 0.0, "scale": 1.0,
		"behaviors": [Behaviors.make("spin", { "speed_deg": 90.0 })] }
	Behaviors.tick(rec, node, { "t": 2.0, "delta": 0.016 })
	var yaw_first := node.rotation.y
	Behaviors.tick(rec, node, { "t": 2.0, "delta": 0.016 })
	ok = _check("D5 spin is deterministic (offset from base, not accumulated)", absf(yaw_first - node.rotation.y) < 1e-6 and absf(absf(yaw_first) - PI) < 0.01) and ok
	# orbit: radius 2 at quarter-period → offset (0, 0, 2).
	rec = { "base_pos": Vector3(1, 0, 1), "yaw_deg": 0.0, "scale": 1.0,
		"behaviors": [Behaviors.make("orbit", { "radius": 2.0, "speed_deg": 90.0 })] }
	var pos: Vector3 = Behaviors.tick(rec, node, { "t": 1.0, "delta": 0.016 })
	ok = _check("D6 orbit circles the base position", pos.distance_to(Vector3(1, 0, 3)) < 0.01) and ok
	# bob: amplitude 0.5, period 2 → +0.5 at t = period/4.
	rec = { "base_pos": Vector3.ZERO, "yaw_deg": 0.0, "scale": 1.0,
		"behaviors": [Behaviors.make("bob", { "amplitude": 0.5, "period": 2.0 })] }
	pos = Behaviors.tick(rec, node, { "t": 0.5, "delta": 0.016 })
	ok = _check("D7 bob floats sinusoidally", absf(pos.y - 0.5) < 0.01) and ok
	# follow: moves the BASE toward the player, stops inside min_dist.
	rec = { "base_pos": Vector3.ZERO, "yaw_deg": 0.0, "scale": 1.0,
		"behaviors": [Behaviors.make("follow", { "speed": 2.0, "min_dist": 3.0 })] }
	Behaviors.tick(rec, node, { "t": 0.0, "delta": 0.5, "player_pos": Vector3(10, 0, 0) })
	ok = _check("D8 follow walks toward the player (stateful base)", (rec["base_pos"] as Vector3).distance_to(Vector3(1, 0, 0)) < 0.01) and ok
	Behaviors.tick(rec, node, { "t": 0.0, "delta": 0.5, "player_pos": Vector3(1.5, 0, 0) })
	ok = _check("D9 follow stops inside min_dist", (rec["base_pos"] as Vector3).distance_to(Vector3(1, 0, 0)) < 0.01) and ok
	# light: managed child node appears with the descriptor's color, leaves on detach.
	rec = { "base_pos": Vector3.ZERO, "yaw_deg": 0.0, "scale": 1.0,
		"behaviors": [Behaviors.make("light", { "color": [1.0, 0.0, 0.0], "energy": 3.0 })] }
	Behaviors.tick(rec, node, { "t": 0.0, "delta": 0.016 })
	var light := node.get_node_or_null(Behaviors.LIGHT_NODE_NAME) as OmniLight3D
	ok = _check("D10 light behavior attaches an OmniLight3D child", light != null and light.light_color.r > 0.99 and light.light_color.g < 0.01 and absf(light.light_energy - 3.0) < 0.001) and ok
	rec["behaviors"] = []
	Behaviors.tick(rec, node, { "t": 0.0, "delta": 0.016 })
	ok = _check("D11 removing the light behavior removes the child", light.is_queued_for_deletion()) and ok
	node.free()

	# ══ E) Sandbox integration — the composed world-builder seams ═════════════════════════
	var s = SandboxScript.new()
	s._headless = true
	s._build_palette()
	s._default_hotbar()
	s._build_world_nodes()
	s.assets = AssetLibraryScript.new()
	s.add_child(s.assets)
	s.assets.load_manifest()
	s._extend_palette_with_assets()
	ok = _check("E1 inventory palette = 14 blocks + ALL 34 imported assets", s.palette.size() == 48) and ok
	ok = _check("E2 categories = 3 block tabs + one per kit", (s._categories() as Array).size() == 5) and ok
	var tmp_e := ProjectSettings.globalize_path("user://test_wb_integration")
	_rm_rf(tmp_e)
	s.store = WorldStoreScript.new(tmp_e)
	s.store.seed_from()
	s.world_name = "starter"
	ok = _check("E3 the active world loads from the store", s._load_active_world() and s.world.size() == 40 and s.objects.size() == 5) and ok
	var all_placeholders := true
	for id in s.objects:
		var r: Dictionary = s.objects[id]
		if (r["node"] as Node3D).get_node_or_null("body") == null:
			all_placeholders = false
	ok = _check("E4 every object gets an immediate body (placeholder until the lazy load lands)", all_placeholders) and ok
	# The lazy swap-in: load one asset synchronously, deliver asset_ready, the record upgrades.
	var swap_asset := String((s.objects["obj_1"] as Dictionary)["asset"])
	s.assets.request_sync(swap_asset)
	s._on_asset_ready(swap_asset)
	ok = _check("E5 asset_ready swaps the placeholder for the real model", bool((s.objects["obj_1"] as Dictionary)["loaded"])) and ok
	# Rearrange verbs mutate the DATA record.
	s.selected_id = "obj_2"
	s._rotate_selected(15.0)
	s._scale_selected(1.1)
	var r2: Dictionary = s.objects["obj_2"]
	ok = _check("E6 rotate + scale land on the record", absf(float(r2["yaw_deg"])) > 14.0 and absf(float(r2["scale"]) - 1.1) < 0.001) and ok
	s._delete_object("obj_3")
	ok = _check("E7 delete removes the object (and clears selection state safely)", not s.objects.has("obj_3") and s.objects.size() == 4) and ok
	var new_id: String = s._place_object(swap_asset, Vector3(9, 0, 9), 45.0, 1.5)
	ok = _check("E8 placing a manifest asset creates a fresh unique id", new_id != "" and s.objects.has(new_id) and new_id != "obj_5") and ok
	# Serialize → append-only save → reload round-trip.
	var v_new: int = s.store.save_version(s.world_name, s._serialize_world())
	var back: Dictionary = s.store.load_world(s.world_name)
	ok = _check("E9 serialize/save/reload round-trips (v2, 40 blocks, 5 objects)", v_new == 2 and (back["blocks"] as Array).size() == 40 and (back["objects"] as Array).size() == 5) and ok
	var kept_yaw := false
	for o in back["objects"]:
		if String(o.get("id", "")) == new_id and absf(float(o.get("yaw_deg", 0.0)) - 45.0) < 0.001 and absf(float(o.get("scale", 0.0)) - 1.5) < 0.001:
			kept_yaw = true
	ok = _check("E10 the placed object's transform survives the round-trip", kept_yaw) and ok
	# Notes-on-things: the Claude Code handoff channel (JSONL, append-only).
	var notes := ProjectSettings.globalize_path("user://test_wb_notes.jsonl")
	if FileAccess.file_exists(notes):
		DirAccess.remove_absolute(notes)
	s.notes_path = notes
	ok = _check("E11 a note on an object writes", s._write_note("make this tree sway in the wind", "obj_2")) and ok
	s.selected_id = ""                       # deselect: N notes the selection when one exists
	ok = _check("E12 a note on a bare location writes", s._write_note("add a pond here", "", Vector3(3, 0, -7))) and ok
	var lines := []
	var f := FileAccess.open(notes, FileAccess.READ)
	while f != null and not f.eof_reached():
		var line := f.get_line()
		if line.strip_edges() != "":
			lines.append(JSON.parse_string(line))
	if f != null:
		f.close()
	ok = _check("E13 notes append as JSONL (2 lines)", lines.size() == 2) and ok
	var n1: Dictionary = lines[0] if lines.size() > 0 and typeof(lines[0]) == TYPE_DICTIONARY else {}
	var n2: Dictionary = lines[1] if lines.size() > 1 and typeof(lines[1]) == TYPE_DICTIONARY else {}
	ok = _check("E14 object note carries full handoff context (ts/world/version/object/asset/position/text)",
		String(n1.get("object_id", "")) == "obj_2" and String(n1.get("asset_id", "")) != ""
		and String(n1.get("world", "")) == "starter" and int(n1.get("world_version", 0)) == 2
		and n1.has("ts") and (n1.get("position", []) as Array).size() == 3
		and String(n1.get("note", "")) == "make this tree sway in the wind") and ok
	ok = _check("E15 location note carries the position, no object", String(n2.get("object_id", "x")) == "" and (n2.get("position", []) as Array) == [3.0, 0.0, -7.0]) and ok
	s.assets.evict_except([])                # wait out background parses before teardown
	s.free()

	print("RESULT: ", "ALL PASS" if _fails == 0 else "FAILURES PRESENT (%d)" % _fails)
	quit(0 if _fails == 0 else 1)


func _check(label: String, cond: bool) -> bool:
	print(("  PASS " if cond else "  FAIL ") + label)
	if not cond:
		_fails += 1
	return cond


## Recursive delete of a test directory (absolute path). Only ever pointed at user:// temp dirs.
func _rm_rf(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	for sub in d.get_directories():
		_rm_rf(path.path_join(sub))
	DirAccess.remove_absolute(path)
