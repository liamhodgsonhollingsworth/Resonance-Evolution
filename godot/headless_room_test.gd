extends SceneTree
## REAL-TREE #049 TEST for Slice 1C — 3D ROOM + FIXTURE ASSETS (visi-sonor arc, item 3).
##
##   <godot> --headless --path godot -s res://headless_room_test.gd
##
## Proves, on the SAME GraphRuntime the running room hot-loads arrangements into (not a standalone
## node — that would be the #049 false pass), that the room + fixture substrate works WITHOUT any
## network fetch (the C-ideal: an absent GLB falls back to a placeholder mesh, never a crash):
##
##  1. demo_room.json loads as an arrangement into a real GraphRuntime — every fixture node
##     instantiates and the whole graph evaluates.
##  2. prim_asset_import (AssetImport): a manifest id whose GLB is PRESENT emits a mesh.source="glb"
##     scene_node; a manifest id whose GLB is ABSENT (not yet downloaded) falls back to a placeholder
##     mesh.source="primitive" (box/cylinder) — the exact renderer-existing dispatch, zero engine edit;
##     an UNKNOWN id emits a placeholder too (declared no-op, never a crash).
##  3. Each fixture in demo_room.json exposes a prim_light descriptor (renderer-neutral glTF
##     KHR_lights_punctual DATA) AND a device addr — drivable by BOTH the 3D renderer and a real WLED.
##  4. prim_led_strip (LedStrip): emits an ARRAY of prim_light descriptors sampled along a path, each
##     PIXEL ADDRESSABLE (base_addr + i), plus per-pixel device.set_led-compatible payloads. A driven
##     pixel value flows to exactly its addr. Zero pixels -> empty array, no crash (C-ideal).
##  5. TEXT-EQUIVALENCE (gate T): every output is plain DATA on a wire (dicts / float arrays), renderer-
##     neutral, so any downstream node subscribes — this headless text path IS the backend a GUI drives.

const AssetLibrary := preload("res://runtime/asset_library.gd")

var _fail := 0

func _check(name: String, cond: bool) -> bool:
	print(("PASS  " if cond else "FAIL  ") + name)
	if not cond:
		_fail += 1
	return cond

func _initialize() -> void:
	_run()

