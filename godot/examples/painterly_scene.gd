extends Node3D
## OPENABLE PAINTERLY EXAMPLE — a small 3D scene built from CATALOG PARTS, PAINTED with a painterly
## effect stack whose brush detail VARIES ACROSS THE FRAME by a single detail-knob + a generic falloff
## curve (Liam's project-generic-detail-falloff-2026-07-01 spec, first instantiation = the painterly
## engine). It reuses the merged engine systems end to end — the PartsCatalog (13-shape vocabulary),
## the GodotSceneRenderer delegate (renderer-neutral scene_node DATA → live 3D), the View primitive
## (camera-as-DATA), and EffectStackCpu (the proven painterly applier) — and adds ONLY the thin new
## detail-field seam (renderers/detail_field.gd + renderers/painterly_falloff.gd). No foundation edit.
##
## ── HOW TO OPEN + ITERATE ────────────────────────────────────────────────────────────────────────
##   Windowed, writes a painted proof PNG then quits:
##     <Godot> --path godot res://examples/painterly_scene.tscn -- --shot
##   Live (stays open, HOT-RELOADS): edit godot/examples/painterly_params.json and SAVE — the scene +
##   the detail knob + the falloff curve re-render live, NO restart (the live_demo watcher pattern):
##     <Godot> --path godot res://examples/painterly_scene.tscn
##   (<Godot> = C:\Users\Liam\godot\Godot_v4.6.3-stable_win64_console.exe.)
##
##   THE ONE FILE LIAM EDITS TO ITERATE:  godot/examples/painterly_params.json
##     detail_knob : 0..1  — the SINGLE slider. Turn it up → more/finer painterly detail budget overall.
##     falloff     : the generic curve that shapes WHERE detail is high across the frame. Pick one:
##                     {"type":"radial","center":[0.5,0.45],"radius":0.85,"edge":0.1,"curve":2.0}
##                     {"type":"vertical","top":1.0,"bottom":0.1,"curve":1.5}
##                     {"type":"horizontal","left":1.0,"right":0.1,"curve":1.0}
##                     {"type":"uniform"}   (no falloff — detail flat over the frame; the control case)
##     coarsen     : 0..1  — how coarse the LOW-detail periphery gets vs the high-detail focus (default 1).
##     scene       : the arrangement of catalog PARTS (name + optional param overrides + position).
##     effect_stack: the painterly layers (the same {type,params} the evolver breeds). Reorder/tune freely.
##     view        : the camera (position / look_at / yfov), camera-as-DATA.
##   Every re-save re-runs render(scene) → paint(detail_knob × falloff) → the live frame updates.
##
## THE DETAIL KNOB + FALLOFF, concretely: DetailField.build(w,h,detail_knob,falloff) makes a per-pixel
## budget field d(x,y) = knob × falloff(x,y). PainterlyFalloff.paint renders the effect stack fine AND
## coarse, then blends per pixel by d — so where d≈1 the paint is fine/dense and where d≈0 it is coarse.
## The FIELD is the durable seam (the Truncate/foveation node plugs the same field into LOD/procgen later);
## the two-pass blend is the simple first algorithm behind it. Turn the knob or swap the curve → the whole
## painted frame re-budgets. The seam LATER wires to camera distance / gaze (foveation) unchanged.

const PARAMS_PATH := "res://examples/painterly_params.json"          # the file Liam edits to iterate
const SHOT_RAW := "res://live/painterly_example_raw.png"             # the un-painted 3D frame (gitignored live/)
const SHOT_PAINTED := "res://live/painterly_example.png"             # the painted proof frame (gitignored live/)
const SHOT_FIELD := "res://live/painterly_example_field.png"         # the detail field itself (debug view)

var runtime: GraphRuntime
var renderer: GodotSceneRenderer
var _sub: SubViewport                                                # the offscreen 3D render target we paint from
var _canvas: TextureRect                                             # the on-window painted result (what Liam sees live)
var _params_mtime := -1
var _did_shot := false

var _busy := false                                                  # guards against overlapping reloads

func _ready() -> void:
	_build_ui()
	runtime = GraphRuntime.new()
	add_child(runtime)
	renderer = GodotSceneRenderer.new()
	_sub.add_child(renderer)                                         # render the 3D scene INTO the SubViewport
	# Ensure the seed params file exists (and its mtime is recorded) BEFORE the watcher runs, so the
	# first-run write does not immediately re-trigger a reload every frame.
	_load_params()
	_params_mtime = _mtime(PARAMS_PATH)
	await _reload()                                                  # first build from the params file (or defaults)

func _process(_delta: float) -> void:
	# HOT-RELOAD watcher (the live_demo pattern): if the params file changed on disk, re-render live.
	if _busy:
		return
	var m := _mtime(PARAMS_PATH)
	if m != _params_mtime:
		_params_mtime = m
		await _reload()

