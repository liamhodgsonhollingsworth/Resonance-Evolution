extends Node3D
## A SELF-CONTAINED, deterministic proof of the end-to-end LIVE 3D ITERATION loop.
##
## It exercises the SAME path the real game uses — write the arrangement file on disk, let
## LiveHost notice the content change, re-wire the already-loaded primitives, re-evaluate to
## renderer-neutral DATA, and let the GodotSceneRenderer delegate rebuild the live scene — with
## NO restart and NO recompile between steps. Three successive on-disk edits each produce a
## visibly different 3D scene; a frame is captured after each so the change is provable by a
## before/after montage (the "verify by live effect" rule), then the run quits.
##
## Run (windowed, renders): Godot ... --path godot res://live_demo.tscn
## Outputs: res://live/demo_step1.png (box) / _step2.png (sphere, turned+scaled) / _step3.png
##          (box+sphere+cylinder composed via a Group) — three frames of one running process.

const DEMO_PATH := "res://live/demo_arrangement.json"
const BOX := "res://live/demo_box.glb"
const SPHERE := "res://live/demo_sphere.glb"
const CYL := "res://live/demo_cylinder.glb"

var runtime: GraphRuntime
var renderer: GodotSceneRenderer
var host: LiveHost

func _ready() -> void:
	_add_view()
	_make_glb(BOX, BoxMesh.new())
	_make_glb(SPHERE, SphereMesh.new())
	_make_glb(CYL, CylinderMesh.new())
	runtime = GraphRuntime.new()
	add_child(runtime)
	renderer = GodotSceneRenderer.new()
	add_child(renderer)
	host = LiveHost.new()
	host.runtime = runtime
	host.path = DEMO_PATH
	host.reloaded.connect(_on_reloaded)
	add_child(host)
	await _run_demo()
	get_tree().quit()

func _on_reloaded() -> void:
	var eval_output := runtime.evaluate()
	renderer.render(eval_output, runtime.arrangement)
	renderer.apply_view(eval_output, runtime.arrangement, self)

## Drive the three live edits through the real on-disk watcher path.
func _run_demo() -> void:
	await _edit_then_shot(_scene_box(), "res://live/demo_step1.png", "box")
	await _edit_then_shot(_scene_sphere(), "res://live/demo_step2.png", "sphere turned + scaled")
	await _edit_then_shot(_scene_trio(), "res://live/demo_step3.png", "box + sphere + cylinder (Group)")

func _edit_then_shot(arr: Dictionary, shot: String, label: String) -> void:
	# Write the NEW arrangement to disk, exactly as Claude Code / the bridge would. LiveHost
	# hashes the content, sees it changed, and re-wires + re-evaluates the running runtime.
	var f := FileAccess.open(DEMO_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(arr, "\t"))
	f.close()
	var reloaded := host.poll_once()
	assert(reloaded, "LiveHost did not detect the on-disk edit")
	# Let the delegate settle the new scene, then capture proof of the live change.
	for i in 8:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(shot)
	print("[live_demo] live edit -> %s  (%s, %d node(s) live)" % [shot, label, runtime.nodes.size()])

# --- the three arrangements (pure DATA; only Model/Transform/Group primitives) ---------------

func _scene_box() -> Dictionary:
	return {
		"format": "resonance.arrangement/v1", "name": "live-step-box",
		"nodes": [
			{ "id": "m", "type": "Model", "params": { "path": BOX } },
			{ "id": "t", "type": "Transform", "params": { "rotation": [0, 20, 0] } },
		],
		"wires": [ { "from": "m", "out": "node", "to": "t", "in": "node" } ],
	}

func _scene_sphere() -> Dictionary:
	return {
		"format": "resonance.arrangement/v1", "name": "live-step-sphere",
		"nodes": [
			{ "id": "m", "type": "Model", "params": { "path": SPHERE } },
			{ "id": "t", "type": "Transform", "params": { "rotation": [0, 45, 30], "scale": [1.6, 1.6, 1.6] } },
		],
		"wires": [ { "from": "m", "out": "node", "to": "t", "in": "node" } ],
	}

func _scene_trio() -> Dictionary:
	return {
		"format": "resonance.arrangement/v1", "name": "live-step-trio",
		"nodes": [
			{ "id": "mb", "type": "Model", "params": { "path": BOX } },
			{ "id": "tb", "type": "Transform", "params": { "position": [-2.0, 0, 0] } },
			{ "id": "ms", "type": "Model", "params": { "path": SPHERE } },
			{ "id": "ts", "type": "Transform", "params": { "position": [0, 0, 0], "scale": [1.2, 1.2, 1.2] } },
			{ "id": "mc", "type": "Model", "params": { "path": CYL } },
			{ "id": "tc", "type": "Transform", "params": { "position": [2.0, 0, 0] } },
			{ "id": "g", "type": "Group", "params": { "count": 3, "name": "trio" } },
		],
		"wires": [
			{ "from": "mb", "out": "node", "to": "tb", "in": "node" },
			{ "from": "ms", "out": "node", "to": "ts", "in": "node" },
			{ "from": "mc", "out": "node", "to": "tc", "in": "node" },
			{ "from": "tb", "out": "node", "to": "g", "in": "in_0" },
			{ "from": "ts", "out": "node", "to": "g", "in": "in_1" },
			{ "from": "tc", "out": "node", "to": "g", "in": "in_2" },
		],
	}

# --- helpers (mirror main.gd's view + glb maker) ---------------------------------------------

func _make_glb(path: String, mesh: Mesh) -> void:
	if FileAccess.file_exists(path):
		return
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	root.add_child(mi)
	mi.owner = root
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_scene(root, state) == OK:
		doc.write_to_filesystem(state, path)
	root.queue_free()

func _add_view() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(2.5, 2.5, 6.0)
	cam.look_at(Vector3.ZERO, Vector3.UP)
	var light := DirectionalLight3D.new()
	add_child(light)
	light.rotation_degrees = Vector3(-45, -35, 0)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.08, 0.09, 0.11)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.45, 0.45, 0.5)
	e.ambient_light_energy = 0.6
	env.environment = e
	add_child(env)
