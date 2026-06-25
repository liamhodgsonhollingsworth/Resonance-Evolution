extends SceneTree
## Headless verification of the walkabout demo scene + its FPS controller, WITHOUT a window.
##
##   <godot> --headless --path godot -s res://headless_walkabout_test.gd
##
## Asserts:
##   (1) the asset-ingestion arrangements on disk parse into Model nodes,
##   (2) the assembled walkabout arrangement runs through GraphRuntime to scene_node DATA,
##   (3) GodotSceneRenderer builds a live node per laid-out asset from that data,
##   (4) the FPS controller instances as a CharacterBody3D and creates its look camera.
## (Mouse-look + movement are interactive and verified by launching the windowed scene; this
## test proves the scene assembles + renders + the controller is structurally sound.)

func _initialize() -> void:
	var ok := true

	# (1) ingested arrangements parse to Model nodes
	var arr_paths := _ingested_arrangements()
	ok = _check("found >=1 ingested arrangement (run asset_ingest_gltf.py first)", arr_paths.size() >= 1) and ok
	var model_count := 0
	for p in arr_paths:
		var data = JSON.parse_string(FileAccess.get_file_as_string(p))
		if typeof(data) == TYPE_DICTIONARY:
			for n in data.get("nodes", []):
				if String(n.get("type")) == "Model":
					model_count += 1
	ok = _check("ingested arrangements contain Model node(s)", model_count >= 1) and ok

	# (2)+(3) assemble -> evaluate -> render
	var arrangement := _assemble(arr_paths)
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	rt.load_arrangement(arrangement)
	var outputs := rt.evaluate()
	ok = _check("runtime evaluated the walkabout arrangement", not outputs.is_empty()) and ok

	# every Transform output should be a scene_node descriptor (renderer-neutral DATA)
	var scene_nodes := 0
	for nid in outputs.keys():
		var node = outputs[nid].get("node")
		if GodotSceneRenderer.is_scene_node(node):
			scene_nodes += 1
	ok = _check("arrangement produced scene_node descriptors", scene_nodes >= 1) and ok

	var renderer := GodotSceneRenderer.new()
	get_root().add_child(renderer)
	renderer.render(outputs, rt.arrangement)
	ok = _check("renderer built live node(s) for the laid-out assets", renderer.get_child_count() >= 1) and ok

	# (4) FPS controller structural soundness
	var player := FpsController.new()
	ok = _check("FpsController is a CharacterBody3D", player is CharacterBody3D) and ok
	get_root().add_child(player)   # triggers _ready -> creates camera
	await process_frame                # let _ready settle in the headless tree
	var has_cam := false
	for c in player.get_children():
		if c is Camera3D:
			has_cam = true
	ok = _check("FpsController created a look Camera3D", has_cam) and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

func _ingested_arrangements() -> Array:
	var out := []
	var dir := "res://assets/ingested/"
	var d := DirAccess.open(dir)
	if d == null:
		return out
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if f.ends_with(".arrangement.json"):
			out.append(dir + f)
		f = d.get_next()
	d.list_dir_end()
	out.sort()
	return out

func _assemble(paths: Array) -> Dictionary:
	var nodes := []
	var wires := []
	var i := 0
	for p in paths:
		var data = JSON.parse_string(FileAccess.get_file_as_string(p))
		if typeof(data) != TYPE_DICTIONARY:
			continue
		for node in data.get("nodes", []):
			if String(node.get("type")) != "Model":
				continue
			var mid := "m_%d" % i
			var tid := "t_%d" % i
			nodes.append({ "id": mid, "type": "Model", "params": node.get("params", {}) })
			nodes.append({ "id": tid, "type": "Transform",
				"params": { "position": [float(i) * 2.5, 0.5, 0.0] } })
			wires.append({ "from": mid, "out": "node", "to": tid, "in": "node" })
			i += 1
	if nodes.is_empty():
		nodes.append({ "id": "fallback", "type": "Model", "params": {} })
	return { "format": "resonance.arrangement/v1", "name": "walkabout", "nodes": nodes, "wires": wires }

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
