extends Node3D
## render_view — the "single scene -> STATIC VIEW" driver: render(scene, view) -> ONE PNG.
##
## It assembles a self-contained arrangement (a Group of Model->Transform scene nodes + a View node),
## evaluates it to renderer-neutral DATA, lets GodotSceneRenderer build the scene AND drive a Camera3D
## from the `view` descriptor, then captures a single still through THAT camera. This is the keystone
## the View primitive exists for: the camera is DATA, so a still is render(scene, view), not a
## hardcoded viewpoint. It reuses the same `--shot` capture convention main.gd / gallery.gd use.
##
##   # windowed (writes godot/live/render_view.png after a few frames, then quits):
##   <godot> --path godot res://render_view.tscn -- --shot
##   # headless smoke (no GPU capture, just proves the assemble->render->apply_view path runs):
##   <godot> --headless --path godot res://render_view.tscn
##
## The arrangement defaults to a built-in primitive scene (asset-free, deterministic) but reads
## res://live/render_view.arrangement.json if present, so the bridge can drive a custom scene + view.

const ARRANGEMENT_PATH := "res://live/render_view.arrangement.json"
const SHOT_OUT := "res://live/render_view.png"

var runtime: GraphRuntime
var renderer: GodotSceneRenderer
var _shot_frames := 0

func _ready() -> void:
	_build_env()
	runtime = GraphRuntime.new()
	add_child(runtime)
	renderer = GodotSceneRenderer.new()
	add_child(renderer)
	runtime.load_arrangement(_arrangement())
	var eval_output := runtime.evaluate()
	renderer.render(eval_output, runtime.arrangement)
	# Camera-as-DATA: the View node in the arrangement drives the capture camera. apply_view returns
	# null only if the arrangement carries no View — then the fallback camera from _build_env() frames it.
	var cam := renderer.apply_view(eval_output, runtime.arrangement, self)
	print("[render_view] ready; %d runtime node(s); view-driven camera: %s" % [
		runtime.nodes.size(), "yes" if cam != null else "no (fallback)"])
	# Headless (no --shot): we've proven the path runs; quit so the smoke test terminates.
	if not _shot_requested():
		get_tree().quit(0)

func _process(_delta: float) -> void:
	if not _shot_requested():
		return
	_shot_frames += 1
	if _shot_frames == 15:
		await _capture(SHOT_OUT)
		print("[render_view] static view captured -> ", SHOT_OUT)
		get_tree().quit(0)

func _shot_requested() -> bool:
	return "--shot" in OS.get_cmdline_user_args() or "--shot" in OS.get_cmdline_args()

func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://live")
	get_viewport().get_texture().get_image().save_png(path)

# A fallback camera (used only when the arrangement has no View node) + lighting + environment, so a
# bare scene is still visible. The View node, when present, takes over as the current camera.
func _build_env() -> void:
	var cam := Camera3D.new()
	# Set the look-at transform tree-independently (Basis.looking_at), so it's valid immediately even
	# in a headless tree before the first frame propagates global transforms (avoids look_at's warning).
	var cpos := Vector3(2.5, 2.0, 3.5)
	cam.transform = Transform3D(Basis.looking_at(Vector3.ZERO - cpos, Vector3.UP), cpos)
	add_child(cam)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, -35, 0)
	add_child(light)
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.08, 0.09, 0.11)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.45, 0.45, 0.5)
	env.ambient_light_energy = 0.6
	env_node.environment = env
	add_child(env_node)

# The scene + view as DATA. Reads a custom arrangement from disk if present; else a deterministic
# built-in scene (a Group of a box + a sphere, asset-free GLBs generated on first run) viewed from an
# authored View — render(scene, view), the keystone path expressed entirely as an arrangement.
func _arrangement() -> Dictionary:
	if FileAccess.file_exists(ARRANGEMENT_PATH):
		var data = JSON.parse_string(FileAccess.get_file_as_string(ARRANGEMENT_PATH))
		if typeof(data) == TYPE_DICTIONARY:
			return data
	var box := "user://render_view_box.glb"
	var orb := "user://render_view_orb.glb"
	_make_mesh_glb(box, BoxMesh.new())
	_make_mesh_glb(orb, SphereMesh.new())
	return {
		"format": "resonance.arrangement/v1",
		"name": "render-view",
		"nodes": [
			{ "id": "box_a", "type": "Model", "params": { "name": "a", "path": box } },
			{ "id": "place_a", "type": "Transform", "params": { "position": [-0.8, 0, 0] } },
			{ "id": "box_b", "type": "Model", "params": { "name": "b", "path": orb } },
			{ "id": "place_b", "type": "Transform", "params": { "position": [0.8, 0, 0] } },
			{ "id": "scene", "type": "Group", "params": { "count": 2, "name": "scene" } },
			{ "id": "view", "type": "View", "params": { "position": [2.5, 2.0, 3.5], "look_at": [0, 0, 0], "yfov": 60.0 } }
		],
		"wires": [
			{ "from": "box_a", "out": "node", "to": "place_a", "in": "node" },
			{ "from": "box_b", "out": "node", "to": "place_b", "in": "node" },
			{ "from": "place_a", "out": "node", "to": "scene", "in": "in_0" },
			{ "from": "place_b", "out": "node", "to": "scene", "in": "in_1" }
		]
	}

func _make_mesh_glb(path: String, mesh: Mesh) -> void:
	if FileAccess.file_exists(path):
		return
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	root.add_child(mi)
	mi.owner = root
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_scene(root, st) == OK:
		doc.write_to_filesystem(st, path)
	root.queue_free()
