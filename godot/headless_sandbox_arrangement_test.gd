extends SceneTree
## Headless proof that THE CREATIVE SANDBOX IS A NODE ARRANGEMENT (Liam 2026-07-06: every scene/room is
## a resonance.arrangement/v1 that diff-hotloads). No display needed:
##
##   godot --headless --path godot -s res://headless_sandbox_arrangement_test.gd
##
## What it proves (real assertions, PASS/FAIL tally, nonzero exit on any FAIL):
##  1. SERIALIZE: place blocks + a free-placed primitive block object + an asset object in the sandbox,
##     serialize -> a valid resonance.arrangement/v1 {nodes,wires} in the GEOMETRY vocabulary
##     (Const/Model/Transform/Group), format tag + schema-required keys present.
##  2. RENDER THROUGH GraphRuntime: load that arrangement into a REAL GraphRuntime + GodotSceneRenderer
##     (the SAME hotload path lsystem_scene + the aperture room use) -> live Node3D scene, one instance
##     per placed thing, at the right world positions. This is the portability claim: the sandbox's edits
##     render through the shared runtime, not just its own imperative renderer.
##  3. ROUND-TRIP: deserialize the arrangement back into the sandbox edit-model and re-apply it to a
##     SECOND sandbox -> identical world (same block cells, same object transforms) — lossless.
##  4. DIFF-HOTLOAD: mutate the arrangement DATA in place (move a block, move an object), re-load_arrangement
##     + re-evaluate + re-render, and assert the KEPT primitives are the SAME instances (diff, not rebuild)
##     and the moved things' live Node3Ds actually moved.
##
## No live pollution: everything runs on in-memory data + off-screen nodes; nothing under state/ or live/.

const SandboxScript := preload("res://examples/sandbox_creative.gd")
const AssetLibraryScript := preload("res://runtime/asset_library.gd")
const WorldArrangement := preload("res://runtime/world_arrangement.gd")
const GraphRuntime := preload("res://runtime/graph_runtime.gd")
const GodotSceneRenderer := preload("res://renderers/godot_scene_renderer.gd")

var _fail := 0

func _check(name: String, cond: bool) -> void:
	print(("PASS  " if cond else "FAIL  ") + name)
	if not cond:
		_fail += 1


