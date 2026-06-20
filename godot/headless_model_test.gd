extends SceneTree
## Headless verification that Model emits a renderer-NEUTRAL scene_node descriptor (DATA),
## and that the Godot renderer delegate builds a live mesh node from it. Model no longer
## holds a live node itself — portability lives in the data, rendering in the delegate.
##
##   godot --headless --path godot -s res://headless_model_test.gd
##
## (1) builds a box .glb via GLTFDocument, then (2) runs it through a Model primitive and
## asserts the output is a JSON-serializable descriptor referencing the GLB, then (3) feeds
## the eval output to GodotSceneRenderer and asserts a live mesh node was built.

func _initialize() -> void:
	var ok := true
	var glb := "user://box.glb"
	ok = _check("box GLB exported", _make_box_glb(glb) == OK) and ok
	ok = _check("box GLB on disk", FileAccess.file_exists(glb)) and ok

	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	rt.load_arrangement({
		"format": "resonance.arrangement/v1",
		"nodes": [ { "id": "m", "type": "Model", "params": { "path": glb, "name": "box_model" } } ],
		"wires": []
	})
	var outputs := rt.evaluate()
	var desc = outputs.get("m", {}).get("node")

	ok = _check("Model emits a Dictionary descriptor (not a live node)", typeof(desc) == TYPE_DICTIONARY) and ok
	ok = _check("descriptor references the GLB by path",
		typeof(desc) == TYPE_DICTIONARY and String((desc.get("mesh", {}) as Dictionary).get("path", "")) == glb) and ok
	ok = _check("descriptor is JSON-serializable (no live objects)",
		typeof(desc) == TYPE_DICTIONARY and typeof(JSON.parse_string(JSON.stringify(desc))) == TYPE_DICTIONARY) and ok

	var renderer := GodotSceneRenderer.new()
	get_root().add_child(renderer)
	renderer.render(outputs, { "wires": [] })
	ok = _check("delegate built one node from the descriptor", renderer.get_child_count() == 1) and ok
	ok = _check("built node contains a mesh", renderer.get_child_count() == 1 and _has_mesh(renderer.get_child(0))) and ok

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
		root.free()
		return err
	err = doc.write_to_filesystem(state, path)
	root.free()
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
