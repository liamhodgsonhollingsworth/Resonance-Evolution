extends Node3D
## GALLERY — a second sample scene over the SAME renderer-neutral seam as `walkabout`.
##
## Where `walkabout/walkabout.gd` lays ingested assets out as a walkable grid on a floor, the gallery
## arranges them as a **circular turntable showcase**: every ingested asset is placed evenly around a
## ring facing a central camera, and the whole ring slowly auto-orbits so each asset rotates into view.
## The point of a SECOND scene is to prove the seam is scene-agnostic — both scenes do the identical
## load-arrangement -> evaluate -> render dance through `GraphRuntime` + `GodotSceneRenderer`; only the
## LAYOUT (the Transform params they emit) differs. No engine/foundation code is touched: a scene is
## just a different arrangement of Model -> Transform DATA plus a camera, exactly like walkabout.
##
## Launch (windowed, auto-orbiting showcase):
##   <godot> --path godot res://gallery/gallery.tscn
## Headless smoke test:
##   <godot> --headless --path godot -s res://headless_gallery_test.gd

const INGESTED_DIR := "res://assets/ingested/"
const RING_RADIUS := 6.0       # meters: how far each asset sits from the center
const RING_HEIGHT := 0.0       # meters: assets sit on the ground plane (meter-scale kits)
const ORBIT_DEG_PER_SEC := 12.0  # the turntable's auto-orbit speed
const SHOT_OUT := "res://live/gallery_shot.png"

var runtime: GraphRuntime
var renderer: GodotSceneRenderer
var _ring: Node3D            # the orbiting pivot the rendered assets hang under
var _shot_frames := 0

func _ready() -> void:
	_build_world()
	runtime = GraphRuntime.new()
	add_child(runtime)
	renderer = GodotSceneRenderer.new()
	# The renderer's rendered children become the ring's children so the whole set orbits as a unit.
	_ring.add_child(renderer)
	var arrangement := assemble_arrangement()
	runtime.load_arrangement(arrangement)
	var eval_output := runtime.evaluate()
	renderer.render(eval_output, runtime.arrangement)
	# ADDITIVE camera-as-DATA: a View node in the arrangement drives a Camera3D from its
	# renderer-neutral descriptor and becomes current; with no View (the gallery's default), this is
	# a no-op and the center turntable camera below stays current. Mounted on `self` (not the orbiting
	# ring) so a View camera would NOT orbit. Keeps the gallery a single-arrangement scene like main.
	renderer.apply_view(eval_output, runtime.arrangement, self)
	print("[gallery] ready; %d runtime node(s); %d asset(s) ringed; %d rendered object(s)" % [
		runtime.nodes.size(), _asset_count(), renderer.get_child_count()])

func _process(delta: float) -> void:
	# Auto-orbit the ring so each showcased asset rotates past the camera (the "turntable").
	if _ring != null:
		_ring.rotate_y(deg_to_rad(ORBIT_DEG_PER_SEC) * delta)
	# CI one-shot: launched with `-- --shot`, render a few frames -> png, quit (proves it runs).
	if "--shot" in OS.get_cmdline_user_args() or "--shot" in OS.get_cmdline_args():
		_shot_frames += 1
		if _shot_frames == 15:
			await _capture(SHOT_OUT)
			get_tree().quit()

func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)

# --- the world (center camera + lights + the orbiting ring pivot) ----------------------------
func _build_world() -> void:
	# A fixed FALLBACK camera at the center, looking out across the ring (slightly raised + tilted
	# down). Active unless the arrangement supplies a View node, in which case apply_view() (in
	# _ready) builds a camera from that descriptor and makes IT current instead.
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	cam.position = Vector3(0, 2.2, 0)
	cam.rotation_degrees = Vector3(-8, 0, 0)
	add_child(cam)

	# Lighting + environment (a neutral gallery backdrop, distinct from walkabout's floor scene).
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -30, 0)
	light.light_energy = 1.2
	add_child(light)
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.06, 0.07, 0.09)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.55, 0.6)
	env.ambient_light_energy = 0.8
	env_node.environment = env
	add_child(env_node)

	# The orbiting pivot: rendered assets become its children, so rotating it spins the whole showcase.
	_ring = Node3D.new()
	_ring.name = "Ring"
	add_child(_ring)

# --- the arrangement: ingested assets laid out in a RING (the gallery's distinct layout) ------

## Every ingested Model node (from singles AND kit-combined arrangements), de-duplicated by GLB path so
## a kit member isn't shown twice. Pure data read — never touches the engine.
func _ring_models() -> Array:
	var models := []
	var seen := {}
	var d := DirAccess.open(INGESTED_DIR)
	if d == null:
		return models
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if f.ends_with(".arrangement.json"):
			var data = JSON.parse_string(FileAccess.get_file_as_string(INGESTED_DIR + f))
			if typeof(data) == TYPE_DICTIONARY:
				for node in data.get("nodes", []):
					if String(node.get("type")) != "Model":
						continue
					var p: Dictionary = node.get("params", {})
					var mpath := String(p.get("path", ""))
					if mpath != "" and not seen.has(mpath):
						seen[mpath] = true
						models.append(node)
		f = d.get_next()
	d.list_dir_end()
	models.sort_custom(func(a, b): return String(a.get("params", {}).get("path", "")) < String(b.get("params", {}).get("path", "")))
	return models

func _asset_count() -> int:
	return _ring_models().size()

## Build a Model -> Transform per asset, placing each evenly around a ring of RING_RADIUS and facing
## inward toward the center camera. The orbit is applied at the scene level (rotating the ring pivot),
## so the arrangement itself is a STATIC ring — the same renderer-neutral DATA the walkabout produces,
## differing only in the layout math. Public so the headless test can assemble + evaluate it directly.
func assemble_arrangement() -> Dictionary:
	var nodes := []
	var wires := []
	var models := _ring_models()
	var n := models.size()
	for i in n:
		var node = models[i]
		var mid := "m_%d" % i
		var tid := "t_%d" % i
		var theta := TAU * float(i) / float(maxi(1, n))
		var x := RING_RADIUS * sin(theta)
		var z := RING_RADIUS * cos(theta)
		# Face inward toward the center (the asset's +Z looks back at the camera at the origin).
		var yaw_deg := rad_to_deg(theta) + 180.0
		nodes.append({ "id": mid, "type": "Model", "params": node.get("params", {}) })
		nodes.append({ "id": tid, "type": "Transform",
			"params": { "position": [x, RING_HEIGHT, z], "rotation": [0, yaw_deg, 0], "scale": [1, 1, 1] } })
		wires.append({ "from": mid, "out": "node", "to": tid, "in": "node" })
	if nodes.is_empty():
		# Fallback: a built-in primitive box so the gallery is never empty (asset-free, portable).
		nodes.append({ "id": "fallback", "type": "Model", "params": {} })
	return { "format": "resonance.arrangement/v1", "name": "gallery", "nodes": nodes, "wires": wires }
