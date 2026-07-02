extends Node3D
## FOCUS SIMULATION DEMO — camera focus / depth-of-field over a receding colonnade, driven ENTIRELY by
## DATA (examples/focus_params.json): `focus.focal_distance` + `focus.focal_depth` are the two focus
## knobs, composed with the SAME single `detail_knob` the painterly example ships (PR #121's seam) —
## d(x,y) = detail_knob × focus(depth(x,y)) via renderers/focus_field.gd. Pixels near the focal plane
## stay SHARP, pixels away from it BLUR; slide `focal_distance` in the JSON and the sharp band walks
## down the colonnade — the "focus visibly shifts" proof.
##
## ── HOW TO OPEN + ITERATE ────────────────────────────────────────────────────────────────────────
##   Windowed, writes NEAR + FAR focus proof PNGs then quits:
##     <Godot> --path godot res://examples/focus_scene.tscn -- --shot
##   Live (stays open, HOT-RELOADS): edit godot/examples/focus_params.json and SAVE — the focus pull
##   re-renders live, no restart (the live_demo watcher pattern):
##     <Godot> --path godot res://examples/focus_scene.tscn
##
##   THE ONE FILE LIAM EDITS TO ITERATE:  godot/examples/focus_params.json
##     detail_knob          : 0..1 — the SAME master detail slider as the painterly example (0 = nothing
##                            gets detail budget → the whole frame is out of focus).
##     focus.focal_distance : the depth (world units from the camera) that is IN focus.
##     focus.focal_depth    : how deep the in-focus band is (aperture-like: small = thin slice).
##     focus.depth_range    : [near,far] world-unit window the captured depth image spans.
##     blur_radius          : how blurred the out-of-focus pole is.
##     shots                : { near, far } — the two focal distances the --shot proof renders.
##     scene / view / sky   : parts + camera + the always-on iterable sky/clouds (same as painterly).
##
## DEPTH is captured PER PIXEL from the real render: a fullscreen post quad (hint_depth_texture shader)
## linearizes the hardware depth buffer to grayscale over depth_range, toggled visible only for the depth
## grab. The CPU then paints DOF from that depth image (FocusField.paint — the reference oracle; a GPU
## CoC delegate later reads the SAME focus DATA).

const PARAMS_PATH := "res://examples/focus_params.json"
const SHOT_NEAR := "res://live/focus_near.png"
const SHOT_FAR := "res://live/focus_far.png"
const SHOT_DEPTH := "res://live/focus_depth.png"
const SHOT_FIELD := "res://live/focus_field.png"

const DEPTH_SHADER := "
shader_type spatial;
render_mode unshaded, fog_disabled, cull_disabled;
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;
uniform float depth_min = 1.5;
uniform float depth_max = 24.0;
void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}
void fragment() {
	float depth = texture(depth_texture, SCREEN_UV).x;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
	vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view.xyz /= view.w;
	float lin = -view.z;
	float g = clamp((lin - depth_min) / max(0.0001, depth_max - depth_min), 0.0, 1.0);
	ALBEDO = vec3(g);
}
"

var runtime: GraphRuntime
var renderer: GodotSceneRenderer
var _sub: SubViewport
var _canvas: TextureRect
var _depth_quad: MeshInstance3D
var _depth_mat: ShaderMaterial
var _env_node: WorldEnvironment
var _params_mtime := -1
var _did_shot := false
var _busy := false

func _ready() -> void:
	_build_ui()
	runtime = GraphRuntime.new()
	add_child(runtime)
	renderer = GodotSceneRenderer.new()
	_sub.add_child(renderer)
	_load_params()
	_params_mtime = _mtime(PARAMS_PATH)
	await _reload()

func _process(_delta: float) -> void:
	if _busy:
		return
	var m := _mtime(PARAMS_PATH)
	if m != _params_mtime:
		_params_mtime = m
		await _reload()

# ── the live pipeline: build scene → capture color + depth → CPU focus paint ───────────────────────

