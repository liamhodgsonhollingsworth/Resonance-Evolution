extends Node3D
## A NAVIGABLE 3D demo scene Liam can walk around in.
##
## It is deliberately built on the SAME renderer-neutral seam as everything else: it loads an
## "arrangement" of `Model`/`Transform` primitives (DATA), evaluates it through GraphRuntime to
## renderer-neutral `scene_node` descriptors, and hands those to GodotSceneRenderer (the only
## Godot-coupled delegate). The only thing this scene adds over `main.gd` is a FLOOR, lights, and
## a first-person CharacterBody3D so a human can move + look — the engine seam is untouched.
##
## The arrangement it loads is assembled from the asset-ingestion pipeline's output: every
## ingested asset's `Model` node, each fed through a `Transform` that lays them out in a row so
## you can walk up to each one. If no ingested assets are present it falls back to a built-in
## primitive box so the scene is never empty.
##
## Launch (windowed, walkable):
##   <godot> --path godot res://walkabout/walkabout.tscn
## Headless smoke test:
##   <godot> --headless --path godot -s res://headless_walkabout_test.gd

const INGESTED_DIR := "res://assets/ingested/"
const SPACING := 2.5      # meters between laid-out assets
const ASSET_SCALE := 12.0 # CC0 sample models are authored at real-world cm scale; scale up to be visible
const ASSET_LIFT := 1.0   # meters off the floor, so a scaled asset sits at roughly eye level
const SHOT_OUT := "res://live/walkabout_shot.png"

var runtime: GraphRuntime
var renderer: GodotSceneRenderer
var _shot_frames := 0

func _ready() -> void:
	_build_world()
	runtime = GraphRuntime.new()
	add_child(runtime)
	renderer = GodotSceneRenderer.new()
	add_child(renderer)
	var arrangement := _assemble_arrangement()
	runtime.load_arrangement(arrangement)
	renderer.render(runtime.evaluate(), runtime.arrangement)
	print("[walkabout] ready; %d node(s); %d asset(s) laid out" % [
		runtime.nodes.size(), _asset_arrangements().size()])

func _process(_delta: float) -> void:
	# CI one-shot: launched with `-- --shot`, render a few frames -> png, quit (proves it runs).
	if "--shot" in OS.get_cmdline_user_args() or "--shot" in OS.get_cmdline_args():
		_shot_frames += 1
		if _shot_frames == 15:
			await _capture(SHOT_OUT)
			get_tree().quit()

func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)

# --- the world (floor + lights + player) — additive over the engine seam --------------------
func _build_world() -> void:
	# Floor: a large static body so the player can walk on it.
	var floor_body := StaticBody3D.new()
	floor_body.name = "Floor"
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40, 40)
	floor_mesh.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.20, 0.22, 0.26)
	floor_mesh.material_override = mat
	floor_body.add_child(floor_mesh)
	var floor_col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40, 0.2, 40)
	floor_col.shape = box
	floor_col.position = Vector3(0, -0.1, 0)
	floor_body.add_child(floor_col)
	add_child(floor_body)

	# Lighting + environment.
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, -40, 0)
	light.light_energy = 1.1
	add_child(light)
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.10, 0.12, 0.16)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.5, 0.55)
	env.ambient_light_energy = 0.7
	env_node.environment = env
	add_child(env_node)

	# Player: the in-house first-person controller, with a capsule collider + eye-height camera.
	var player := FpsController.new()
	player.name = "Player"
	player.position = Vector3(0, 1.0, 6.0)   # stand back so the laid-out row is in view
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.height = 1.8
	cap.radius = 0.35
	col.shape = cap
	col.position = Vector3(0, 0.9, 0)
	player.add_child(col)
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	cam.position = Vector3(0, 1.6, 0)
	player.add_child(cam)
	add_child(player)

# --- the arrangement: every ingested asset, laid out in a row via Model -> Transform ---------
func _asset_arrangements() -> Array:
	var out := []
	var d := DirAccess.open(INGESTED_DIR)
	if d == null:
		return out
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if f.ends_with(".arrangement.json"):
			out.append(INGESTED_DIR + f)
		f = d.get_next()
	d.list_dir_end()
	out.sort()
	return out

func _assemble_arrangement() -> Dictionary:
	var nodes := []
	var wires := []
	var paths := _asset_arrangements()
	var i := 0
	var n := paths.size()
	for p in paths:
		var text := FileAccess.get_file_as_string(p)
		var data = JSON.parse_string(text)
		if typeof(data) != TYPE_DICTIONARY:
			continue
		for node in data.get("nodes", []):
			if String(node.get("type")) != "Model":
				continue
			var mid := "m_%d" % i
			var tid := "t_%d" % i
			nodes.append({ "id": mid, "type": "Model", "params": node.get("params", {}) })
			# Lay assets out in a centered row along X, scaled up + lifted so each is walk-up visible.
			var x := (float(i) - float(n - 1) / 2.0) * SPACING
			nodes.append({ "id": tid, "type": "Transform",
				"params": { "position": [x, ASSET_LIFT, 0.0], "rotation": [0, 0, 0],
					"scale": [ASSET_SCALE, ASSET_SCALE, ASSET_SCALE] } })
			wires.append({ "from": mid, "out": "node", "to": tid, "in": "node" })
			i += 1
	if nodes.is_empty():
		# Fallback: a built-in primitive box so the scene is never empty (asset-free, portable).
		nodes.append({ "id": "fallback", "type": "Model", "params": {} })
	return { "format": "resonance.arrangement/v1", "name": "walkabout", "nodes": nodes, "wires": wires }
