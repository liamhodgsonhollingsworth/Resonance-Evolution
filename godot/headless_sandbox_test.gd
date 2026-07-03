extends SceneTree
## Headless verification of the creative sandbox core (no display needed):
##
##   godot --headless --path godot -s res://headless_sandbox_test.gd
##
## Exercises the DATA layer that must be correct regardless of the UI: the block palette (13 shapes,
## all present in the renderer vocabulary), grid math (world<->cell round-trips), the place/remove/replace
## write path into the world Dictionary + the scene, the material seam, and the params seed/hotload.

const SandboxScript := preload("res://examples/sandbox_creative.gd")
const GodotSceneRenderer := preload("res://renderers/godot_scene_renderer.gd")

func _initialize() -> void:
	var ok := true
	var s = SandboxScript.new()
	s._headless = true
	s._build_palette()
	s._default_hotbar()
	s._build_world_nodes()
	get_root().add_child(s)

	# 1) Palette: 14 generic blocks (each shape builds a real mesh) + the held TOOLS (Sticky Note; act on
	#    click, no placement mesh). Count = 14 blocks + the tool palette entries.
	var block_count := 0
	var tool_count := 0
	for entry in s.palette:
		if String(entry.get("kind", "block")) == "tool":
			tool_count += 1
		else:
			block_count += 1
	ok = _check("palette has 14 blocks", block_count == 14) and ok
	ok = _check("palette includes the held tools (Sticky Note)", tool_count >= 1) and ok
	var all_meshes := true
	for entry in s.palette:
		if String(entry.get("kind", "block")) == "tool":
			continue                       # tools have no placement mesh (they act on click)
		var m: Mesh = GodotSceneRenderer._primitive_mesh(String(entry["shape"]), entry.get("params", {}))
		if m == null or m.get_surface_count() == 0:
			all_meshes = false
			print("  palette block '%s' (shape %s) built no mesh" % [entry["name"], entry["shape"]])
	ok = _check("every palette block builds a non-empty mesh", all_meshes) and ok

	# 2) Every block starts UNTEXTURED: material descriptor is a plain albedo, no texture.
	var all_untextured := true
	for entry in s.palette:
		var mat: Dictionary = entry["material"]
		if mat.has("albedo_texture") or not mat.has("albedo"):
			all_untextured = false
	ok = _check("every block starts untextured (albedo only, no texture)", all_untextured) and ok

	# 3) Hotbar: 9 MC slots, all valid palette indices.
	ok = _check("hotbar has 9 slots", s.hotbar.size() == 9) and ok
	var valid := true
	for i in s.hotbar:
		if i < 0 or i >= s.palette.size():
			valid = false
	ok = _check("all hotbar slots are valid palette indices", valid) and ok

	# 4) Grid math: world<->cell round-trips on cell centres.
	s.grid_size = 1.0
	var c := Vector3i(3, -2, 5)
	ok = _check("cell->world->cell round-trips", s._world_to_cell(s._cell_to_world(c)) == c) and ok

	# 5) Placement: place a Cube at a cell -> world has it + a MeshInstance3D was instanced.
	var cube := s._palette_index("Cube")
	ok = _check("Cube is in the palette", cube >= 0) and ok
	var cell := Vector3i(0, 0, 0)
	s._set_block(cell, cube)
	ok = _check("place: world records the cell", s.world.has(cell)) and ok
	var rec: Dictionary = s.world.get(cell, {})
	ok = _check("place: record has a live MeshInstance3D node", rec.get("node", null) is MeshInstance3D) and ok
	ok = _check("place: record carries the material SEAM", rec.has("material") and rec["material"].has("albedo")) and ok
	ok = _check("place: block instanced under Blocks root", s._blocks_root.get_child_count() == 1) and ok

	# 6) Replace: placing a different block at the same cell swaps it (one node, not two).
	var arch := s._palette_index("Arch")
	s._set_block(cell, arch)
	ok = _check("replace: still exactly one block at the cell", s._blocks_root.get_child_count() == 1) and ok
	ok = _check("replace: block type updated to Arch", String(s.world[cell]["type"]) == "Arch") and ok

	# 7) Removal: erase the cell -> world empty + node freed.
	s._erase_block(cell)
	ok = _check("remove: world no longer has the cell", not s.world.has(cell)) and ok
	ok = _check("remove: no blocks remain under Blocks root", s._blocks_root.get_child_count() == 0) and ok

	# 8) Params seed: the default params produce a non-trivial buildable world.
	var cfg: Dictionary = s._default_params()
	ok = _check("default params carry a blocks list", cfg.has("blocks") and (cfg["blocks"] as Array).size() > 20) and ok
	s._seed_world(cfg, true)
	ok = _check("seeding places the default build (40 blocks)", s.world.size() == 40) and ok

	# 9) Hotload re-seed: a smaller params set REPLACES the world (source of truth = the file).
	var small := { "blocks": [ {"cell": [0,0,0], "block": "Cube"}, {"cell": [1,0,0], "block": "Ball"} ] }
	s._seed_world(small, true)
	ok = _check("hotload re-seed replaces the world (2 blocks)", s.world.size() == 2) and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

func _check(label: String, cond: bool) -> bool:
	print(("  PASS " if cond else "  FAIL ") + label)
	return cond
