extends SceneTree
## GZ-3D.3 — the basic-parts 3D shape library + catalog. Proves the expanded primitive vocabulary
## is real, renderable, portable, and DISCOVERABLE from the renderer-neutral catalog:
##   1. catalog.json parses and every part it lists is BUILDABLE (a non-empty mesh) and its shape
##      is one the renderer knows.
##   2. every catalog shape builds a non-empty mesh via GodotSceneRenderer (with its catalog defaults).
##   3. every catalog shape exports to a spec-valid GLB (GltfExporter round-trips it: re-import + mesh).
##   4. PartsCatalog.part_node emits a valid scene_node (one call / one node) that the delegate builds.
##   5. a MULTI-PART GLB is written (all parts in a row) for the external Khronos validator + three.js.
##   6. params flow through as DATA (a tuned dimension changes the produced geometry).
##
##   godot --headless --path godot -s res://headless_parts_test.gd

func _initialize() -> void:
	var ok := true

	# --- 1. the catalog parses + is internally consistent -------------------------------------
	var catalog := PartsCatalog.load_catalog()
	ok = _check("catalog.json parses to a non-empty dict", not catalog.is_empty()) and ok
	var names := PartsCatalog.shapes(catalog)
	ok = _check("catalog lists at least 8 parts", names.size() >= 8) and ok
	print("  catalog parts (%d): %s" % [names.size(), ", ".join(names)])

	# --- 2 + 3. every catalog part builds a non-empty mesh AND round-trips through glTF ---------
	var all_roots := []   # for the multi-part GLB (§5)
	var x := 0.0
	for name in names:
		var shape := PartsCatalog.shape_for(name, catalog)
		var params := PartsCatalog.defaults_for(name, catalog)

		var mesh := GodotSceneRenderer._primitive_mesh(shape, params)
		var vcount := _vertex_count(mesh)
		ok = _check("part '%s' (shape=%s) builds a non-empty mesh (%d verts)" % [name, shape, vcount], mesh != null and vcount > 0) and ok

		# The delegate builds a live node carrying exactly one MeshInstance3D with this mesh.
		var node := PartsCatalog.part_node(name, {}, [x, 0.0, 0.0], catalog)
		ok = _check("part '%s' -> a valid scene_node (part_node one-call helper)" % name, GodotSceneRenderer.is_scene_node(node)) and ok
		var built := GodotSceneRenderer.build_node(node)
		ok = _check("part '%s' delegate-builds exactly one mesh instance" % name, _mesh_count(built) == 1) and ok
		built.free()

		# Single-part glTF round-trip: export -> re-import -> still has a mesh.
		var bytes := GltfExporter.export_buffer([node])
		ok = _check("part '%s' exports to a non-empty GLB" % name, bytes.size() > 0) and ok
		var imp := _reimport(bytes)
		ok = _check("part '%s' GLB re-imports with a mesh" % name, imp != null and _mesh_count(imp) >= 1) and ok
		if imp != null:
			imp.free()

		all_roots.append(node)
		x += 2.5

	# --- 4. an unknown part name degrades cleanly (empty dict, no crash) -----------------------
	ok = _check("unknown part name -> {} (graceful)", PartsCatalog.part_node("not_a_real_shape").is_empty()) and ok

	# --- 5. the MULTI-PART GLB for the external validator + three.js parity --------------------
	DirAccess.make_dir_recursive_absolute("res://live")
	var expected_meshes := all_roots.size()
	ok = _check("wrote res://live/parts.glb (all %d parts, for validator + three.js)" % expected_meshes,
		GltfExporter.export_to_file(all_roots, "res://live/parts.glb") == OK) and ok
	# Sidecar counts so three_parity.mjs can assert mesh parity against Godot.
	var total_verts := 0
	for r in all_roots:
		total_verts += _vertex_count(GodotSceneRenderer._primitive_mesh(String(r["mesh"]["shape"]), r["mesh"]["params"]))
	var counts := { "meshes": expected_meshes, "vertices": total_verts }
	var f := FileAccess.open("res://live/parts.counts.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(counts))
		f.close()
	ok = _check("wrote res://live/parts.counts.json (meshes=%d vertices=%d)" % [expected_meshes, total_verts], FileAccess.file_exists("res://live/parts.counts.json")) and ok

	# --- 6. params flow through as DATA (tuning a dimension changes the geometry) ---------------
	var small := GodotSceneRenderer._primitive_mesh("box", {"width": 0.5, "height": 0.5, "depth": 0.5})
	var big := GodotSceneRenderer._primitive_mesh("box", {"width": 4.0, "height": 4.0, "depth": 4.0})
	ok = _check("box params tune the geometry (bigger AABB)", _aabb_size(big) > _aabb_size(small)) and ok
	# The stairs step-count param actually changes vertex count (composite parts respond to params).
	var s4 := GodotSceneRenderer._primitive_mesh("stairs", {"steps": 4})
	var s8 := GodotSceneRenderer._primitive_mesh("stairs", {"steps": 8})
	ok = _check("stairs 'steps' param changes vertex count (8>4)", _vertex_count(s8) > _vertex_count(s4)) and ok

	# --- no-regression guard: the original box/sphere/cylinder still build ---------------------
	for base in ["box", "sphere", "cylinder"]:
		ok = _check("legacy shape '%s' still builds (no regression)" % base, _vertex_count(GodotSceneRenderer._primitive_mesh(base)) > 0) and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

# --- helpers -----------------------------------------------------------------------------------

func _reimport(bytes: PackedByteArray) -> Node:
	if bytes.size() == 0:
		return null
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_buffer(bytes, "", st) == OK:
		return doc.generate_scene(st)
	return null

func _vertex_count(mesh: Mesh) -> int:
	if mesh == null:
		return 0
	var n := 0
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		if arrays.size() > Mesh.ARRAY_VERTEX and arrays[Mesh.ARRAY_VERTEX] != null:
			n += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	return n

func _aabb_size(mesh: Mesh) -> float:
	if mesh == null:
		return 0.0
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var a := mi.get_aabb()
	mi.free()
	return a.size.length()

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
