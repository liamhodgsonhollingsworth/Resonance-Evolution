extends Node3D
## L-SYSTEM DEMO — a branching plant GROWN from axiom + production rules + turtle DATA (the LSystem
## primitive, renderers/lsystem.gd), placed in a 3D scene with the standing always-on sky + clouds,
## and PAINTED through the same painterly pipeline as the painterly example (EffectStackCpu via
## PainterlyFalloff + the single detail-knob × falloff seam). Deterministic + seeded: the same
## lsystem_params.json grows the same plant, byte for byte.
##
## ── HOW TO OPEN + ITERATE ────────────────────────────────────────────────────────────────────────
##   Windowed, writes a painterly proof PNG then quits:
##     <Godot> --path godot res://examples/lsystem_scene.tscn -- --shot
##   Live (stays open, HOT-RELOADS): edit godot/examples/lsystem_params.json and SAVE — the plant
##   regrows + repaints live, no restart:
##     <Godot> --path godot res://examples/lsystem_scene.tscn
##
##   THE ONE FILE LIAM EDITS TO ITERATE:  godot/examples/lsystem_params.json
##     lsystem  : axiom + rules (plain string = deterministic; [[weight, replacement], ...] =
##                stochastic, drawn by the seed) + depth + seed + the turtle
##                ({ step, angle_deg, radius, radius_decay, step_decay }).
##     detail_knob / falloff / coarsen / effect_stack / paint_width : the painterly pipeline knobs
##                (identical to painterly_params.json).
##     sky      : the always-on iterable sky + clouds block.
##     view     : the camera (position / look_at / yfov).

const PARAMS_PATH := "res://examples/lsystem_params.json"
const SHOT_RAW := "res://live/lsystem_plant_raw.png"
const SHOT_PAINTED := "res://live/lsystem_plant.png"

var runtime: GraphRuntime
var renderer: GodotSceneRenderer
var _sub: SubViewport
var _canvas: TextureRect
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

func _reload() -> void:
	_busy = true
	_params_mtime = _mtime(PARAMS_PATH)
	var cfg := _load_params()
	_build_env(_sub, cfg)
	runtime.load_arrangement(_arrangement(cfg))
	var eval_output := runtime.evaluate()
	renderer.render(eval_output, runtime.arrangement)
	renderer.apply_view(eval_output, runtime.arrangement, _sub)
	await _paint_when_ready(cfg)

func _paint_when_ready(cfg: Dictionary) -> void:
	for _i in 3:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var raw := _sub.get_texture().get_image()
	var paint_w := int(cfg.get("paint_width", 640))
	if raw.get_width() > paint_w:
		var ph := int(round(float(paint_w) * float(raw.get_height()) / float(raw.get_width())))
		raw.resize(paint_w, ph, Image.INTERPOLATE_BILINEAR)
	raw.convert(Image.FORMAT_RGBAF)
	var stroke_scale := clampf(float(paint_w) / 320.0, 1.0, 4.0)
	var stack := { "stack": _scale_stroke(cfg.get("effect_stack", _default_stack()), stroke_scale) }
	var knob := float(cfg.get("detail_knob", 0.85))
	var falloff: Dictionary = cfg.get("falloff", { "type": "radial" })
	var coarsen := float(cfg.get("coarsen", 1.0))
	var painted := PainterlyFalloff.paint(raw, stack, knob, falloff, coarsen)
	var tex := ImageTexture.create_from_image(painted)
	_canvas.texture = tex
	_busy = false
	var ls: Dictionary = cfg.get("lsystem", {})
	print("[lsystem_example] painted; depth=%d seed=%d knob=%.2f" % [
		int(ls.get("depth", 0)), int(ls.get("seed", 0)), knob])
	if _shot_requested() and not _did_shot:
		_did_shot = true
		DirAccess.make_dir_recursive_absolute("res://live")
		raw.convert(Image.FORMAT_RGBA8)
		raw.save_png(SHOT_RAW)
		painted.save_png(SHOT_PAINTED)
		print("[lsystem_example] proof: %s (painted), %s (raw)" % [SHOT_PAINTED, SHOT_RAW])
		get_tree().quit(0)

# ── the arrangement: LSystem plant → Transform → Group (+ ground) + View ─────────────────────────────

