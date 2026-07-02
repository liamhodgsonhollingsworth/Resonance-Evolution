extends SceneTree
## HEADLESS TEST — MathPainting generators + the MathPaint primitive + the three committed demo
## arrangements. Pure CPU. Pins the DATA contract: determinism (same descriptor → byte-identical
## pixels; different seed → different pixels), geometric sanity (curve strokes stay inside the margin
## box; flow strokes actually paint; harmonic fields ink their nodal lines), and the end-to-end
## arrangement path (GraphRuntime → MathPaint → a saved PNG + reproducible sha256).
##
##   godot --headless --path godot -s res://headless_math_paint_test.gd

var _passed := 0
var _failed := 0

func _initialize() -> void:
	_test_determinism()
	_test_curve_bounds()
	_test_flow_paints()
	_test_harmonic_nodal()
	_test_arrangements_end_to_end()
	var verdict := "ALL PASS" if _failed == 0 else "FAILURES"
	print("\n[math_paint_test] RESULT: %s  (%d passed, %d failed)" % [verdict, _passed, _failed])
	quit(0 if _failed == 0 else 1)

func _check(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
		print("  ok   %s" % label)
	else:
		_failed += 1
		print("  FAIL %s" % label)

func _sha(img: Image) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(img.get_data())
	return ctx.finish().hex_encode()

# ── determinism ─────────────────────────────────────────────────────────────────────────────────────

func _test_determinism() -> void:
	var flow := { "generator": "flow_field", "width": 96, "height": 64, "seed": 7, "strokes": 60, "steps": 12 }
	var a := MathPainting.generate(flow)
	var b := MathPainting.generate(flow)
	_check(_sha(a) == _sha(b), "determinism: same descriptor → byte-identical pixels")
	var flow2 := flow.duplicate(true)
	flow2["seed"] = 8
	var c := MathPainting.generate(flow2)
	_check(_sha(a) != _sha(c), "determinism: a different seed → different pixels")
	var curve := { "generator": "parametric_curve", "curve": "lissajous", "width": 96, "height": 64, "samples": 400 }
	_check(_sha(MathPainting.generate(curve)) == _sha(MathPainting.generate(curve)),
		"determinism: parametric curve is seedless-deterministic")

# ── parametric curve: strokes stay inside the margin box ───────────────────────────────────────────

func _test_curve_bounds() -> void:
	var bg := [0.1, 0.1, 0.1]
	var cfg := { "generator": "parametric_curve", "curve": "lissajous", "a": 3, "b": 4,
		"width": 120, "height": 80, "samples": 800, "stroke_radius": 2, "margin": 0.1, "background": bg }
	var img := MathPainting.generate(cfg)
	var w := img.get_width()
	var h := img.get_height()
	var painted := 0
	var out_of_box := 0
	# the margin box, padded by the stroke radius
	var x0 := int(float(w) * 0.1) - 3
	var x1 := w - x0
	var y0 := int(float(h) * 0.1) - 3
	var y1 := h - y0
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			if absf(c.r - 0.1) > 0.02 or absf(c.g - 0.1) > 0.02 or absf(c.b - 0.1) > 0.02:
				painted += 1
				if x < x0 or x > x1 or y < y0 or y > y1:
					out_of_box += 1
	_check(painted > 200, "curve: the stroke actually paints (%d px)" % painted)
	_check(out_of_box == 0, "curve: every stroke pixel is inside the margin box (%d outside)" % out_of_box)

# ── flow field: strokes paint, and rose-vs-lissajous differ ────────────────────────────────────────

func _test_flow_paints() -> void:
	var cfg := { "generator": "flow_field", "width": 120, "height": 80, "seed": 21,
		"strokes": 150, "steps": 20, "background": [0.0, 0.0, 0.0] }
	var img := MathPainting.generate(cfg)
	var painted := 0
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).r + img.get_pixel(x, y).g + img.get_pixel(x, y).b > 0.05:
				painted += 1
	_check(painted > 400, "flow: streamline strokes paint the canvas (%d px)" % painted)
	var rose := MathPainting.generate({ "generator": "parametric_curve", "curve": "rose", "k": 5,
		"width": 120, "height": 80, "samples": 800 })
	var liss := MathPainting.generate({ "generator": "parametric_curve", "curve": "lissajous",
		"width": 120, "height": 80, "samples": 800 })
	_check(_sha(rose) != _sha(liss), "curve: rose and lissajous are distinct constructions")

# ── harmonic: nodal lines are inked, modes change the figure ───────────────────────────────────────

func _test_harmonic_nodal() -> void:
	var cfg := { "generator": "harmonic", "width": 96, "height": 96, "modes": [[3, 5, 1.0]],
		"ink": [0.0, 0.0, 0.0], "ink_eps": 0.04,
		"palette": [[0.0, 1.0, 1.0, 1.0], [1.0, 1.0, 1.0, 1.0]] }
	var img := MathPainting.generate(cfg)
	var dark := 0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.r < 0.25 and c.g < 0.25 and c.b < 0.25:
				dark += 1
	var total := img.get_width() * img.get_height()
	_check(dark > total / 50, "harmonic: nodal lines are inked (%d dark px)" % dark)
	_check(dark < total / 2, "harmonic: nodal ink is lines, not a flood (%d dark px)" % dark)
	var other := MathPainting.generate({ "generator": "harmonic", "width": 96, "height": 96,
		"modes": [[2, 7, 1.0]], "ink": [0.0, 0.0, 0.0], "ink_eps": 0.04,
		"palette": [[0.0, 1.0, 1.0, 1.0], [1.0, 1.0, 1.0, 1.0]] })
	_check(_sha(img) != _sha(other), "harmonic: different modes → a different figure")

# ── end to end: the committed arrangements evaluate through the real runtime ───────────────────────

func _test_arrangements_end_to_end() -> void:
	for path in ["res://examples/math_lissajous.arrangement.json",
			"res://examples/math_flow_field.arrangement.json",
			"res://examples/math_harmonic.arrangement.json"]:
		var data = JSON.parse_string(FileAccess.get_file_as_string(path))
		_check(typeof(data) == TYPE_DICTIONARY, "%s parses" % path.get_file())
		if typeof(data) != TYPE_DICTIONARY:
			continue
		var rt := GraphRuntime.new()
		get_root().add_child(rt)
		rt.load_arrangement(data)
		var outputs := rt.evaluate()
		var painted: Dictionary = outputs.get("paint", {}).get("painted", {})
		_check(bool(painted.get("ok", false)), "%s: MathPaint evaluated ok" % path.get_file())
		_check(FileAccess.file_exists(String(painted.get("path", ""))), "%s: PNG exists on disk" % path.get_file())
		_check(String(painted.get("sha256", "")).length() == 64, "%s: descriptor carries a sha256" % path.get_file())
		rt.queue_free()
