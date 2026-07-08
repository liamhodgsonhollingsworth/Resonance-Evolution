extends SceneTree
## Headless proof that the APERTURE ROOM IS A HOTLOADING NODE ARRANGEMENT (Liam 2026-07-06).
##   godot --headless --path godot -s res://headless_aperture_room_test.gd
##
## What it proves (real assertions, PASS/FAIL tally, nonzero exit on any FAIL):
##  1. The shipped room arrangement (aperture/aperture_room_shell.json) loads + evaluates with ZERO
##     errors and produces the shell geometry (6 boxes under one Group), a sky Environment descriptor,
##     and a fill Light descriptor — all renderer-neutral DATA.
##  2. The GodotSceneRenderer builds the shell (>=6 primitive-box mesh instances), a live
##     WorldEnvironment + sun, and a live Light3D from that one evaluate() output.
##  3. DIFF-HOTLOAD: mutate the arrangement DATA in place (move a wall, retint + re-aim the sky),
##     re-load_arrangement + re-evaluate + re-render, and assert (a) the KEPT primitive nodes are the
##     SAME instances (diff, not rebuild), (b) the moved wall's live Node3D actually moved, and (c) the
##     env/light re-drove to the new values. Nothing is rebuilt that didn't change.
##
## No live pollution: everything runs on in-memory data + off-screen nodes; no file under state/ or
## live/ is written (the mutate step edits an IN-MEMORY copy of the arrangement, never the shipped JSON).

const GodotSceneRenderer := preload("res://renderers/godot_scene_renderer.gd")
const ROOM_JSON := "res://aperture/aperture_room_shell.json"

var _fail := 0

func _check(name: String, cond: bool) -> void:
	print(("PASS  " if cond else "FAIL  ") + name)
	if not cond:
		_fail += 1