# ── the live pipeline: (re)build the scene from DATA, render it, then PAINT it by the detail field ──

func _reload() -> void:
	_busy = true
	_params_mtime = _mtime(PARAMS_PATH)
	var cfg := _load_params()
	# 0) Rebuild the SKY module from the params' `sky` block so a sky/cloud edit re-renders live, in
	#    parallel with (and independent of) the scene + the painterly renderer.
	_build_env(_sub, cfg)
	# 1) Assemble the renderer-neutral arrangement (catalog parts → Group + a View), evaluate to DATA,
	#    and let the GodotSceneRenderer delegate build the live 3D scene inside the SubViewport.
	runtime.load_arrangement(_arrangement(cfg))
	var eval_output := runtime.evaluate()
	renderer.render(eval_output, runtime.arrangement)
	renderer.apply_view(eval_output, runtime.arrangement, _sub)
	# 2) After a couple of frames (so the SubViewport has drawn), grab the raw frame and paint it.
	await _paint_when_ready(cfg)

func _paint_when_ready(cfg: Dictionary) -> void:
	# Let the offscreen viewport render the freshly-wired scene before we read its pixels.
	for _i in 3:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var raw := _sub.get_texture().get_image()
	# Downscale to a CPU-paint-friendly resolution BEFORE the painterly passes. The painterly applier is
	# per-pixel neighbourhood math in GDScript (Kuwahara is O(pixels × radius²)) — a full-res 768×512 pass
	# is minutes; the painted look is a low-frequency effect, so a ~paint_width-wide frame is both fast and
	# visually identical once shown at window scale. `paint_width` is a tunable in the params file.
	# Paint at a MUCH higher resolution than before (640 vs 320) so the painterly look reads as crisp
	# brushwork, not square pixel blocks — the old 320px frame upscaled to the window WAS the pixelation.
	# Kuwahara is O(pixels × radius²); 640px is ~4× the pixels of 320 but still a fast background paint.
	var paint_w := int(cfg.get("paint_width", 640))
	if raw.get_width() > paint_w:
		var ph := int(round(float(paint_w) * float(raw.get_height()) / float(raw.get_width())))
		raw.resize(paint_w, ph, Image.INTERPOLATE_BILINEAR)
	raw.convert(Image.FORMAT_RGBAF)
	# 3) THE SPEC: paint the frame with the effect stack, VARYING the brush detail by the single
	#    detail-knob × the generic falloff curve. This is the whole point of the example.
	# Scale the brush KERNEL to the paint resolution so "coarse" means LARGER BRUSH STROKES, not bigger
	# blocks: a Kuwahara radius authored for ~320px is doubled at 640px, keeping the stroke's on-screen
	# size constant as resolution rises (the crisp-painterly, not pixelated, requirement).
	var stroke_scale := clampf(float(paint_w) / 320.0, 1.0, 4.0)
	var stack := { "stack": _scale_stroke(cfg.get("effect_stack", _default_stack()), stroke_scale) }
	var knob := float(cfg.get("detail_knob", 0.85))
	var falloff: Dictionary = cfg.get("falloff", { "type": "radial" })
	var coarsen := float(cfg.get("coarsen", 1.0))
	var painted := PainterlyFalloff.paint(raw, stack, knob, falloff, coarsen)
	# 4) Show the painted result on the window (so a live edit is visible immediately).
	var tex := ImageTexture.create_from_image(painted)
	_canvas.texture = tex
	_busy = false
	print("[painterly_example] rendered %d node(s); knob=%.2f falloff=%s coarsen=%.2f" % [
		runtime.nodes.size(), knob, String(falloff.get("type", "uniform")), coarsen])
	# 5) --shot: write the proof PNGs (raw + painted + the field itself), once, then quit.
	if _shot_requested() and not _did_shot:
		_did_shot = true
		DirAccess.make_dir_recursive_absolute("res://live")
		raw.convert(Image.FORMAT_RGBA8)
		raw.save_png(SHOT_RAW)
		painted.save_png(SHOT_PAINTED)
		var w := painted.get_width()
		var h := painted.get_height()
		var field := DetailField.build(w, h, knob, falloff)
		var dbg := DetailField.to_debug_image(field, w, h)
		dbg.convert(Image.FORMAT_RGBA8)
		dbg.save_png(SHOT_FIELD)
		print("[painterly_example] proof: %s (painted), %s (raw), %s (field)" % [SHOT_PAINTED, SHOT_RAW, SHOT_FIELD])
		get_tree().quit(0)

# ── the scene as DATA: catalog PARTS composed into a Group, plus a View (camera-as-DATA) ────────────

