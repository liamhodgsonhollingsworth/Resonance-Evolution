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
const SPACING := 2.5      # meters between laid-out single assets
const ASSET_SCALE := 1.0  # Kenney/Quaternius CC0 kits are authored at real-world METER scale → 1:1
const ASSET_LIFT := 0.0   # meter-scale kit models already sit on their own origin → no lift
const SHOT_OUT := "res://live/walkabout_shot.png"

var runtime: GraphRuntime
var renderer: GodotSceneRenderer
var interactor: PickupInteractor
var _player: FpsController
var _shot_frames := 0

func _ready() -> void:
	_build_world()
	runtime = GraphRuntime.new()
	add_child(runtime)
	renderer = GodotSceneRenderer.new()
	add_child(renderer)
	var arrangement := _assemble_arrangement()
	runtime.load_arrangement(arrangement)
	var eval_output := runtime.evaluate()
	renderer.render(eval_output, runtime.arrangement)
	var found := _asset_arrangements()
	# Proximity-gated pickup: every laid-out object becomes walk-up-pickable via the `proximity`
	# Context handler. Registering the rendered nodes (not the data) keeps the gate driven by where
	# things actually are in the world (the handler reads live positions as inputs each frame).
	interactor = PickupInteractor.new()
	interactor.name = "PickupInteractor"
	add_child(interactor)
	interactor.set_player(_player)
	interactor.set_world_root(self)   # placed objects (Q) join the walkabout root, like everything else
	_register_pickables(eval_output)
	# Inventory HUD: an on-screen panel of held objects + the active type. It reads the interactor and
	# refreshes on its `inventory_changed` signal — pure presentation over the pickup/place model.
	var hud := BuildHud.new()
	hud.name = "BuildHud"
	add_child(hud)
	hud.bind(interactor)
	print("[walkabout] ready; %d runtime node(s); %d kit(s) found; %d rendered object(s); %d pickable(s)" % [
		runtime.nodes.size(), (found["kits"] as Array).size(),
		renderer.get_child_count(), interactor.pickable_count()])

## Register every rendered scene object as a proximity-gated pickable. The renderer spawns one
## Node3D child per laid-out asset (in `select_roots` order); each carries its world position from
## the applied TRS — exactly the `pos_b` the proximity handler reads. We zip each rendered child to
## the scene_node DESCRIPTOR it was built from (same order), so the pickable knows its inventory
## TYPE and can be re-rendered on place-down. Walkers can then walk up, pick up (E), and place (Q).
func _register_pickables(eval_output: Dictionary) -> void:
	var roots := GodotSceneRenderer.select_roots(eval_output, runtime.arrangement)
	var descs: Array = []
	for r in roots:
		descs.append(r["desc"])
	var i := 0
	for child in renderer.get_children():
		if child is Node3D:
			var desc: Dictionary = descs[i] if i < descs.size() else {}
			interactor.register("obj_%d_%s" % [i, child.name], child, PickupInteractor.DEFAULT_RADIUS, desc)
			i += 1

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
	_player = player   # the body whose position gates proximity pickup

# --- the arrangement: ingested MODULAR KITS as buildable sets, single assets in a row ---------
## All ingested arrangements, split into kit-combined sets (`kit_*.arrangement.json`, pre-laid-out)
## vs per-asset singles (everything else). A member of an ingested kit ALSO has a single-asset
## arrangement; to avoid drawing it twice we draw the kit-combined set and skip any single whose
## Model paths the kits already cover.
func _asset_arrangements() -> Dictionary:
	var kits := []
	var singles := []
	var d := DirAccess.open(INGESTED_DIR)
	if d == null:
		return { "kits": kits, "singles": singles }
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if f.ends_with(".arrangement.json"):
			var path := INGESTED_DIR + f
			if f.begins_with("kit_"):
				kits.append(path)
			else:
				singles.append(path)
		f = d.get_next()
	d.list_dir_end()
	kits.sort()
	singles.sort()
	return { "kits": kits, "singles": singles }

func _assemble_arrangement() -> Dictionary:
	var nodes := []
	var wires := []
	var found := _asset_arrangements()
	var kit_paths: Array = found["kits"]
	var single_paths: Array = found["singles"]
	var i := 0
	var kit_index := 0
	var covered_paths := {}   # Model res paths already drawn by a kit (so singles don't duplicate)

	# (1) Each modular kit is a buildable set: take its combined Model -> Transform layout VERBATIM
	# (already grid-laid-out at correct meter scale by the ingest pipeline) and offset the whole kit
	# into its own zone along Z so multiple kits don't overlap.
	const KIT_ZONE_GAP := 12.0   # meters between kit zones
	for kp in kit_paths:
		var kdata = JSON.parse_string(FileAccess.get_file_as_string(kp))
		if typeof(kdata) != TYPE_DICTIONARY:
			continue
		var zone_z := float(kit_index) * KIT_ZONE_GAP
		var id_map := {}
		for node in kdata.get("nodes", []):
			var old_id := String(node.get("id"))
			var new_id := "k%d_%s" % [kit_index, old_id]
			id_map[old_id] = new_id
			var nt := String(node.get("type"))
			var params: Dictionary = (node.get("params", {}) as Dictionary).duplicate(true)
			if nt == "Transform":
				# Shift this kit's whole layout into its zone (preserve the kit's internal grid).
				var pos: Array = params.get("position", [0, 0, 0])
				params["position"] = [float(pos[0]), float(pos[1]), float(pos[2]) + zone_z]
			elif nt == "Model":
				covered_paths[String(params.get("path", ""))] = true
			nodes.append({ "id": new_id, "type": nt, "params": params })
		for w in kdata.get("wires", []):
			wires.append({
				"from": id_map.get(String(w.get("from")), String(w.get("from"))),
				"out": w.get("out"),
				"to": id_map.get(String(w.get("to")), String(w.get("to"))),
				"in": w.get("in"),
			})
		kit_index += 1

	# (2) Any remaining single (non-kit) asset gets the centered-row layout, skipping anything a kit
	# already covers. Singles render in a row in front of the kit zones (negative Z).
	var single_models := []
	for p in single_paths:
		var data = JSON.parse_string(FileAccess.get_file_as_string(p))
		if typeof(data) != TYPE_DICTIONARY:
			continue
		for node in data.get("nodes", []):
			if String(node.get("type")) != "Model":
				continue
			var mpath := String((node.get("params", {}) as Dictionary).get("path", ""))
			if covered_paths.has(mpath):
				continue
			single_models.append(node)
	var ns := single_models.size()
	for node in single_models:
		var mid := "m_%d" % i
		var tid := "t_%d" % i
		nodes.append({ "id": mid, "type": "Model", "params": node.get("params", {}) })
		var x := (float(i) - float(ns - 1) / 2.0) * SPACING
		nodes.append({ "id": tid, "type": "Transform",
			"params": { "position": [x, ASSET_LIFT, -KIT_ZONE_GAP], "rotation": [0, 0, 0],
				"scale": [ASSET_SCALE, ASSET_SCALE, ASSET_SCALE] } })
		wires.append({ "from": mid, "out": "node", "to": tid, "in": "node" })
		i += 1

	if nodes.is_empty():
		# Fallback: a built-in primitive box so the scene is never empty (asset-free, portable).
		nodes.append({ "id": "fallback", "type": "Model", "params": {} })
	return { "format": "resonance.arrangement/v1", "name": "walkabout", "nodes": nodes, "wires": wires }
