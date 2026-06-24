extends SceneTree
## Proves the EVOLVER's genome vocabulary (primitive-shape scene_nodes) is cross-renderer
## portable in the engine: a scene_node group of placed primitive objects (box/sphere/cylinder)
## renders via the Godot delegate, exports to glTF, and re-imports structurally identical. This
## is the ENGINE side of the evolver connection — domain_node.js (window.Evolve, in the
## Resonance-Website repo) evolves exactly this shape, and these GLBs validate + load in three.js
## the same as any other (run godot/oracle/validate_glb.mjs + three_parity.mjs on the output).
##   godot --headless --path godot -s res://headless_primitive_test.gd

func _initialize() -> void:
	var ok := true
	# A scene_node exactly like domain_node.js emits: a group of placed primitive objects.
	var scene := {
		"name": "scene", "translation": [0, 0, 0], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1], "mesh": null,
		"children": [
			{ "name": "b", "translation": [-1.5, 0, 0], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1], "mesh": { "source": "primitive", "shape": "box" }, "children": [] },
			{ "name": "s", "translation": [1.5, 0, 0], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1], "mesh": { "source": "primitive", "shape": "sphere" }, "children": [] },
			{ "name": "c", "translation": [0, 0, 2.0], "rotation": [0, 0, 0, 1], "scale": [1, 1, 1], "mesh": { "source": "primitive", "shape": "cylinder" }, "children": [] }
		]
	}

	var renderer := GodotSceneRenderer.new()
	get_root().add_child(renderer)
	renderer.render({ "scene": { "node": scene } }, { "wires": [] })
	ok = _check("delegate built one group root", renderer.get_child_count() == 1) and ok
	ok = _check("3 primitive meshes built (box/sphere/cylinder)", _mesh_count(renderer) == 3) and ok

	var bytes := GltfExporter.export_buffer([scene])
	ok = _check("primitive scene exported to a non-empty GLB", bytes.size() > 0) and ok

	var imp = null
	if bytes.size() > 0:
		var doc := GLTFDocument.new()
		var st := GLTFState.new()
		if doc.append_from_buffer(bytes, "", st) == OK:
			imp = doc.generate_scene(st)
	ok = _check("primitive GLB re-imports + generates", imp != null) and ok
	ok = _check("round-trip keeps 3 meshes", imp != null and _mesh_count(imp) == 3) and ok

	DirAccess.make_dir_recursive_absolute("res://live")
	ok = _check("wrote res://live/primitive.glb (for validator + three.js parity)",
		GltfExporter.export_to_file([scene], "res://live/primitive.glb") == OK) and ok

	if imp != null:
		imp.free()
	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

func _mesh_count(node: Node) -> int:
	var c := 0
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		c += 1
	for ch in node.get_children():
		c += _mesh_count(ch)
	return c

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