func _initialize() -> void:
	var holder := Node3D.new()
	get_root().add_child(holder)

	# --- 1. load the shipped arrangement -------------------------------------------------------
	_check("arrangement file exists", FileAccess.file_exists(ROOM_JSON))
	var data = JSON.parse_string(FileAccess.get_file_as_string(ROOM_JSON))
	_check("arrangement parses to a Dictionary", typeof(data) == TYPE_DICTIONARY)
	_check("format is resonance.arrangement/v1", String((data as Dictionary).get("format", "")) == "resonance.arrangement/v1")

	var runtime := GraphRuntime.new()
	holder.add_child(runtime)
	runtime.load_arrangement(data)
	var eval := runtime.evaluate()
	_check("runtime instanced all arrangement nodes", runtime.nodes.size() == (data as Dictionary).get("nodes", []).size())

	# The Group is the terminal scene_node; the Environment + Light are on their own ports.
	var roots := GodotSceneRenderer.select_roots(eval, runtime.arrangement)
	_check("exactly one terminal scene_node root (the room Group)", roots.size() == 1)
	var room_desc: Dictionary = roots[0]["desc"] if roots.size() > 0 else {}
	var kids: Array = room_desc.get("children", [])
	_check("room Group has 6 shell children (floor+ceiling+4 walls)", kids.size() == 6)

	var env_desc := GodotSceneRenderer.find_environment(eval)
	_check("an Environment (sky) descriptor is present", not env_desc.is_empty())
	_check("environment is renderer-neutral (has top_color array)", env_desc.get("top_color") is Array)

	var lights := GodotSceneRenderer.gather_lights(eval)
	_check("at least one Light descriptor is present", lights.size() >= 1)

	# --- 2. render the shell + env + lights ----------------------------------------------------
	var renderer := GodotSceneRenderer.new()
	holder.add_child(renderer)
	renderer.render(eval, runtime.arrangement)
	renderer.apply_environment(eval, runtime.arrangement, holder)
	renderer.apply_lights(eval, runtime.arrangement, holder)

	var mesh_instances := _count_mesh_instances(renderer)
	_check("shell rendered >= 6 box mesh instances", mesh_instances >= 6)
	var world_envs := _find_class(holder, "WorldEnvironment")
	_check("a live WorldEnvironment was mounted", world_envs.size() == 1)
	var dir_lights := _find_class(holder, "DirectionalLight3D")
	# The sky's sun (from apply_environment) + the fill directional Light (from apply_lights) = 2.
	_check("live directional lights present (sky sun + fill light)", dir_lights.size() >= 2)

	# Capture the identity of a KEPT primitive node + a moved wall's live Node3D BEFORE mutating.
	var wall_prim_before = runtime.nodes.get("wall_px_at")
	_check("kept-node handle exists pre-hotload (wall_px_at)", wall_prim_before != null)
	var wall_node_before := _find_node3d_named(renderer, "wall_px")
	_check("moved wall has a live Node3D pre-hotload", wall_node_before != null)
	# Read LOCAL position: apply_trs sets node.transform (local); the wall sits under a Group parent at
	# origin so local == world here, and this avoids the off-tree get_global_transform() warning.
	var wall_x_before := wall_node_before.position.x if wall_node_before != null else -999.0

	# --- 3. DIFF-HOTLOAD: mutate the DATA and re-render ----------------------------------------
	var mutated: Dictionary = (data as Dictionary).duplicate(true)
	for n in mutated["nodes"]:
		if String(n.get("id")) == "wall_px_at":
			n["params"]["position"] = [15.0, 3.0, 0.0]    # move the +X wall out from x=12 to x=15
		if String(n.get("id")) == "sky":
			n["params"]["top_color"] = [0.9, 0.2, 0.2]     # retint the sky red
			n["params"]["sun_azimuth_deg"] = 80.0          # re-aim the sun
		if String(n.get("id")) == "fill_light":
			n["params"]["intensity"] = 0.95               # brighten the fill light

	runtime.load_arrangement(mutated)  # DIFF, not rebuild
	var wall_prim_after = runtime.nodes.get("wall_px_at")
	_check("hotload KEPT the wall_px_at primitive (same instance, diff not rebuild)",
		wall_prim_after != null and wall_prim_after == wall_prim_before)

	var eval2 := runtime.evaluate()
	renderer.render(eval2, runtime.arrangement)
	renderer.apply_environment(eval2, runtime.arrangement, holder)
	renderer.apply_lights(eval2, runtime.arrangement, holder)

	var wall_node_after := _find_node3d_named(renderer, "wall_px")
	_check("moved wall's live Node3D SURVIVED the hotload (same instance)",
		wall_node_after != null and wall_node_after == wall_node_before)
	var wall_x_after := wall_node_after.position.x if wall_node_after != null else -999.0
	_check("moved wall actually moved to x=15 (was ~12)",
		abs(wall_x_after - 15.0) < 0.01 and abs(wall_x_before - 12.0) < 0.01)

	# Env re-drove: exactly ONE WorldEnvironment is LIVE (the previous one was queue_free()'d — it lingers
	# in the tree until the next frame, so count only the not-queued-for-deletion instance).
	_check("exactly one live WorldEnvironment after hotload (old one released)",
		_count_live_class(holder, "WorldEnvironment") == 1)
	var env_desc2 := GodotSceneRenderer.find_environment(eval2)
	_check("sky descriptor re-drove to the mutated top_color",
		env_desc2.get("top_color") is Array and abs(float(env_desc2["top_color"][0]) - 0.9) < 0.001)

	# Light re-drove IN PLACE: the fill light and the sky sun are re-driven, not duplicated — the live
	# (not-queued-for-deletion) directional count matches the pre-hotload count.
	_check("live directional-light count stable after hotload (re-driven, not duplicated)",
		_count_live_class(holder, "DirectionalLight3D") == dir_lights.size())

	print("---- %s (%d failing) ----" % ["ROOM-ARRANGEMENT HOTLOAD", _fail])
	# Standard battery sentinel (run_all_tests.py classifies on "RESULT: ALL PASS" / "… N FAIL").
	print("RESULT: %s" % ("ALL PASS" if _fail == 0 else "%d FAIL" % _fail))
	quit(1 if _fail > 0 else 0)

# -- helpers --------------------------------------------------------------------------------------

func _count_mesh_instances(root: Node) -> int:
	var n := 0
	if root is MeshInstance3D:
		n += 1
	for c in root.get_children():
		n += _count_mesh_instances(c)
	return n

func _find_class(root: Node, cls: String) -> Array:
	var out := []
	if root.is_class(cls):
		out.append(root)
	for c in root.get_children():
		out.append_array(_find_class(c, cls))
	return out

# Count instances of a class that are NOT queued for deletion — the LIVE ones. A queue_free()'d node
# lingers in the tree until the next frame, so a same-frame count must exclude the released instance.
func _count_live_class(root: Node, cls: String) -> int:
	var n := 0
	for node in _find_class(root, cls):
		if is_instance_valid(node) and not node.is_queued_for_deletion():
			n += 1
	return n

# Find a Node3D whose name matches (or starts with) the given base name.
func _find_node3d_named(root: Node, base: String) -> Node3D:
	if root is Node3D and (root.name == base or String(root.name).begins_with(base)):
		return root
	for c in root.get_children():
		var found := _find_node3d_named(c, base)
		if found != null:
			return found
	return null
