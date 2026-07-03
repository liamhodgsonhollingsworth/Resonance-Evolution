extends Node3D
## STEREO MODE DEMO — one slider from flat screen to VR, on a REAL scene. An ordinary arrangement
## scene (colonnade + spheres + sky, the focus-demo world) is wrapped by StereoMode WITHOUT any
## scene changes: the wrapper takes the active View camera + the `stereo` DATA block and morphs
## the display from ONE full image (t=0) to TWO repositionable images of the exact same scene
## (t=1, cross-eye layout by default — cross your eyes and the scene itself fuses in depth).
##
## ── HOW TO OPEN + ITERATE ────────────────────────────────────────────────────────────────────
##   Windowed, writes the t=0 / t=0.5 / t=1 proof PNGs then quits:
##     <Godot> --path godot res://examples/stereo_mode_scene.tscn -- --shot
##   Live (stays open, HOT-RELOADS): edit godot/examples/stereo_mode_params.json and SAVE — the
##   morph re-drives live, no restart:
##     <Godot> --path godot res://examples/stereo_mode_scene.tscn
##
##   THE ONE FILE LIAM EDITS TO ITERATE:  godot/examples/stereo_mode_params.json
##     t              : 0..1 — THE slider. 0 = one flat image; 1 = the full stereo pair.
##     geometry.ipd_m : eye separation (m). 0.063 = human; larger = hyper-stereo (a giant's view —
##                      more depth pop on far scenes; this is the XR world_scale seam).
##     geometry.screen_distance_m : the convergence plane — objects there sit ON the screen.
##     layout.mode    : "cross" (left eye's image on the RIGHT — cross-eye viewing) | "parallel".
##     layout.rects   : { left:[x,y,w,h], right:[…] } normalized — put the two images ANYWHERE.
##     fit_camera     : true = t=0 exactly reproduces the View camera's framing.
##     scene/view/sky : the world itself (same parts/View/sky DATA as the focus demo).
##     shots          : the t values --shot renders.

const PARAMS_PATH := "res://examples/stereo_mode_params.json"
const SHOT_DIR := "res://docs"

var runtime: GraphRuntime
var renderer: GodotSceneRenderer
var stereo: StereoMode
var _env_node: WorldEnvironment = null
var _sun: DirectionalLight3D = null
var _params_mtime := -1
var _busy := false
var _did_shot := false

func _ready() -> void:
	get_window().size = Vector2i(1280, 800)
	get_window().title = "StereoMode — one slider from flat to VR"
	runtime = GraphRuntime.new()
	add_child(runtime)
	renderer = GodotSceneRenderer.new()
	add_child(renderer)
	stereo = StereoMode.new()
	add_child(stereo)
	_params_mtime = _mtime(PARAMS_PATH)
	await _reload()

func _process(_delta: float) -> void:
	if _busy:
		return
	var m := _mtime(PARAMS_PATH)
	if m != _params_mtime:
		_params_mtime = m
		await _reload()

func _reload() -> void:
	_busy = true
	_params_mtime = _mtime(PARAMS_PATH)
	var cfg := _load_params()
	_build_env(cfg)
	runtime.load_arrangement(_arrangement(cfg))
	var eval_output := runtime.evaluate()
	renderer.render(eval_output, runtime.arrangement)
	var cam := renderer.apply_view(eval_output, runtime.arrangement, self)
	if cam == null:
		push_warning("[stereo_mode_example] no View in the arrangement")
		_busy = false
		return
	var m := stereo.wrap(cam, _stereo_block(cfg))
	print("[stereo_mode_example] t=%.2f ipd_eff=%.3f m rects=%s" % [
		float(m["t"]), float(m["ipd_eff_m"]), JSON.stringify(m["rects"])])
	if _shot_requested() and not _did_shot:
		_did_shot = true
		await _shots(cfg)
		get_tree().quit(0)
	_busy = false