## Build the RE-native arrangement ({nodes, wires}) from the params config. Each scene entry names a
## catalog part; PartsCatalog.part_node emits its renderer-neutral primitive scene_node (mesh:{source:
## "primitive", shape, params}), which a Const node carries onto a wire, a Transform places, and one
## Group combines — the SAME Const→Transform→Group pattern render_view / live_demo use, so the catalog
## part flows through unchanged (no new primitive: Const passes the pre-built scene_node through as DATA,
## and the delegate builds primitive meshes straight from the descriptor it finds on the Group's roots).
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
		# Emit the catalog scene_node at the ORIGIN (pos [0,0,0]); the Transform below places it, so the
		# position is set once (a Transform overwrites `translation`, so baking pos here would double it).
		var desc := PartsCatalog.part_node(part_name, overrides, [0.0, 0.0, 0.0])
		if desc.is_empty():
			push_warning("[painterly_example] unknown catalog part '%s' (skipped)" % part_name)
			continue
		# A Const node carries the pre-built catalog scene_node onto a wire (Const passes params.value
		# through verbatim); a Transform places it; the Group combines all placed parts. No new primitive.
		var cid := "part_%d" % idx
		var tid := "place_%d" % idx
		nodes.append({ "id": cid, "type": "Const", "params": { "value": desc } })
		nodes.append({ "id": tid, "type": "Transform", "params": { "position": pos } })
		wires.append({ "from": cid, "out": "value", "to": tid, "in": "node" })
		group_ins.append(tid)
		idx += 1
	nodes.append({ "id": "scene", "type": "Group", "params": { "count": group_ins.size(), "name": "painterly_scene" } })
	for j in group_ins.size():
		wires.append({ "from": group_ins[j], "out": "node", "to": "scene", "in": "in_%d" % j })
	# The View (camera-as-DATA) — placement + aim + fov from the params file.
	var v: Dictionary = cfg.get("view", {})
	nodes.append({ "id": "view", "type": "View", "params": {
		"position": v.get("position", [4.5, 3.5, 6.5]),
		"look_at": v.get("look_at", [0.0, 0.8, 0.0]),
		"yfov": float(v.get("yfov", 55.0)),
	} })
	return { "format": "resonance.arrangement/v1", "name": "painterly-example", "nodes": nodes, "wires": wires }

## The default scene when painterly_params.json is absent: a small courtyard — an arch gateway, a
## staircase, and a few shapes — so the example is meaningful out of the box (and re-writes the params
## file so Liam has a starting point to edit).
func _default_scene() -> Array:
	return [
		{ "part": "arch",     "params": { "width": 3.0, "height": 3.0, "depth": 0.6 }, "pos": [0.0, 0.0, -1.5] },
		{ "part": "stairs",   "params": { "width": 1.6, "total_height": 1.2, "total_depth": 2.0, "steps": 6 }, "pos": [0.0, 0.0, 0.6] },
		{ "part": "cylinder", "params": { "radius": 0.35, "height": 2.4 }, "pos": [-2.2, 1.2, -1.5] },
		{ "part": "cylinder", "params": { "radius": 0.35, "height": 2.4 }, "pos": [2.2, 1.2, -1.5] },
		{ "part": "sphere",   "params": { "radius": 0.6 }, "pos": [-2.2, 2.7, -1.5] },
		{ "part": "torus",    "params": { "inner_radius": 0.25, "outer_radius": 0.55 }, "pos": [2.2, 2.7, -1.5] },
		{ "part": "cone",     "params": { "radius": 0.7, "height": 1.2 }, "pos": [0.0, 3.2, -1.5] },
		{ "part": "box",      "params": { "width": 8.0, "height": 0.2, "depth": 8.0 }, "pos": [0.0, -0.1, 0.0] },
	]

func _default_stack() -> Array:
	# A painterly stack: Kuwahara flatten (oil-brush) → edge pooling → posterize → paper grain. Radii are
	# authored for ~320px and scaled up to the actual paint resolution by _scale_stroke (crisp strokes).
	# posterize levels kept HIGH (14) so near-flat regions (sky, ground) do NOT band into visible blocks —
	# posterize banding on low-detail areas was a second source of the "pixelated" look; more levels =
	# smooth tonal ramps there while the Kuwahara still gives the brush-flattened oil look on the shapes.
	return [
		{ "type": "kuwahara",    "params": { "radius": 3 } },
		{ "type": "edge_darken", "params": { "strength": 0.85, "threshold": 0.10 } },
		{ "type": "posterize",   "params": { "levels": 14 } },
		{ "type": "paper_grain", "params": { "amount": 0.07, "scale": 5.0, "seed": 7 } },
	]

