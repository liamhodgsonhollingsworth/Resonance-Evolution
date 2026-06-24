extends SceneTree
## Substrate-independence / multi-renderer proof for 3D arrangements.
##
##   godot --headless --path godot -s res://headless_portable_test.gd
##
## Proves the design law for the 3D path:
##   (a) a 3D arrangement evaluates to renderer-NEUTRAL DATA — no live Godot object on any
##       wire, and the value round-trips through JSON;
##   (b) the Godot delegate builds the right live scene from that data (and a hotload
##       RE-WIRES the same instance rather than rebuilding it);
##   (c) the SAME data exported to glTF (GLB) and re-imported is STRUCTURALLY IDENTICAL —
##       it ported through the universal 3D interchange unchanged, so any other glTF
##       renderer can consume it.
##
## It also writes res://live/portable.glb so the external Khronos glTF-validator gate
## (node godot/oracle/validate_glb.mjs) can confirm the export is spec-conformant — i.e.
## "a different renderer" agrees the data is valid. See PROGRESS.md for the chained command.

const POS := [1.0, 2.0, 3.0]
const EXPORT_PATH := "res://live/portable.glb"

func _initialize() -> void:
	var ok := true
	var glb := "user://portable_box.glb"
	ok = _check("box GLB fixture exported", _make_box_glb(glb) == OK) and ok

	var arrangement := {
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "box", "type": "Model", "params": { "path": glb, "name": "box_model" } },
			{ "id": "place", "type": "Transform", "params": { "position": POS, "rotation": [0, 90, 0] } }
		],
		"wires": [ { "from": "box", "out": "node", "to": "place", "in": "node" } ]
	}

	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	rt.load_arrangement(arrangement)
	var outputs := rt.evaluate()
	var desc = outputs.get("place", {}).get("node")

	# (a) Substrate independence: the wire value is pure, JSON-serializable DATA.
	ok = _check("Transform output is a Dictionary (not a Node3D)", typeof(desc) == TYPE_DICTIONARY) and ok
	ok = _check("descriptor carries no live Godot object", typeof(desc) == TYPE_DICTIONARY and not _has_object(desc)) and ok
	ok = _check("descriptor is JSON round-trippable", typeof(desc) == TYPE_DICTIONARY and _json_roundtrips(desc)) and ok
	ok = _check("descriptor placed at (1,2,3)", typeof(desc) == TYPE_DICTIONARY and _approx_arr(desc.get("translation"), POS)) and ok
	ok = _check("descriptor rotation is a quaternion [x,y,z,w]",
		typeof(desc) == TYPE_DICTIONARY and (desc.get("rotation") is Array) and (desc.get("rotation") as Array).size() == 4) and ok
	ok = _check("descriptor mesh references the GLB by path", typeof(desc) == TYPE_DICTIONARY and _mesh_path(desc) == glb) and ok

	# (b) The Godot delegate builds the right live scene from that data.
	var renderer := GodotSceneRenderer.new()
	get_root().add_child(renderer)
	renderer.render(outputs, arrangement)
	ok = _check("delegate built one root node", renderer.get_child_count() == 1) and ok
	var root_node: Node3D = renderer.get_child(0) if renderer.get_child_count() > 0 else null
	ok = _check("built node at (1,2,3) within epsilon",
		root_node != null and root_node.transform.origin.is_equal_approx(Vector3(POS[0], POS[1], POS[2]))) and ok
	ok = _check("built node has a mesh under it", root_node != null and _has_mesh(root_node)) and ok

	# (b') Hotload re-wires (keeps the instance); it does not rebuild.
	arrangement["nodes"][1]["params"]["position"] = [5.0, 0.0, 0.0]
	rt.load_arrangement(arrangement)
	var outputs2 := rt.evaluate()
	renderer.render(outputs2, arrangement)
	var root_node2: Node3D = renderer.get_child(0) if renderer.get_child_count() > 0 else null
	ok = _check("hotload kept the SAME node instance (re-wired, not rebuilt)", root_node != null and root_node == root_node2) and ok
	ok = _check("hotload moved the node to (5,0,0)", root_node2 != null and root_node2.transform.origin.is_equal_approx(Vector3(5, 0, 0))) and ok

	# (c) Portability oracle: export to glTF (GLB) and re-import — structurally identical.
	# Use the descriptor as it was at export time (POS), rebuilt from a fresh evaluate so the
	# reference tree and the export agree on placement.
	arrangement["nodes"][1]["params"]["position"] = POS
	rt.load_arrangement(arrangement)
	var roots := [rt.evaluate().get("place", {}).get("node")]

	var bytes := GltfExporter.export_buffer(roots)
	ok = _check("arrangement exported to a non-empty GLB", bytes.size() > 0) and ok

	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	var imp_err := doc.append_from_buffer(bytes, "", st) if bytes.size() > 0 else FAILED
	ok = _check("exported GLB re-imports OK", imp_err == OK) and ok
	var imp = doc.generate_scene(st) if imp_err == OK else null
	ok = _check("re-imported scene generated", imp != null) and ok

	# Reference tree (OFF-tree) built from the SAME data; compare to the re-imported tree by
	# composing GLOBAL transforms manually — this avoids the SceneTree sibling-name-collision
	# artifact that would otherwise rename a co-parented re-imported root and cause a false fail.
	var ref := Node3D.new()
	GodotSceneRenderer.build_static_tree(roots, ref)
	var ref_meshes := _collect_meshes(ref, Transform3D.IDENTITY)
	var imp_meshes := _collect_meshes(imp, Transform3D.IDENTITY) if imp != null else []

	ok = _check("round-trip preserves mesh count (>=2 distinct meshes)",
		ref_meshes.size() == imp_meshes.size() and ref_meshes.size() >= 2) and ok
	ok = _check("round-trip preserves total vertex count",
		_sum_verts(ref_meshes) == _sum_verts(imp_meshes) and _sum_verts(ref_meshes) > 0) and ok
	ok = _check("fixture exercises a non-identity rotation (so the basis check is meaningful)",
		_any_nonidentity_basis(ref_meshes)) and ok
	ok = _check("round-trip preserves per-mesh transform (rotation+scale+translation), verts & surfaces",
		_meshes_match(ref_meshes, imp_meshes)) and ok

	# Emit the GLB to disk for the external Khronos glTF-validator conformance gate.
	DirAccess.make_dir_recursive_absolute("res://live")
	var wrote := GltfExporter.export_to_file(roots, EXPORT_PATH)
	ok = _check("wrote %s for the validator gate" % EXPORT_PATH, wrote == OK and FileAccess.file_exists(EXPORT_PATH)) and ok

	# Sidecar counts from the RE-IMPORTED tree (which reads the exported accessors, exactly as
	# three.js will), so an INDEPENDENT engine (three.js GLTFLoader) can assert geometry parity
	# on the same GLB — proving the data renders the same across renderers, not just that it's valid.
	var counts := { "meshes": imp_meshes.size(), "vertices": _sum_verts(imp_meshes) }
	var cf := FileAccess.open("res://live/portable.counts.json", FileAccess.WRITE)
	if cf != null:
		cf.store_string(JSON.stringify(counts))
		cf.close()
	ok = _check("wrote portable.counts.json (three.js parity sidecar)", FileAccess.file_exists("res://live/portable.counts.json")) and ok

	ref.free()
	if imp != null:
		imp.free()

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