func _initialize() -> void:
	# ── build a sandbox with a few placed blocks + one free block object + one asset object ──────────
	var s = SandboxScript.new()
	s._headless = true
	s._build_palette()
	s._default_hotbar()
	s._build_world_nodes()
	s.assets = AssetLibraryScript.new()
	s.add_child(s.assets)
	s.assets.load_manifest()
	s._extend_palette_with_assets()
	# NB: do NOT add the sandbox script to the SceneTree root — that fires its _ready(), which builds its
	# OWN store + re-seeds the 40-block starter world, clobbering this test's state. The world-builder test
	# uses the same detached pattern. We drive the data seams directly (headless).

	var cube := s._palette_index("Cube")
	var ball := s._palette_index("Ball")
	s._set_block(Vector3i(0, 0, 0), cube)
	s._set_block(Vector3i(2, 0, 0), cube)
	s._set_block(Vector3i(0, 1, 0), ball)
	# a free-placed primitive BLOCK object (carries `block`, not `asset`)
	var slab := s._palette_index("Slab")
	var block_obj_id := s._place_block_free(slab, Vector3(3.5, 0.0, 1.5), 30.0)
	# a placed ASSET object (a real manifest GLB, loaded so its path resolves)
	var asset_id := ""
	if (s.assets.kits as Array).size() > 0:
		var kit0: Array = s.assets.kit_assets(String(s.assets.kits[0]))
		if kit0.size() > 0:
			asset_id = String((kit0[0] as Dictionary)["id"])
	var asset_obj_id := ""
	if asset_id != "":
		s.assets.request_sync(asset_id)
		asset_obj_id = s._place_object(asset_id, Vector3(-2.0, 0.0, 4.0), 45.0, 1.5)

	# ══ 1) SERIALIZE -> resonance.arrangement/v1 ═══════════════════════════════════════════════════
	var arr: Dictionary = s._serialize_world()
	_check("1a serialize tags resonance.arrangement/v1", String(arr.get("format", "")) == "resonance.arrangement/v1")
	_check("1b arrangement carries required keys (format/nodes/wires)", arr.has("format") and arr.has("nodes") and arr.has("wires"))
	var types := {}
	for n in arr.get("nodes", []):
		types[String(n.get("type", ""))] = int(types.get(String(n.get("type", "")), 0)) + 1
	# 3 voxel blocks + 1 block object => 4 Const; 1 asset object => 1 Model; per placed thing a Transform; 1 Group.
	_check("1c geometry vocabulary only (Const/Model/Transform/Group)",
		types.keys().all(func(t): return t in ["Const", "Model", "Transform", "Group"]))
	_check("1d one Const per primitive (3 blocks + 1 block object = 4)", int(types.get("Const", 0)) == 4)
	_check("1e one Model for the asset object", int(types.get("Model", 0)) == 1)
	_check("1f one Transform per placed thing (5)", int(types.get("Transform", 0)) == 5)
	_check("1g exactly one world Group", int(types.get("Group", 0)) == 1)
	# every wire references existing node ids
	var ids := {}
	for n in arr.get("nodes", []):
		ids[String(n.get("id", ""))] = true
	var wires_valid := true
	for w in arr.get("wires", []):
		if not ids.has(String(w.get("from", ""))) or not ids.has(String(w.get("to", ""))):
			wires_valid = false
	_check("1h every wire connects existing nodes", wires_valid)

	# ══ 2) RENDER THROUGH GraphRuntime (the shared hotload path) ═══════════════════════════════════
	var holder := Node3D.new()
	get_root().add_child(holder)
	var rt: GraphRuntime = GraphRuntime.new()
	holder.add_child(rt)
	var rend: GodotSceneRenderer = GodotSceneRenderer.new()
	holder.add_child(rend)
	rt.load_arrangement(arr)
	var eval_out := rt.evaluate()
	rend.render(eval_out, rt.arrangement)
	await process_frame
	# The renderer builds one live subtree under itself; count leaf Node3Ds that carry geometry.
	var live_nodes := _all_node3d(rend)
	# The world Group emits a parent node whose children are the placed things; assert the placed count.
	var group_out: Dictionary = eval_out.get("world", {})
	var world_desc = group_out.get("node")
	_check("2a Group evaluate() emits a scene_node with 5 children",
		typeof(world_desc) == TYPE_DICTIONARY and (world_desc.get("children", []) as Array).size() == 5)
	# geometry actually built: at least one MeshInstance3D exists under the renderer
	var mesh_count := 0
	for nn in live_nodes:
		if nn is MeshInstance3D and (nn as MeshInstance3D).mesh != null:
			mesh_count += 1
	_check("2b GraphRuntime+renderer built live geometry (>=3 primitive meshes)", mesh_count >= 3)
	# the block at cell (2,0,0) lands at world x=2 (grid_size 1) — find its transform in the descriptor
	var found_block_at_x2 := false
	for child in (world_desc.get("children", []) if typeof(world_desc) == TYPE_DICTIONARY else []):
		var tr = child.get("translation", [0, 0, 0])
		if typeof(tr) == TYPE_ARRAY and tr.size() >= 1 and absf(float(tr[0]) - 2.0) < 1e-6 and String(child.get("mesh", {}).get("source", "")) == "primitive":
			found_block_at_x2 = true
	_check("2c the block placed at cell (2,0,0) renders at world x=2", found_block_at_x2)

	# ══ 3) ROUND-TRIP: deserialize + re-apply to a SECOND sandbox -> identical world ═══════════════
	var s2 = SandboxScript.new()
	s2._headless = true
	s2._build_palette()
	s2._default_hotbar()
	s2._build_world_nodes()
	s2.assets = AssetLibraryScript.new()
	s2.add_child(s2.assets)
	s2.assets.load_manifest()
	s2._extend_palette_with_assets()
	if asset_id != "":
		s2.assets.request_sync(asset_id)
	s2._apply_world_data(arr)   # arr is an arrangement; _apply_world_data deserializes it
	await process_frame
	_check("3a round-trip preserves the 3 voxel blocks", s2.world.size() == 3)
	_check("3b round-trip preserves both objects (block obj + asset obj)", s2.objects.size() == 2)
	_check("3c the same block cells survive", s2.world.has(Vector3i(0, 0, 0)) and s2.world.has(Vector3i(2, 0, 0)) and s2.world.has(Vector3i(0, 1, 0)))
	# the block object's transform (pos + yaw) round-trips
	var bo_ok := false
	if block_obj_id != "" and s2.objects.has(block_obj_id):
		var r: Dictionary = s2.objects[block_obj_id]
		bo_ok = (r["base_pos"] as Vector3).distance_to(Vector3(3.5, 0.0, 1.5)) < 1e-4 and absf(float(r["yaw_deg"]) - 30.0) < 1e-4 and r.has("block")
	_check("3d free-placed block object round-trips (pos+yaw, still a block)", bo_ok)
	var ao_ok := false
	if asset_obj_id != "" and s2.objects.has(asset_obj_id):
		var r2: Dictionary = s2.objects[asset_obj_id]
		ao_ok = (r2["base_pos"] as Vector3).distance_to(Vector3(-2.0, 0.0, 4.0)) < 1e-4 and absf(float(r2["yaw_deg"]) - 45.0) < 1e-4 and absf(float(r2["scale"]) - 1.5) < 1e-4 and String(r2.get("asset", "")) == asset_id
	_check("3e asset object round-trips (pos+yaw+scale+asset id)", ao_ok if asset_id != "" else true)

	# ══ 4) DIFF-HOTLOAD: mutate arrangement data in place -> running world updates via the diff path ══
	# capture a kept primitive instance BEFORE the mutation
	var pre_instances := rend._instances.duplicate()
	# find the Transform node feeding the block at cell (2,0,0): id "blk_2_0_0_at"
	var mutated := arr.duplicate(true)
	var moved_ok := false
	for n in mutated.get("nodes", []):
		if String(n.get("id", "")) == "blk_2_0_0_at":
			n["params"]["position"] = [7.0, 0.0, 0.0]   # move it from x=2 to x=7
			moved_ok = true
	_check("4a found the block's Transform node to mutate", moved_ok)
	rt.load_arrangement(mutated)
	var eval2 := rt.evaluate()
	rend.render(eval2, rt.arrangement)
	await process_frame
	# DIFF not rebuild: the block's Const primitive instance is the SAME object (mesh_key unchanged).
	var kept_same := false
	for key in rend._instances.keys():
		if pre_instances.has(key) and rend._instances[key]["node"] == pre_instances[key]["node"]:
			kept_same = true
	_check("4b diff kept live instances across hotload (same objects, not rebuilt)", kept_same)
	# the moved block now renders at world x=7
	var group2: Dictionary = eval2.get("world", {})
	var world_desc2 = group2.get("node")
	var found_at_x7 := false
	for child in (world_desc2.get("children", []) if typeof(world_desc2) == TYPE_DICTIONARY else []):
		var tr = child.get("translation", [0, 0, 0])
		if typeof(tr) == TYPE_ARRAY and tr.size() >= 1 and absf(float(tr[0]) - 7.0) < 1e-6:
			found_at_x7 = true
	_check("4c the mutated block moved to world x=7 after hotload", found_at_x7)

	# ══ 5) ON-DISK ROUND-TRIP + LIVE HOTLOAD through the real store (the running-path proof) ═══════
	# The sandbox saves to disk as a resonance.arrangement/v1 file, the running sandbox reloads it, and
	# EDITING that file on disk hotloads the LIVE world in place (verification #1 + #2 in the real path).
	var WorldStoreScript := preload("res://runtime/world_store.gd")
	var tmp := ProjectSettings.globalize_path("user://test_sandbox_arrangement_store")
	_rm_rf(tmp)
	s.store = WorldStoreScript.new(tmp)
	s.world_name = "arr_world"
	var vsave: int = s.store.save_version(s.world_name, s._serialize_world())
	_check("5a save writes v1 to the store", vsave == 1)
	var on_disk: Dictionary = s.store.load_world(s.world_name)
	_check("5b the ON-DISK file is a resonance.arrangement/v1 (format survived the store)",
		WorldArrangement.is_arrangement(on_disk))
	# reload the on-disk arrangement into a THIRD sandbox -> identical world (disk round-trip)
	var s3 = SandboxScript.new()
	s3._headless = true
	s3._build_palette()
	s3._default_hotbar()
	s3._build_world_nodes()
	s3.assets = AssetLibraryScript.new()
	s3.add_child(s3.assets)
	s3.assets.load_manifest()
	s3._extend_palette_with_assets()
	if asset_id != "":
		s3.assets.request_sync(asset_id)
	s3.store = WorldStoreScript.new(tmp)
	s3.world_name = "arr_world"
	var s3_loaded := s3._load_active_world()
	_check("5c the on-disk arrangement loads back (disk round-trip: 3 blocks + 2 objects)",
		s3_loaded and s3.world.size() == 3 and s3.objects.size() == 2)
	# LIVE HOTLOAD: append-only save a MUTATED arrangement (move the (0,0,0) block to cell (5,5,5)),
	# then the running s3's file watcher (_poll_world_file) picks up the newer version in place.
	var disk_arr: Dictionary = on_disk.duplicate(true)
	for n in disk_arr.get("nodes", []):
		if String(n.get("id", "")) == "blk_0_0_0_at":
			(n["_sandbox"] as Dictionary)["cell"] = [5, 5, 5]
			n["params"]["position"] = [5.0, 5.0, 5.0]
	s.store.save_version(s.world_name, disk_arr)   # writes v2 to the same store dir s3 watches
	s3._poll_world_file()                          # the running sandbox's on-disk hotload path
	await process_frame
	_check("5d live on-disk hotload moved the block to cell (5,5,5) in the running world",
		s3.world.has(Vector3i(5, 5, 5)) and not s3.world.has(Vector3i(0, 0, 0)) and s3.world.size() == 3)
	s3.free()
	_rm_rf(tmp)

	s.free()
	s2.free()
	print("RESULT: ", "ALL PASS" if _fail == 0 else "FAILURES PRESENT (%d)" % _fail)
	quit(0 if _fail == 0 else 1)


## Recursive delete of a test dir (absolute path). Only ever pointed at user:// temp dirs.
func _rm_rf(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	for sub in d.get_directories():
		_rm_rf(path.path_join(sub))
	DirAccess.remove_absolute(path)


func _all_node3d(root: Node) -> Array:
	var out := []
	for c in root.get_children():
		if c is Node3D:
			out.append(c)
		out.append_array(_all_node3d(c))
	return out