func _run() -> void:
	# --- 1. demo_room.json loads + evaluates on a REAL room runtime -----------------------------------
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	rt.load_json("res://arrangements/demo_room.json")
	_check("demo_room.json loaded into a real GraphRuntime (nodes live)", rt.nodes.size() > 0)
	var room_out := rt.evaluate()
	_check("demo_room.json evaluates without crashing (outputs produced)", room_out.size() > 0)

	# The room arrangement composes a Group scene_node (the room shell + fixtures). It must be a valid
	# renderer-neutral scene_node with children (walls/floor + lamps) — plain DATA (gate T).
	var room_node = room_out.get("room", {}).get("node")
	_check("demo_room emits a room scene_node with children (shell + fixtures composed)",
		typeof(room_node) == TYPE_DICTIONARY and room_node.has("children")
		and (room_node["children"] as Array).size() > 0)

	# --- 2. prim_asset_import: PRESENT glb -> glb source; ABSENT / UNKNOWN -> placeholder primitive ---
	var lib := AssetLibrary.new()
	get_root().add_child(lib)
	var manifest_count := lib.load_manifest()
	_check("AssetLibrary read the repo manifest (>0 assets indexed)", manifest_count > 0)

	# Pick a manifest id whose GLB actually EXISTS on disk (the 34 nature kit assets are vendored).
	var present_id := ""
	for id in lib.manifest.keys():
		var p := String(lib.manifest[id].get("path", ""))
		if p != "" and FileAccess.file_exists(p):
			present_id = String(id)
			break
	_check("found a manifest id whose GLB is present on disk (for the glb-source path)", present_id != "")

	var imp: Node = load("res://primitives/prim_asset_import.gd").new()
	imp.params = { "id": present_id, "manifest_path": "res://assets/manifest.json" }
	get_root().add_child(imp)
	var present_out: Dictionary = imp.evaluate({})
	var pnode = present_out.get("node")
	_check("AssetImport(present id) emits a scene_node", typeof(pnode) == TYPE_DICTIONARY and pnode.has("mesh"))
	_check("AssetImport(present id) -> mesh.source='glb' (real asset path)",
		typeof(pnode.get("mesh")) == TYPE_DICTIONARY and String(pnode["mesh"].get("source")) == "glb"
		and String(pnode["mesh"].get("path")) != "")
	_check("AssetImport(present id) reports NOT a placeholder", present_out.get("placeholder") == false)

	# An id from the LIGHTING manifest whose GLB is NOT downloaded -> placeholder primitive box/cylinder.
	# (manifest_lighting_room.json ships REAL urls but the GLB bytes are absent until fetched — the
	#  whole point of the C-ideal: fully headless-testable without any network fetch.)
	var imp2: Node = load("res://primitives/prim_asset_import.gd").new()
	imp2.params = { "id": "kenney_furniture__lamp_round_floor", "manifest_path": "res://assets/manifest_lighting_room.json",
		"placeholder_shape": "cylinder" }
	get_root().add_child(imp2)
	var absent_out: Dictionary = imp2.evaluate({})
	var anode = absent_out.get("node")
	_check("AssetImport(absent GLB) still emits a scene_node (no crash)", typeof(anode) == TYPE_DICTIONARY)
	_check("AssetImport(absent GLB) -> PLACEHOLDER mesh.source='primitive' (box/cylinder)",
		typeof(anode.get("mesh")) == TYPE_DICTIONARY and String(anode["mesh"].get("source")) == "primitive")
	_check("AssetImport(absent GLB) reports placeholder=true (declared fallback, C-ideal)",
		absent_out.get("placeholder") == true)
	_check("AssetImport(absent GLB) honours the requested placeholder_shape",
		String(anode["mesh"].get("shape")) == "cylinder")

	# An UNKNOWN id (not in ANY manifest) -> placeholder too, never a crash.
	var imp3: Node = load("res://primitives/prim_asset_import.gd").new()
	imp3.params = { "id": "no_such_asset_xyz", "manifest_path": "res://assets/manifest_lighting_room.json" }
	get_root().add_child(imp3)
	var unk_out: Dictionary = imp3.evaluate({})
	_check("AssetImport(unknown id) -> placeholder, no crash (C-ideal declared no-op)",
		typeof(unk_out.get("node")) == TYPE_DICTIONARY and unk_out.get("placeholder") == true
		and String(unk_out["node"]["mesh"].get("source")) == "primitive")

	# The wired `id` input overrides params.id (rewireable — a different id is a data change, gate T).
	var imp4: Node = load("res://primitives/prim_asset_import.gd").new()
	imp4.params = { "id": "no_such_asset_xyz", "manifest_path": "res://assets/manifest.json" }
	get_root().add_child(imp4)
	var wired_out: Dictionary = imp4.evaluate({ "id": present_id })
	_check("AssetImport reads the wired `id` input (overrides params) — rewireable",
		String(wired_out["node"]["mesh"].get("source")) == "glb")

	# --- 3. each fixture exposes a prim_light + a device addr ----------------------------------------
	# The room arrangement has Light nodes (fixtures) each carrying an addr param. Every Light output is
	# a renderer-neutral KHR_lights_punctual descriptor; each has an addr so it drives BOTH renderer +
	# a real WLED via the same descriptor.
	var light_count := 0
	var lights_with_addr := 0
	for nid in rt.nodes:
		var prim = rt.nodes[nid]
		if prim.prim_type == "Light":
			light_count += 1
			var lout = room_out.get(nid, {}).get("light")
			if typeof(lout) == TYPE_DICTIONARY and String(lout.get("kind")) == "light":
				# addr rides as a param on the fixture (the device address); confirm the arrangement set one.
				if prim.params.has("addr"):
					lights_with_addr += 1
	_check("demo_room has >=2 lamp fixtures each emitting a prim_light descriptor", light_count >= 2)
	_check("every lamp fixture carries a device addr (drivable by renderer AND real WLED)",
		lights_with_addr == light_count and light_count > 0)

	# --- 4. prim_led_strip: array of addressable prim_light pixels -----------------------------------
	var strip: Node = load("res://primitives/prim_led_strip.gd").new()
	strip.params = {
		"count": 8, "base_addr": 100,
		"start": [0.0, 2.0, 0.0], "end": [3.0, 2.0, 0.0],
		"color": [0.2, 0.6, 1.0], "intensity": 1.0,
	}
	get_root().add_child(strip)
	var strip_out: Dictionary = strip.evaluate({})
	var pixels = strip_out.get("lights")
	_check("LedStrip emits an ARRAY of prim_light descriptors (one per pixel)",
		typeof(pixels) == TYPE_ARRAY and (pixels as Array).size() == 8)
	var all_lights := true
	var addrs_ok := true
	for i in (pixels as Array).size():
		var px = pixels[i]
		if typeof(px) != TYPE_DICTIONARY or String(px.get("kind")) != "light":
			all_lights = false
		# each pixel addressable: base_addr + i
		if int(px.get("addr", -1)) != 100 + i:
			addrs_ok = false
	_check("every LedStrip pixel is a renderer-neutral prim_light descriptor (gate T)", all_lights)
	_check("every LedStrip pixel is ADDRESSABLE (addr = base_addr + index)", addrs_ok)

	# Pixels are laid along the path: first pixel at start, last at end (linear spline sampling).
	var first_t = pixels[0]["transform"]["translation"]
	var last_t = pixels[7]["transform"]["translation"]
	_check("LedStrip samples pixels along the path (first at start x=0, last at end x=3)",
		abs(float(first_t[0]) - 0.0) < 0.001 and abs(float(last_t[0]) - 3.0) < 0.001)

	# set_led-compatible per-pixel payloads: drivable by device.set_led (same {r,g,b,addr} shape).
	var payloads = strip_out.get("set_led")
	_check("LedStrip emits per-pixel device.set_led payloads ({r,g,b,addr})",
		typeof(payloads) == TYPE_ARRAY and (payloads as Array).size() == 8
		and typeof(payloads[0]) == TYPE_DICTIONARY and payloads[0].has("r") and payloads[0].has("addr")
		and int(payloads[3]["addr"]) == 103)

	# A wired per-pixel color array drives exactly its pixel (drivable by device.set_led -> rewireable).
	var strip2: Node = load("res://primitives/prim_led_strip.gd").new()
	strip2.params = { "count": 4, "base_addr": 0, "start": [0, 0, 0], "end": [1, 0, 0] }
	get_root().add_child(strip2)
	# `colors` input: per-pixel [r,g,b]; pixel 2 is red.
	var driven: Dictionary = strip2.evaluate({ "colors": [[0, 0, 0], [0, 0, 0], [1.0, 0.0, 0.0], [0, 0, 0]] })
	var dpix = driven.get("lights")
	_check("LedStrip drives a per-pixel wired color to EXACTLY that pixel (pixel 2 = red)",
		abs(float(dpix[2]["color"][0]) - 1.0) < 0.001 and abs(float(dpix[0]["color"][0]) - 0.0) < 0.001)

	# C-ideal: zero pixels -> empty arrays, never a crash.
	var strip0: Node = load("res://primitives/prim_led_strip.gd").new()
	strip0.params = { "count": 0 }
	get_root().add_child(strip0)
	var empty: Dictionary = strip0.evaluate({})
	_check("LedStrip(count=0) -> empty arrays, no crash (C-ideal)",
		typeof(empty.get("lights")) == TYPE_ARRAY and (empty.get("lights") as Array).is_empty()
		and typeof(empty.get("set_led")) == TYPE_ARRAY and (empty.get("set_led") as Array).is_empty())

	rt.free()
	print("RESULT: ", "ALL PASS" if _fail == 0 else ("%d FAIL" % _fail))
	quit(0 if _fail == 0 else 1)
