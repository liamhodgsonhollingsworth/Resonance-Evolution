extends SceneTree
## Headless verification that placement composes by WIRING (Model -> Transform):
##
##   godot --headless --path godot -s res://headless_transform_test.gd
##
## Builds a box GLB, wires a Model into a Transform with a known position, evaluates,
## and asserts the live model node actually moved.

func _initialize() -> void:
	var ok := true
	var glb := "user://box_t.glb"
	ok = _check("box GLB exported", _make_box_glb(glb) == OK) and ok

	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	rt.load_arrangement({
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "box", "type": "Model", "params": { "path": glb } },
			{ "id": "place", "type": "Transform", "params": { "position": [1.0, 2.0, 3.0] } }
		],
		"wires": [ { "from": "box", "out": "node", "to": "place", "in": "node" } ]
	})
	rt.evaluate()

	var model: PrimModel = rt.nodes.get("box")
	ok = _check("model loaded", model != null and model.model_root != null) and ok
	var moved := model != null and model.model_root != null and model.model_root.position == Vector3(1.0, 2.0, 3.0)
	ok = _check("Transform moved the wired model to (1,2,3)", moved) and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

func _make_box_glb(path: String) -> int:
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	root.add_child(mi)
	mi.owner = root
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_scene(root, state)
	if err == OK:
		err = doc.write_to_filesystem(state, path)
	root.queue_free()
	return err

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
