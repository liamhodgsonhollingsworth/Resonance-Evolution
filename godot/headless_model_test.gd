extends SceneTree
## Headless verification of runtime GLB loading (the "add any 3D model live as a node"
## capability) — fully self-contained, no external asset and no display needed:
##
##   godot --headless --path godot -s res://headless_model_test.gd
##
## It (1) builds a box mesh and exports it to a .glb via GLTFDocument, then (2) loads
## that .glb back through a Model primitive in an arrangement and asserts the mesh
## arrived as a live node. This exercises the exact runtime path Phase 1 relies on.

func _initialize() -> void:
	var ok := true
	var glb := "user://box.glb"
	ok = _check("box GLB exported", _make_box_glb(glb) == OK) and ok
	ok = _check("box GLB on disk", FileAccess.file_exists(glb)) and ok

	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	rt.load_arrangement({
		"format": "resonance.arrangement/v1",
		"nodes": [ { "id": "m", "type": "Model", "params": { "path": glb } } ],
		"wires": []
	})
	rt.evaluate()
	var model: PrimModel = rt.nodes.get("m")
	ok = _check("Model primitive present", model != null) and ok
	ok = _check("model loaded as a live node", model != null and model.model_root != null) and ok
	ok = _check("loaded model contains a mesh", model != null and _has_mesh(model.model_root)) and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

func _make_box_glb(path: String) -> int:
	var root := Node3D.new()
	root.name = "BoxRoot"
	var mi := MeshInstance3D.new()
	mi.name = "Box"
	mi.mesh = BoxMesh.new()
	root.add_child(mi)
	mi.owner = root  # required so the exporter includes the child
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_scene(root, state)
	if err != OK:
		root.queue_free()
		return err
	err = doc.write_to_filesystem(state, path)
	root.queue_free()
	return err

func _has_mesh(n: Node) -> bool:
	if n is MeshInstance3D:
		return true
	for c in n.get_children():
		if _has_mesh(c):
			return true
	return false

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