## --shot: drive the SAME live path through each t and screenshot the actual window — the proof
## that the display really morphs from one image to the repositionable pair.
func _shots(cfg: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	var block := _stereo_block(cfg)
	for t in cfg.get("shots", [0.0, 0.5, 1.0]):
		block["t"] = float(t)
		stereo.apply(block)
		for _i in 6:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path := SHOT_DIR + "/stereo_mode_t%d.png" % int(round(float(t) * 100.0))
		img.save_png(ProjectSettings.globalize_path(path))
		print("[stereo_mode_example] shot %s" % path)

func _stereo_block(cfg: Dictionary) -> Dictionary:
	return {
		"t": cfg.get("t", 1.0),
		"fit_camera": cfg.get("fit_camera", true),
		"geometry": cfg.get("geometry", {}),
		"layout": cfg.get("layout", { "mode": "cross" }),
		"background": cfg.get("background", [0.02, 0.02, 0.02]),
	}

# ── the scene as DATA (the focus-demo colonnade — depth-legible on purpose) ────────────────────

func _arrangement(cfg: Dictionary) -> Dictionary:
	var scene: Array = cfg.get("scene", _default_scene())
	var nodes := []
	var wires := []
	var group_ins := []
	var idx := 0
	for entry in scene:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var part_name := String(entry.get("part", "box"))
		var overrides: Dictionary = entry.get("params", {})
		var pos: Array = entry.get("pos", [0.0, 0.0, 0.0])
		var desc := PartsCatalog.part_node(part_name, overrides, [0.0, 0.0, 0.0])
		if desc.is_empty():
			push_warning("[stereo_mode_example] unknown catalog part '%s' (skipped)" % part_name)
			continue
		var cid := "part_%d" % idx
		var tid := "place_%d" % idx
		nodes.append({ "id": cid, "type": "Const", "params": { "value": desc } })
		nodes.append({ "id": tid, "type": "Transform", "params": { "position": pos } })
		wires.append({ "from": cid, "out": "value", "to": tid, "in": "node" })
		group_ins.append(tid)
		idx += 1
	nodes.append({ "id": "scene", "type": "Group", "params": { "count": group_ins.size(), "name": "stereo_mode_scene" } })
	for j in group_ins.size():
		wires.append({ "from": group_ins[j], "out": "node", "to": "scene", "in": "in_%d" % j })
	var v: Dictionary = cfg.get("view", {})
	nodes.append({ "id": "view", "type": "View", "params": {
		"position": v.get("position", [0.0, 2.0, 2.0]),
		"look_at": v.get("look_at", [0.0, 1.2, -8.0]),
		"yfov": float(v.get("yfov", 50.0)),
	} })
	return { "format": "resonance.arrangement/v1", "name": "stereo-mode-example", "nodes": nodes, "wires": wires }

func _default_scene() -> Array:
	var parts := []
	for z in [-2.0, -6.0, -10.0, -14.0]:
		for sx in [-1.6, 1.6]:
			parts.append({ "part": "cylinder", "params": { "radius": 0.35, "height": 2.4 }, "pos": [sx, 1.2, z] })
			parts.append({ "part": "sphere", "params": { "radius": 0.5 }, "pos": [sx, 2.9, z] })
	parts.append({ "part": "cone", "params": { "radius": 0.9, "height": 2.0 }, "pos": [0.0, 1.0, -17.0] })
	parts.append({ "part": "box", "params": { "width": 7.0, "height": 0.2, "depth": 26.0 }, "pos": [0.0, -0.1, -8.0] })
	return parts

func _default_params() -> Dictionary:
	return {
		"t": 1.0,
		"fit_camera": true,
		"geometry": {
			"screen_distance_m": 0.6,
			"ipd_m": 0.22,
			"image_width_px": 960, "image_height_px": 600,
			"znear_m": 0.05, "zfar_m": 100.0
		},
		"layout": { "mode": "cross" },
		"background": [0.02, 0.02, 0.02],
		"shots": [0.0, 0.5, 1.0],
		"scene": _default_scene(),
		"sky": PainterlySky.default_descriptor(),
		"view": { "position": [0.0, 2.0, 2.0], "look_at": [0.0, 1.4, -8.0], "yfov": 50.0 },
	}

func _load_params() -> Dictionary:
	if FileAccess.file_exists(PARAMS_PATH):
		var data = JSON.parse_string(FileAccess.get_file_as_string(PARAMS_PATH))
		if typeof(data) == TYPE_DICTIONARY:
			return data
	var cfg := _default_params()
	var f := FileAccess.open(PARAMS_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(cfg, "\t"))
		f.close()
	return cfg

## Always-on iterable sky + clouds (standing rule) — shared World3D, so BOTH eye viewports see it.
func _build_env(cfg: Dictionary) -> void:
	if _env_node != null and is_instance_valid(_env_node):
		_env_node.queue_free()
	if _sun != null and is_instance_valid(_sun):
		_sun.queue_free()
	var built := PainterlySky.build(cfg.get("sky", PainterlySky.default_descriptor()))
	_env_node = WorldEnvironment.new()
	_env_node.environment = built["environment"]
	add_child(_env_node)
	_sun = built["sun"]
	add_child(_sun)

func _shot_requested() -> bool:
	return "--shot" in OS.get_cmdline_user_args() or "--shot" in OS.get_cmdline_args()

func _mtime(path: String) -> int:
	if not FileAccess.file_exists(path):
		return -1
	return int(FileAccess.get_modified_time(ProjectSettings.globalize_path(path)))