# --- helpers --------------------------------------------------------------

# Global transform composed manually (parent_global * local) so neither tree needs to be in
# the SceneTree — sidesteps the name-collision rename trap entirely.
func _collect_meshes(node: Node, parent_global: Transform3D) -> Array:
	var out := []
	var g := parent_global
	if node is Node3D:
		g = parent_global * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var m: Mesh = (node as MeshInstance3D).mesh
		var verts := 0
		for s in m.get_surface_count():
			var arr := m.surface_get_arrays(s)
			if arr.size() > Mesh.ARRAY_VERTEX and arr[Mesh.ARRAY_VERTEX] != null:
				verts += (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		out.append({ "g": g, "verts": verts, "surfaces": m.get_surface_count() })
	for c in node.get_children():
		out.append_array(_collect_meshes(c, g))
	return out

func _sum_verts(meshes: Array) -> int:
	var total := 0
	for m in meshes:
		total += int(m["verts"])
	return total

# Bijective per-mesh match: each reference mesh must pair with a DISTINCT re-imported mesh that
# agrees on vertex count, surface count, AND full world transform (rotation + scale + translation)
# within epsilon — so a dropped mesh, swapped geometry, or lost orientation fails the check.
func _meshes_match(a: Array, b: Array) -> bool:
	if a.size() != b.size() or a.is_empty():
		return false
	var used := {}
	for i in a.size():
		var matched := -1
		for j in b.size():
			if used.has(j):
				continue
			var ga := a[i]["g"] as Transform3D
			var gb := b[j]["g"] as Transform3D
			if int(a[i]["verts"]) == int(b[j]["verts"]) and int(a[i]["surfaces"]) == int(b[j]["surfaces"]) \
				and ga.origin.is_equal_approx(gb.origin) and ga.basis.is_equal_approx(gb.basis):
				matched = j
				break
		if matched < 0:
			return false
		used[matched] = true
	return true

func _any_nonidentity_basis(meshes: Array) -> bool:
	for m in meshes:
		if not (m["g"] as Transform3D).basis.is_equal_approx(Basis.IDENTITY):
			return true
	return false

func _has_object(v) -> bool:
	match typeof(v):
		TYPE_OBJECT:
			return true
		TYPE_DICTIONARY:
			for k in v:
				if _has_object(k) or _has_object(v[k]):
					return true
		TYPE_ARRAY:
			for e in v:
				if _has_object(e):
					return true
	return false

func _json_roundtrips(d: Dictionary) -> bool:
	var s := JSON.stringify(d)
	var back = JSON.parse_string(s)
	return typeof(back) == TYPE_DICTIONARY and JSON.stringify(back) == s

func _approx_arr(a, b) -> bool:
	if not (a is Array) or (a as Array).size() < 3:
		return false
	return abs(float(a[0]) - float(b[0])) < 1e-4 and abs(float(a[1]) - float(b[1])) < 1e-4 and abs(float(a[2]) - float(b[2])) < 1e-4

func _mesh_path(desc: Dictionary) -> String:
	var mesh = desc.get("mesh")
	if typeof(mesh) == TYPE_DICTIONARY:
		return String(mesh.get("path", ""))
	return ""

func _has_mesh(n: Node) -> bool:
	if n is MeshInstance3D:
		return true
	for c in n.get_children():
		if _has_mesh(c):
			return true
	return false

# Fixture: TWO distinct meshes (a box + an offset sphere, different vertex counts) so the
# round-trip oracle can catch a dropped/swapped mesh or a lost orientation — not just a
# single-mesh happy path.
func _make_box_glb(path: String) -> int:
	var root := Node3D.new()
	root.name = "BoxRoot"
	var box := MeshInstance3D.new()
	box.name = "Box"
	box.mesh = BoxMesh.new()
	root.add_child(box)
	box.owner = root
	var orb := MeshInstance3D.new()
	orb.name = "Orb"
	orb.mesh = SphereMesh.new()
	orb.position = Vector3(2, 0, 0)
	root.add_child(orb)
	orb.owner = root
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
