extends Node3D
## The running game's entry scene. It is deliberately almost empty: EVERYTHING is an
## arrangement of primitives, loaded from a watched file and hotloaded live. This scene
## only provides a camera + light to look at whatever the arrangement spawns, a
## GraphRuntime to run it, and a LiveHost to hotload it when the file changes.
##
## The live bridge (Claude <-> game):
##   - res://live/arrangement.json  — write this to change the running game live.
##   - res://live/shot_request.txt  — write a new value to ask for a screenshot.
##   - res://live/shot.png          — the running game writes the latest frame here.
## Claude Code (or the scene_bridge HTTP relay) drives the game purely through these
## files: no restart, no recompile — just a new arrangement of already-loaded primitives.

const ARRANGEMENT_PATH := "res://live/arrangement.json"
const SHOT_REQUEST := "res://live/shot_request.txt"
const SHOT_OUT := "res://live/shot.png"

var runtime: GraphRuntime
var renderer: GodotSceneRenderer
var host: LiveHost
var _shot_frames := 0
var _shot_poll := 0.0
var _last_shot_req := ""

func _ready() -> void:
	_add_view()
	_ensure_default_arrangement()
	runtime = GraphRuntime.new()
	add_child(runtime)
	renderer = GodotSceneRenderer.new()
	add_child(renderer)
	host = LiveHost.new()
	host.runtime = runtime
	host.path = ARRANGEMENT_PATH
	host.reloaded.connect(_on_reloaded)
	add_child(host)
	host.poll_once()
	if FileAccess.file_exists(SHOT_REQUEST):
		_last_shot_req = FileAccess.get_file_as_string(SHOT_REQUEST).sha256_text()
	print("[main] ready; watching ", ARRANGEMENT_PATH, " (%d node(s) live)" % runtime.nodes.size())

func _on_reloaded() -> void:
	# The arrangement changed on disk: re-evaluate it to renderer-neutral data and let the
	# Godot delegate (re)build the live scene from that data. The runtime + the data stay
	# engine-agnostic; only the delegate knows about Node3D.
	renderer.render(runtime.evaluate(), runtime.arrangement)


func _process(delta: float) -> void:
	# CI one-shot: launched with `-- --shot`, render a few frames -> res://shot.png, quit.
	if "--shot" in OS.get_cmdline_user_args() or "--shot" in OS.get_cmdline_args():
		_shot_frames += 1
		if _shot_frames == 15:
			await _capture("res://shot.png")
			get_tree().quit()
		return
	# Live screenshot-on-request: the bridge writes a new value to SHOT_REQUEST to ask
	# the running game for a fresh frame (visual feedback with no restart).
	_shot_poll += delta
	if _shot_poll >= 0.2:
		_shot_poll = 0.0
		_check_shot_request()

func _check_shot_request() -> void:
	if not FileAccess.file_exists(SHOT_REQUEST):
		return
	var h := FileAccess.get_file_as_string(SHOT_REQUEST).sha256_text()
	if h == _last_shot_req:
		return
	_last_shot_req = h
	await _capture(SHOT_OUT)
	print("[main] live screenshot -> ", SHOT_OUT)

func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)

func _add_view() -> void:
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(2.5, 2.0, 3.5)
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

func _ensure_default_arrangement() -> void:
	if FileAccess.file_exists(ARRANGEMENT_PATH):
		return
	var glb := "res://live/box.glb"
	_make_box_glb(glb)
	# A default arrangement that demonstrates WIRING: a Model fed into a Transform.
	var data := {
		"format": "resonance.arrangement/v1",
		"name": "default-scene",
		"nodes": [
			{ "id": "box", "type": "Model", "params": { "path": glb } },
			{ "id": "place", "type": "Transform", "params": { "rotation": [0, 25, 0] } }
		],
		"wires": [
			{ "from": "box", "out": "node", "to": "place", "in": "node" }
		]
	}
	var f := FileAccess.open(ARRANGEMENT_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "\t"))
	f.close()

func _make_box_glb(path: String) -> void:
	if FileAccess.file_exists(path):
		return
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	root.add_child(mi)
	mi.owner = root
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_scene(root, state) == OK:
		doc.write_to_filesystem(state, path)
	root.queue_free()
