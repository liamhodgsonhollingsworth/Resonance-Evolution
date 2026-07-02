extends SceneTree
## HEADLESS TEST — FocusField (camera focus / depth-of-field as a detail field).
## Pure CPU (no GPU, no scene render): a synthetic depth RAMP + a checkerboard source stand in for the
## captured frames, and the assertions pin the DATA contract: the focus response peaks at the focal
## plane, the detail_knob composes multiplicatively (knob=0 → everything out of focus), the blur pole
## genuinely blurs, the blend honors the field at both poles, and — the demo's core promise — moving
## `focal_distance` MOVES the sharp band across the frame.
##
##   godot --headless --path godot -s res://headless_focus_test.gd

var _passed := 0
var _failed := 0

func _init() -> void:
	_test_response_curve()
	_test_field_build_and_knob()
	_test_blur_pole()
	_test_blend_poles()
	_test_focus_shift_moves_sharp_band()
	_test_focal_depth_widens_band()
	var verdict := "ALL PASS" if _failed == 0 else "FAILURES"
	print("\n[focus_test] RESULT: %s  (%d passed, %d failed)" % [verdict, _passed, _failed])
	quit(0 if _failed == 0 else 1)

func _check(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
		print("  ok   %s" % label)
	else:
		_failed += 1
		print("  FAIL %s" % label)

# ── the response curve ───────────────────────────────────────────────────────────────────────────────

func _test_response_curve() -> void:
	_check(is_equal_approx(FocusField.response(6.0, 6.0, 2.0), 1.0), "response: exactly 1 on the focal plane")
	_check(is_equal_approx(FocusField.response(6.0 + 0.4 * 2.0, 6.0, 2.0), 1.0), "response: full-sharp plateau inside 0.5×focal_depth")
	_check(is_equal_approx(FocusField.response(6.0 + 1.6 * 2.0, 6.0, 2.0), 0.0), "response: zero beyond 1.5×focal_depth")
	var near_r := FocusField.response(6.8, 6.0, 2.0)
	var far_r := FocusField.response(8.0, 6.0, 2.0)
	_check(near_r > far_r, "response: monotone falloff with |depth-focal| (%.3f > %.3f)" % [near_r, far_r])
	_check(is_equal_approx(FocusField.response(4.0, 6.0, 2.0), FocusField.response(8.0, 6.0, 2.0)),
		"response: symmetric front/back of the focal plane")

# ── field build + the composing detail knob ──────────────────────────────────────────────────────────

func _depth_ramp(w: int, h: int) -> Image:
	# gray 0 → 1 left → right: depth spans depth_range across the frame width.
	var img := Image.create(w, h, false, Image.FORMAT_RGBAF)
	for y in h:
		for x in w:
			var g := float(x) / float(w - 1)
			img.set_pixel(x, y, Color(g, g, g, 1.0))
	return img

func _test_field_build_and_knob() -> void:
	var w := 64
	var h := 8
	var depth := _depth_ramp(w, h)
	var focus := { "focal_distance": 5.0, "focal_depth": 2.0, "depth_range": [0.0, 10.0] }
	var full := FocusField.build(depth, 1.0, focus)
	_check(full.size() == w * h, "build: field is w*h")
	# focal_distance 5.0 over range [0,10] = the middle column; edges are far from focus.
	var mid := full[w / 2]
	var left := full[0]
	var right := full[w - 1]
	_check(mid > 0.99, "build: field ≈ 1 at the focal plane (got %.3f)" % mid)
	_check(left < 0.01 and right < 0.01, "build: field ≈ 0 far from the focal plane")
	var half := FocusField.build(depth, 0.5, focus)
	_check(absf(half[w / 2] - 0.5 * full[w / 2]) < 0.001, "build: detail_knob composes multiplicatively (0.5×)")
	var zero := FocusField.build(depth, 0.0, focus)
	var all_zero := true
	for v in zero:
		if v > 0.0001:
			all_zero = false
			break
	_check(all_zero, "build: knob=0 → the whole frame gets zero detail budget")

# ── the blur pole ────────────────────────────────────────────────────────────────────────────────────

func _checker(w: int, h: int, cell: int = 2) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGBAF)
	for y in h:
		for x in w:
			var on := (int(x / float(cell)) + int(y / float(cell))) % 2 == 0
			var v := 1.0 if on else 0.0
			img.set_pixel(x, y, Color(v, v, v, 1.0))
	return img

func _local_contrast(img: Image, x0: int, x1: int) -> float:
	# mean |Δ| between horizontal neighbours in the column band [x0, x1) — sharpness proxy.
	var acc := 0.0
	var n := 0
	for y in img.get_height():
		for x in range(x0, x1 - 1):
			acc += absf(img.get_pixel(x + 1, y).r - img.get_pixel(x, y).r)
			n += 1
	return acc / float(maxi(1, n))