func _arrangement(cfg: Dictionary) -> Dictionary:
	var ls: Dictionary = cfg.get("lsystem", _default_lsystem())
	var nodes := []
	var wires := []
	nodes.append({ "id": "plant", "type": "LSystem", "params": ls })
	nodes.append({ "id": "place_plant", "type": "Transform", "params": { "position": cfg.get("plant_pos", [0.0, 0.0, 0.0]) } })
	wires.append({ "from": "plant", "out": "node", "to": "place_plant", "in": "node" })
	var ground := PartsCatalog.part_node("box", { "width": 10.0, "height": 0.2, "depth": 10.0 }, [0.0, 0.0, 0.0])
	nodes.append({ "id": "ground", "type": "Const", "params": { "value": ground } })
	nodes.append({ "id": "place_ground", "type": "Transform", "params": { "position": [0.0, -0.1, 0.0] } })
	wires.append({ "from": "ground", "out": "value", "to": "place_ground", "in": "node" })
	nodes.append({ "id": "scene", "type": "Group", "params": { "count": 2, "name": "lsystem_scene" } })
	wires.append({ "from": "place_plant", "out": "node", "to": "scene", "in": "in_0" })
	wires.append({ "from": "place_ground", "out": "node", "to": "scene", "in": "in_1" })
	var v: Dictionary = cfg.get("view", {})
	nodes.append({ "id": "view", "type": "View", "params": {
		"position": v.get("position", [4.2, 3.4, 5.6]),
		"look_at": v.get("look_at", [0.0, 2.0, 0.0]),
		"yfov": float(v.get("yfov", 55.0)),
	} })
	return { "format": "resonance.arrangement/v1", "name": "lsystem-example", "nodes": nodes, "wires": wires }

## The default plant: the classic two-rule bush (X branches four ways with yaw AND pitch so the plant
## is genuinely 3D; F doubles per pass; ! tapers each branch level).
func _default_lsystem() -> Dictionary:
	return {
		"axiom": "X",
		"rules": { "X": "F[!+X][!-X][!&X][!^X]FX", "F": "FF" },
		"depth": 4,
		"seed": 0,
		"turtle": { "step": 0.14, "angle_deg": 26.0, "radius": 0.05, "radius_decay": 0.72, "step_decay": 0.9 },
		"name": "bush",
	}

func _default_stack() -> Array:
	return [
		{ "type": "kuwahara",    "params": { "radius": 3 } },
		{ "type": "edge_darken", "params": { "strength": 0.85, "threshold": 0.10 } },
		{ "type": "posterize",   "params": { "levels": 14 } },
		{ "type": "paper_grain", "params": { "amount": 0.07, "scale": 5.0, "seed": 7 } },
	]

func _scale_stroke(stack: Array, factor: float) -> Array:
	if factor <= 1.001:
		return stack.duplicate(true)
	var out := []
	for layer in stack:
		if typeof(layer) != TYPE_DICTIONARY:
			continue
		var t := String(layer.get("type", "passthrough"))
		var p: Dictionary = (layer.get("params", {}) as Dictionary).duplicate(true)
		match t:
			"kuwahara", "generalized_kuwahara":
				p["radius"] = int(round(float(p.get("radius", 3)) * factor))
			_:
				pass
		out.append({ "type": t, "params": p })
	return out

func _default_params() -> Dictionary:
	return {
		"lsystem": _default_lsystem(),
		"plant_pos": [0.0, 0.0, 0.0],
		"detail_knob": 0.85,
		"falloff": { "type": "radial", "center": [0.5, 0.45], "radius": 0.85, "edge": 0.1, "curve": 2.0 },
		"coarsen": 1.0,
		"paint_width": 640,
		"effect_stack": _default_stack(),
		"sky": PainterlySky.default_descriptor(),
		"view": { "position": [4.2, 3.4, 5.6], "look_at": [0.0, 2.0, 0.0], "yfov": 55.0 },
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
	var layer := CanvasLayer.new()
	add_child(layer)
	_canvas = TextureRect.new()
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_canvas.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_canvas.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	layer.add_child(_canvas)

## Always-on iterable sky + clouds (the standing rule) — the same PainterlySky module + `sky` block.
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