func _reload() -> void:
	_busy = true
	_params_mtime = _mtime(PARAMS_PATH)
	var cfg := _load_params()
	_build_env(_sub, cfg)
	runtime.load_arrangement(_arrangement(cfg))
	var eval_output := runtime.evaluate()
	renderer.render(eval_output, runtime.arrangement)
	renderer.apply_view(eval_output, runtime.arrangement, _sub)
	await _capture_and_paint(cfg)

func _capture_and_paint(cfg: Dictionary) -> void:
	var focus: Dictionary = cfg.get("focus", {})
	var rng: Array = focus.get("depth_range", [1.5, 24.0])
	_depth_mat.set_shader_parameter("depth_min", float(rng[0]))
	_depth_mat.set_shader_parameter("depth_max", float(rng[1]))
	# 1) color frame (depth quad hidden)
	_depth_quad.visible = false
	var color := await _grab_frame()
	# 2) depth frame (fullscreen depth quad on). The quad's gray rides the normal color pipeline, so
	#    for THIS grab the tonemapper is swapped to LINEAR (FILMIC would bend the values) and the 8-bit
	#    sRGB framebuffer encode is inverted on the CPU (srgb_to_linear) — leaving true normalized depth.
	var prev_env: Environment = _env_node.environment if _env_node != null else null
	var depth_env := Environment.new()
	depth_env.background_mode = Environment.BG_COLOR
	depth_env.background_color = Color(1, 1, 1)
	depth_env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	if _env_node != null:
		_env_node.environment = depth_env
	_depth_quad.visible = true
	var depth := await _grab_frame()
	_depth_quad.visible = false
	if _env_node != null and prev_env != null:
		_env_node.environment = prev_env
	depth.srgb_to_linear()
	# 3) downscale both to the CPU-paint resolution (the same paint_width tunable as painterly)
	var paint_w := int(cfg.get("paint_width", 640))
	color = _downscale(color, paint_w)
	depth = _downscale(depth, paint_w)
	color.convert(Image.FORMAT_RGBAF)
	depth.convert(Image.FORMAT_RGBAF)
	# 4) the focus paint: d = detail_knob × focus(depth) — sharp at the focal plane, blurred away from it
	var painted := FocusField.paint(color, depth, cfg)
	var tex := ImageTexture.create_from_image(painted)
	_canvas.texture = tex
	_busy = false
	print("[focus_example] painted; knob=%.2f focal_distance=%.2f focal_depth=%.2f" % [
		float(cfg.get("detail_knob", 1.0)),
		float(focus.get("focal_distance", 6.0)), float(focus.get("focal_depth", 2.0))])
	# 5) --shot: NEAR + FAR focal-distance proofs (the focus visibly shifts), + depth + field debug views
	if _shot_requested() and not _did_shot:
		_did_shot = true
		DirAccess.make_dir_recursive_absolute("res://live")
		var shots: Dictionary = cfg.get("shots", { "near": 4.5, "far": 12.5 })
		var near_cfg := cfg.duplicate(true)
		(near_cfg["focus"] as Dictionary)["focal_distance"] = float(shots.get("near", 4.5))
		var far_cfg := cfg.duplicate(true)
		(far_cfg["focus"] as Dictionary)["focal_distance"] = float(shots.get("far", 12.5))
		var near_img := FocusField.paint(color, depth, near_cfg)
		var far_img := FocusField.paint(color, depth, far_cfg)
		near_img.convert(Image.FORMAT_RGBA8)
		far_img.convert(Image.FORMAT_RGBA8)
		near_img.save_png(SHOT_NEAR)
		far_img.save_png(SHOT_FAR)
		var d8 := depth.duplicate()
		d8.convert(Image.FORMAT_RGBA8)
		d8.save_png(SHOT_DEPTH)
		var field := FocusField.build(depth, float(cfg.get("detail_knob", 1.0)), near_cfg.get("focus", {}))
		var dbg := DetailField.to_debug_image(field, depth.get_width(), depth.get_height())
		dbg.convert(Image.FORMAT_RGBA8)
		dbg.save_png(SHOT_FIELD)
		print("[focus_example] proof: %s (near focus), %s (far focus), %s (depth), %s (field)" % [
			SHOT_NEAR, SHOT_FAR, SHOT_DEPTH, SHOT_FIELD])
		get_tree().quit(0)

