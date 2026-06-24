extends SceneTree
## Headless verification that placement composes by WIRING (Model -> Transform) as DATA:
## Transform sets TRS on the scene_node descriptor (emitting a glTF quaternion for rotation),
## and the renderer delegate places the built node accordingly. No live node crosses a wire.
##
##   godot --headless --path godot -s res://headless_transform_test.gd

func _initialize() -> void:
	var ok := true
	var glb := "user://box_t.glb"
	ok = _check("box GLB exported", _make_box_glb(glb) == OK) and ok

	var arrangement := {
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "box", "type": "Model", "params": { "path": glb, "name": "box_model" } },
			{ "id": "place", "type": "Transform", "params": { "position": [1.0, 2.0, 3.0], "rotation": [0.0, 90.0, 0.0] } }
		],
		"wires": [ { "from": "box", "out": "node", "to": "place", "in": "node" } ]
	}
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	rt.load_arrangement(arrangement)
	var outputs := rt.evaluate()
	var desc = outputs.get("place", {}).get("node")

	ok = _check("Transform output is a descriptor (Dictionary)", typeof(desc) == TYPE_DICTIONARY) and ok
	var t = desc.get("translation") if typeof(desc) == TYPE_DICTIONARY else null
	ok = _check("descriptor placed at (1,2,3) as data",
		t is Array and abs(float(t[0]) - 1.0) < 1e-5 and abs(float(t[1]) - 2.0) < 1e-5 and abs(float(t[2]) - 3.0) < 1e-5) and ok
	# rotation must be the ACTUAL quaternion for 90deg about Y, not merely a 4-element array.
	var expected := Quaternion.from_euler(Vector3(0.0, deg_to_rad(90.0), 0.0))
	var r = desc.get("rotation") if typeof(desc) == TYPE_DICTIONARY else null
	var rq := Quaternion.IDENTITY
	if r is Array and (r as Array).size() == 4:
		rq = Quaternion(float(r[0]), float(r[1]), float(r[2]), float(r[3]))
	ok = _check("rotation emitted as the correct glTF quaternion (90deg about Y)",
		r is Array and (r as Array).size() == 4 and rq.is_equal_approx(expected)) and ok

	var renderer := GodotSceneRenderer.new()
	get_root().add_child(renderer)
	renderer.render(outputs, arrangement)
	var node: Node3D = renderer.get_child(0) if renderer.get_child_count() > 0 else null
	ok = _check("delegate placed the built node at (1,2,3)",
		node != null and node.transform.origin.is_equal_approx(Vector3(1, 2, 3))) and ok
	ok = _check("delegate applied the rotation to the built node's basis",
		node != null and node.transform.basis.is_equal_approx(Basis(expected))) and ok

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
	root.free()
	return err

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