## Scale the brush-KERNEL params of an effect stack to the paint resolution so a stroke keeps a constant
## ON-SCREEN size as resolution rises: a Kuwahara/generalized-Kuwahara `radius` authored for ~320px is
## multiplied by `factor` (paint_width / 320). This is what makes the higher-res paint read as crisp
## brushwork instead of tiny strokes — "coarse" then genuinely means a WIDER BRUSH, not a bigger pixel.
## NOTE: `paper_grain.scale` (the noise CELL size) is deliberately NOT scaled up — enlarging the grain
## cells is exactly what turned FLAT regions (sky, ground) into visible square blocks. Keeping the grain
## cell small means the paper texture stays a fine tooth over the whole frame, not a checkerboard on flats.
## Pure DATA→DATA; effects with no kernel size pass through unchanged.
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
				pass  # paper_grain.scale intentionally left at its authored (fine) cell size — see above
		out.append({ "type": t, "params": p })
	return out

## The full default params config, also WRITTEN to disk on first run so Liam has an editable seed file.
func _default_params() -> Dictionary:
	return {
		"detail_knob": 0.85,
		"falloff": { "type": "radial", "center": [0.5, 0.45], "radius": 0.85, "edge": 0.1, "curve": 2.0 },
		"coarsen": 1.0,
		"paint_width": 640,
		"scene": _default_scene(),
		"effect_stack": _default_stack(),
		# The SKY is its OWN wired module (renderers/sky.gd + renderers/clouds.gd) with its OWN params, so
		# Liam iterates the sky + clouds in PARALLEL with the scene + the painterly renderer. Every key here
		# hot-reloads: edit a color / the sun angle / cloud coverage and only the environment re-renders.
		"sky": PainterlySky.default_descriptor(),
		# Aim a little higher (look_at y=1.6) so the always-on sky + clouds read clearly in the top of frame.
		"view": { "position": [4.5, 3.8, 6.8], "look_at": [0.0, 1.6, 0.0], "yfov": 55.0 },
	}

func _load_params() -> Dictionary:
	if FileAccess.file_exists(PARAMS_PATH):
		var data = JSON.parse_string(FileAccess.get_file_as_string(PARAMS_PATH))
		if typeof(data) == TYPE_DICTIONARY:
			return data
	# First run (or missing/invalid): write the seed file so Liam has something to edit, and use it.
	var cfg := _default_params()
	var f := FileAccess.open(PARAMS_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(cfg, "\t"))
		f.close()
	return cfg

# ── window / offscreen viewport / environment ──────────────────────────────────────────────────────

func _build_ui() -> void:
	# The offscreen 3D render target we paint from. Rendered at HIGH resolution with MSAA so the geometry
	# feeding the paint is crisp + anti-aliased (jagged geometry edges were half the "pixelated" look).
	_sub = SubViewport.new()
	_sub.size = Vector2i(1280, 854)                                  # ~1.6x the old 768×512: crisp base frame
	_sub.msaa_3d = Viewport.MSAA_4X                                  # 4× MSAA → no stair-step geometry edges
	_sub.transparent_bg = false
	_sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_sub)
	# The sky/sun are their OWN wired module (renderers/sky.gd) mounted here, so they iterate in parallel
	# with the scene + the painterly renderer. _build_env reads the `sky` block of the params on reload.
	_build_env(_sub, _load_params())
	# The on-window canvas that shows the PAINTED frame (so live edits are visible immediately). LINEAR
	# texture filtering so the painted frame is smoothed (not nearest-neighbour-blocked) when the window
	# scales it — combined with the much higher paint_width this removes the square-pixel look entirely.
	var layer := CanvasLayer.new()
	add_child(layer)
	_canvas = TextureRect.new()
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_canvas.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_canvas.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR       # smooth upscale, no blocky pixels
	layer.add_child(_canvas)

## Build the environment for the render viewport from the `sky` block of the params. The SKY is a SEPARATE
## wired module (PainterlySky.build → an Environment + a sun DirectionalLight3D driven from the same sky
## descriptor); it replaces the old flat BG_COLOR backdrop with a procedural sky + clouds that Liam tunes
## independently via `sky` in painterly_params.json. Rebuilt on every reload so a sky edit re-renders live.
func _build_env(into: Node, cfg: Dictionary = {}) -> void:
	# Clear any previous env/sun so a hot-reload of the sky block RE-BUILDS (not stacks) the environment.
	for c in into.get_children():
		if c is WorldEnvironment or c is DirectionalLight3D:
			c.queue_free()
	var sky_desc: Dictionary = cfg.get("sky", PainterlySky.default_descriptor())
	var built := PainterlySky.build(sky_desc)
	var env_node := WorldEnvironment.new()
	env_node.environment = built["environment"]
	into.add_child(env_node)
	into.add_child(built["sun"])

func _shot_requested() -> bool:
	return "--shot" in OS.get_cmdline_user_args() or "--shot" in OS.get_cmdline_args()

func _mtime(path: String) -> int:
	var abs := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(path):
		return -1
	return int(FileAccess.get_modified_time(abs))