func _grab_frame() -> Image:
	for _i in 3:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	return _sub.get_texture().get_image()

func _downscale(img: Image, paint_w: int) -> Image:
	if img.get_width() > paint_w:
		var ph := int(round(float(paint_w) * float(img.get_height()) / float(img.get_width())))
		img.resize(paint_w, ph, Image.INTERPOLATE_BILINEAR)
	return img

# ── the scene as DATA: a receding colonnade so depth (and therefore focus) is legible ───────────────

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
			push_warning("[focus_example] unknown catalog part '%s' (skipped)" % part_name)
			continue
		var cid := "part_%d" % idx
		var tid := "place_%d" % idx
		nodes.append({ "id": cid, "type": "Const", "params": { "value": desc } })
		nodes.append({ "id": tid, "type": "Transform", "params": { "position": pos } })
		wires.append({ "from": cid, "out": "value", "to": tid, "in": "node" })
		group_ins.append(tid)
		idx += 1
	nodes.append({ "id": "scene", "type": "Group", "params": { "count": group_ins.size(), "name": "focus_scene" } })
	for j in group_ins.size():
		wires.append({ "from": group_ins[j], "out": "node", "to": "scene", "in": "in_%d" % j })
	var v: Dictionary = cfg.get("view", {})
	nodes.append({ "id": "view", "type": "View", "params": {
		"position": v.get("position", [0.0, 2.0, 2.0]),
		"look_at": v.get("look_at", [0.0, 1.2, -8.0]),
		"yfov": float(v.get("yfov", 50.0)),
	} })
	return { "format": "resonance.arrangement/v1", "name": "focus-example", "nodes": nodes, "wires": wires }

## Default scene: pillar pairs marching away from the camera (z = -2 / -6 / -10 / -14) with spheres on
## top, a far cone, and a long ground slab — objects at clearly separated depths so the focus pull reads.
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
		"detail_knob": 1.0,
		"focus": { "focal_distance": 4.5, "focal_depth": 1.8, "depth_range": [1.5, 24.0] },
		"blur_radius": 7,
		"paint_width": 640,
		"shots": { "near": 4.5, "far": 12.5 },
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

# ── window / offscreen viewport / environment (the painterly_scene pattern, verbatim) ────────────────

func _build_ui() -> void:
	_sub = SubViewport.new()
	_sub.size = Vector2i(1280, 854)
	_sub.msaa_3d = Viewport.MSAA_4X
	_sub.transparent_bg = false
	_sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_sub)
	_build_env(_sub, _load_params())
	# The fullscreen depth-capture quad (hidden except during the depth grab).
	var shader := Shader.new()
	shader.code = DEPTH_SHADER
	_depth_mat = ShaderMaterial.new()
	_depth_mat.shader = shader
	_depth_quad = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(2, 2)
	_depth_quad.mesh = quad
	_depth_quad.material_override = _depth_mat
	_depth_quad.extra_cull_margin = 16384.0
	_depth_quad.visible = false
	_sub.add_child(_depth_quad)
	var layer := CanvasLayer.new()
	add_child(layer)
	_canvas = TextureRect.new()
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_canvas.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_canvas.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	layer.add_child(_canvas)

## Always-on iterable sky + clouds (the standing rule): the same PainterlySky module + `sky` JSON block
## as the painterly example — edit a sky/cloud knob in focus_params.json and only the environment rebuilds.
func _build_env(into: Node, cfg: Dictionary = {}) -> void:
	for c in into.get_children():
		if c is WorldEnvironment or c is DirectionalLight3D:
			c.queue_free()
	var sky_desc: Dictionary = cfg.get("sky", PainterlySky.default_descriptor())
	var built := PainterlySky.build(sky_desc)
	_env_node = WorldEnvironment.new()
	_env_node.environment = built["environment"]
	into.add_child(_env_node)
	into.add_child(built["sun"])

func _shot_requested() -> bool:
	return "--shot" in OS.get_cmdline_user_args() or "--shot" in OS.get_cmdline_args()

func _mtime(path: String) -> int:
	var abs := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(path):
		return -1
	return int(FileAccess.get_modified_time(abs))