func _test_blur_pole() -> void:
	var src := _checker(32, 16)
	var flat := Image.create(32, 16, false, Image.FORMAT_RGBAF)
	flat.fill(Color(0.5, 0.5, 0.5, 1.0))
	var fb := FocusField.blur(flat, 4)
	var flat_ok := true
	for y in 16:
		for x in 32:
			if absf(fb.get_pixel(x, y).r - 0.5) > 0.001:
				flat_ok = false
	_check(flat_ok, "blur: a constant image is unchanged")
	var c_src := _local_contrast(src, 0, 32)
	var b1 := FocusField.blur(src, 2)
	var c_b1 := _local_contrast(b1, 0, 32)
	var b2 := FocusField.blur(src, 5)
	var c_b2 := _local_contrast(b2, 0, 32)
	_check(c_b1 < c_src, "blur: reduces local contrast (%.3f < %.3f)" % [c_b1, c_src])
	_check(c_b2 < c_b1, "blur: a larger radius blurs more (%.3f < %.3f)" % [c_b2, c_b1])
	_check(FocusField.blur(src, 0).get_pixel(3, 3).r == src.get_pixel(3, 3).r, "blur: radius 0 is identity")

# ── the blend poles ──────────────────────────────────────────────────────────────────────────────────

func _test_blend_poles() -> void:
	var sharp := _checker(16, 8)
	var blurred := FocusField.blur(sharp, 3)
	var ones := PackedFloat32Array()
	ones.resize(16 * 8)
	ones.fill(1.0)
	var zeros := PackedFloat32Array()
	zeros.resize(16 * 8)
	zeros.fill(0.0)
	var as_sharp := FocusField.blend(sharp, blurred, ones)
	var as_blur := FocusField.blend(sharp, blurred, zeros)
	_check(absf(as_sharp.get_pixel(5, 3).r - sharp.get_pixel(5, 3).r) < 0.001, "blend: field=1 returns the sharp pole")
	_check(absf(as_blur.get_pixel(5, 3).r - blurred.get_pixel(5, 3).r) < 0.001, "blend: field=0 returns the blurred pole")

# ── the demo's core promise: focal_distance MOVES the sharp band ─────────────────────────────────────

func _test_focus_shift_moves_sharp_band() -> void:
	var w := 96
	var h := 16
	var src := _checker(w, h)
	var depth := _depth_ramp(w, h)
	# NEAR focus: focal plane at depth 2 over range [0,10] → the LEFT fifth of the ramp is sharp.
	var near_cfg := { "detail_knob": 1.0, "blur_radius": 4,
		"focus": { "focal_distance": 2.0, "focal_depth": 1.5, "depth_range": [0.0, 10.0] } }
	# FAR focus: focal plane at depth 8 → the RIGHT fifth is sharp.
	var far_cfg := { "detail_knob": 1.0, "blur_radius": 4,
		"focus": { "focal_distance": 8.0, "focal_depth": 1.5, "depth_range": [0.0, 10.0] } }
	var near_img := FocusField.paint(src, depth, near_cfg)
	var far_img := FocusField.paint(src, depth, far_cfg)
	# contrast bands: left fifth [0, w/5) vs right fifth [4w/5, w)
	var near_left := _local_contrast(near_img, 0, w / 5)
	var near_right := _local_contrast(near_img, 4 * w / 5, w)
	var far_left := _local_contrast(far_img, 0, w / 5)
	var far_right := _local_contrast(far_img, 4 * w / 5, w)
	_check(near_left > 2.0 * near_right, "focus shift: NEAR focus → left band sharp, right blurred (%.3f vs %.3f)" % [near_left, near_right])
	_check(far_right > 2.0 * far_left, "focus shift: FAR focus → right band sharp, left blurred (%.3f vs %.3f)" % [far_right, far_left])
	# and the knob composes end-to-end: knob=0 → the focal band is as blurred as everywhere else.
	var dead_cfg := near_cfg.duplicate(true)
	dead_cfg["detail_knob"] = 0.0
	var dead := FocusField.paint(src, depth, dead_cfg)
	var dead_left := _local_contrast(dead, 0, w / 5)
	var blurred_ref := _local_contrast(FocusField.blur(src, 4), 0, w / 5)
	_check(absf(dead_left - blurred_ref) < 0.005, "focus shift: knob=0 → even the focal band is out of focus")

func _test_focal_depth_widens_band() -> void:
	var w := 96
	var h := 4
	var depth := _depth_ramp(w, h)
	var thin := FocusField.build(depth, 1.0, { "focal_distance": 5.0, "focal_depth": 1.0, "depth_range": [0.0, 10.0] })
	var wide := FocusField.build(depth, 1.0, { "focal_distance": 5.0, "focal_depth": 3.0, "depth_range": [0.0, 10.0] })
	var thin_n := 0
	var wide_n := 0
	for v in thin:
		if v > 0.9:
			thin_n += 1
	for v in wide:
		if v > 0.9:
			wide_n += 1
	_check(wide_n > thin_n, "focal_depth: a deeper focal band keeps more pixels sharp (%d > %d)" % [wide_n, thin_n])
