extends SceneTree
## Multi-object + hierarchical composition, end-to-end substrate-independence.
##
##   godot --headless --path godot -s res://headless_compose_test.gd
##
## Two Models placed at different positions are grouped (Group) into ONE scene_node whose
## children are the two placed objects. Asserts: the grouped descriptor is pure data with 2
## children at the right positions; the delegate builds both meshes at the right WORLD
## positions; and the whole multi-object scene exports to glTF and re-imports with both
## objects still at A and B. Also checks a FLAT multi-object scene (two terminal nodes, no
## group) renders both roots — so multi-object works with or without grouping.

const A := [-1.5, 0.0, 0.0]
const B := [1.5, 0.0, 0.0]

func _initialize() -> void:
	var ok := true
	var glb := "user://compose_box.glb"
	ok = _check("box GLB fixture exported", _make_box_glb(glb) == OK) and ok

	var arrangement := {
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "m1", "type": "Model", "params": { "path": glb, "name": "obj_a" } },
			{ "id": "m2", "type": "Model", "params": { "path": glb, "name": "obj_b" } },
			{ "id": "t1", "type": "Transform", "params": { "position": A } },
			{ "id": "t2", "type": "Transform", "params": { "position": B } },
			{ "id": "g", "type": "Group", "params": { "count": 2, "name": "pair" } }
		],
		"wires": [
			{ "from": "m1", "out": "node", "to": "t1", "in": "node" },
			{ "from": "m2", "out": "node", "to": "t2", "in": "node" },
			{ "from": "t1", "out": "node", "to": "g", "in": "in_0" },
			{ "from": "t2", "out": "node", "to": "g", "in": "in_1" }
		]
	}
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	rt.load_arrangement(arrangement)
	var outputs := rt.evaluate()
	var grp = outputs.get("g", {}).get("node")

	ok = _check("Group emits a scene_node (Dictionary)", typeof(grp) == TYPE_DICTIONARY) and ok
	var kids = grp.get("children") if typeof(grp) == TYPE_DICTIONARY else null
	ok = _check("group has 2 children", kids is Array and (kids as Array).size() == 2) and ok
	ok = _check("grouped scene is pure JSON data",
		typeof(grp) == TYPE_DICTIONARY and typeof(JSON.parse_string(JSON.stringify(grp))) == TYPE_DICTIONARY) and ok
	ok = _check("child A placed at -1.5 x", kids is Array and _approx(kids[0]["translation"], A)) and ok
	ok = _check("child B placed at +1.5 x", kids is Array and _approx(kids[1]["translation"], B)) and ok

	# Delegate builds the whole group: one root (the group), two mesh subtrees at A and B.
	var renderer := GodotSceneRenderer.new()
	get_root().add_child(renderer)
	renderer.render(outputs, arrangement)
	ok = _check("delegate built one group root", renderer.get_child_count() == 1) and ok
	var meshes := _collect_mesh_globals(renderer, Transform3D.IDENTITY)
	ok = _check("group renders 2 meshes", meshes.size() == 2) and ok
	ok = _check("the 2 meshes are at A and B",
		_has_origin(meshes, Vector3(A[0], A[1], A[2])) and _has_origin(meshes, Vector3(B[0], B[1], B[2]))) and ok

	# Multi-object export -> reimport round-trip keeps both objects at A and B.
	var bytes := GltfExporter.export_buffer([grp])
	ok = _check("grouped scene exported to GLB", bytes.size() > 0) and ok
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	var ierr := doc.append_from_buffer(bytes, "", st) if bytes.size() > 0 else FAILED
	var imp = doc.generate_scene(st) if ierr == OK else null
	ok = _check("grouped GLB re-imports", imp != null) and ok
	var imp_meshes := _collect_mesh_globals(imp, Transform3D.IDENTITY) if imp != null else []
	ok = _check("round-trip keeps both objects at A and B",
		imp_meshes.size() == 2 and _has_origin(imp_meshes, Vector3(A[0], A[1], A[2])) and _has_origin(imp_meshes, Vector3(B[0], B[1], B[2]))) and ok

	# FLAT multi-object: two terminal Transforms (no group) render two independent roots.
	var flat := {
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "m1", "type": "Model", "params": { "path": glb, "name": "a" } },
			{ "id": "m2", "type": "Model", "params": { "path": glb, "name": "b" } },
			{ "id": "t1", "type": "Transform", "params": { "position": A } },
			{ "id": "t2", "type": "Transform", "params": { "position": B } }
		],
		"wires": [
			{ "from": "m1", "out": "node", "to": "t1", "in": "node" },
			{ "from": "m2", "out": "node", "to": "t2", "in": "node" }
		]
	}
	var r2 := GodotSceneRenderer.new()
	get_root().add_child(r2)
	rt.load_arrangement(flat)
	r2.render(rt.evaluate(), flat)
	ok = _check("flat scene renders 2 independent roots", r2.get_child_count() == 2) and ok

	if imp != null:
		imp.free()
	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

# --- helpers --------------------------------------------------------------

func _collect_mesh_globals(node: Node, parent_global: Transform3D) -> Array:
	var out := []
	var g := parent_global
	if node is Node3D:
		g = parent_global * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out.append(g)
	for c in node.get_children():
		out.append_array(_collect_mesh_globals(c, g))
	return out

func _has_origin(globals: Array, v: Vector3) -> bool:
	for t in globals:
		if (t as Transform3D).origin.is_equal_approx(v):
			return true
	return false

func _approx(a, b) -> bool:
	if not (a is Array) or (a as Array).size() < 3:
		return false
	return abs(float(a[0]) - float(b[0])) < 1e-4 and abs(float(a[1]) - float(b[1])) < 1e-4 and abs(float(a[2]) - float(b[2])) < 1e-4

func _make_box_glb(path: String) -> int:
	var root := Node3D.new()
	root.name = "BoxRoot"
	var mi := MeshInstance3D.new()
	mi.name = "Box"
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
