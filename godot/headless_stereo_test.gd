extends SceneTree
## Headless verification of the stereogram + VR-viewer foundation — ONE viewing-geometry
## parameter set (distance / IPD / focal plane / depth budget / DPI) driving depth map,
## autostereogram (SIRDS), stereo pair, anaglyph, and the live/VR camera rig.
##
##   godot --headless --path godot -s res://headless_stereo_test.gd
##
## The proof is DECODER-based: the stereogram's repeat period and the pair's pixel disparity
## are measured back out of the produced images (including reloaded PNG files) and checked
## against the closed-form geometry — hand-computed literals, not round-trips through the
## same code. See notes/design/stereogram_vr_viewer_2026-07-02.md.

const D := 0.6          # screen_distance_m used throughout
const E := 0.063        # ipd_m
const WM := 0.52        # screen_width_m

var _ok := true

func _initialize() -> void:
	var t0 := Time.get_ticks_msec()

	# --- (1) formula anchors: hand-computed literals -----------------------------------------
	# ppm = 960/0.52 = 1846.1538…; e·ppm = 116.3077…
	var geo_p := PrimStereoRender.derive({
		"screen_distance_m": D, "ipd_m": E, "screen_width_m": WM,
		"image_width_px": 960, "image_height_px": 120,
		"viewing": "parallel", "display_near_m": 0.9, "display_far_m": 2.0 })
	_check("derive: ppm == 1846.154 (960 px over 0.52 m)", absf(float(geo_p["ppm"]) - 1846.1538) < 0.01)
	_check("derive: parallel budget behind the screen is valid", bool(geo_p["valid"]))
	_check("anchor: parallel s(0.9 m) == 38.769 px (= 116.308·0.3/0.9)",
		absf(PrimStereoRender.separation_px(geo_p, 0.9) - 38.7692) < 0.01)
	_check("anchor: parallel s(2.0 m) == 81.415 px (= 116.308·1.4/2.0)",
		absf(PrimStereoRender.separation_px(geo_p, 2.0) - 81.4154) < 0.01)
	_check("anchor: v=0.5 maps to Z=1.24138 m (linear in 1/Z)",
		absf(PrimStereoRender.depth_to_display_z(geo_p, 0.5) - 1.2413793) < 1e-4)

	var geo_c := PrimStereoRender.derive({
		"screen_distance_m": D, "ipd_m": E, "screen_width_m": WM,
		"image_width_px": 960, "image_height_px": 120,
		"viewing": "cross", "display_near_m": 0.40, "display_far_m": 0.54 })
	_check("derive: cross budget in front of the screen is valid", bool(geo_c["valid"]))
	_check("anchor: cross s(0.40 m) == 58.154 px (= 116.308·0.2/0.4)",
		absf(PrimStereoRender.separation_px(geo_c, 0.40) - 58.1538) < 0.01)
	_check("anchor: cross s(0.54 m) == 12.923 px (= 116.308·0.06/0.54)",
		absf(PrimStereoRender.separation_px(geo_c, 0.54) - 12.9231) < 0.01)
	_check("anchor: pair disparity d(0.45 m) == +38.769 px (crossed, near)",
		absf(PrimStereoRender.pair_disparity_px(geo_c, 0.45) - 38.7692) < 0.01)
	_check("anchor: pair disparity d(1.2 m) == −58.154 px (uncrossed, far)",
		absf(PrimStereoRender.pair_disparity_px(geo_c, 1.2) - (-58.1538)) < 0.01)

	# Validation: budget on the wrong side of the screen must be rejected.
	var bad := PrimStereoRender.derive({ "viewing": "cross", "display_near_m": 0.7, "display_far_m": 0.9 })
	_check("derive: cross budget behind the screen is INVALID", not bool(bad["valid"]))
	var bad2 := PrimStereoRender.derive({ "viewing": "parallel", "display_near_m": 0.4, "display_far_m": 0.5 })
	_check("derive: parallel budget in front of the screen is INVALID", not bool(bad2["valid"]))

	# --- (2) depth map: sphere dead-centre reads Z−r exactly; misses read far ----------------
	var geo_d := PrimStereoRender.derive({
		"screen_distance_m": D, "ipd_m": E, "screen_width_m": WM,
		"image_width_px": 320, "image_height_px": 200,
		"viewing": "parallel", "display_near_m": 0.9, "display_far_m": 2.0,
		"scene_near_m": 1.3, "scene_far_m": 1.7 })
	var sph_scene := _sphere_node([0.0, 0.0, -1.5], 0.2, [1, 1, 1])
	var shapes: Array = PrimStereoRender.collect_shapes(sph_scene)["shapes"]
	_check("collect_shapes found the analytic sphere", shapes.size() == 1)
	var zbuf := PrimStereoRender.render_depth(shapes, geo_d)
	var zc := zbuf[100 * 320 + 160]
	_check("depth at centre pixel == 1.30 m (sphere front = Z − r)", absf(zc - 1.30) < 1e-3)
	_check("depth at corner == miss (INF)", zbuf[0] == INF)
	var vb := PrimStereoRender.normalize_depth(zbuf, geo_d, PrimStereoRender.depth_stats(zbuf))
	_check("normalized: centre == 1.0 (nearest), corner == 0.0 (far)",
		absf(vb[100 * 320 + 160] - 1.0) < 1e-4 and vb[0] == 0.0)

	# --- (3) SIRDS decoder, PARALLEL mode: 4 constant-depth bands ------------------------------
	# v = [0, 0.25, 0.5, 1.0] → expected periods [81, 71, 60, 39] px (hand-computed).
	print("[stereo_test] SIRDS bands (parallel)… %d ms" % (Time.get_ticks_msec() - t0))
	_bands_case(geo_p, [0.0, 0.25, 0.5, 1.0], [81, 71, 60, 39], "parallel", "res://live/stereo/bands_parallel.png")

	# --- (4) SIRDS decoder, CROSS mode: same bands, inverted relation --------------------------
	# v = [0, 0.25, 0.5, 1.0] → expected periods [13, 24, 36, 58] px (near ⇒ LARGER, inverted).
	_bands_case(geo_c, [0.0, 0.25, 0.5, 1.0], [13, 24, 36, 58], "cross", "res://live/stereo/bands_cross.png")

	# --- (5) stereo pair decoder: white sphere at 3 depths, centroid disparity ----------------
	print("[stereo_test] stereo pair decode… %d ms" % (Time.get_ticks_msec() - t0))
	var geo_pair := PrimStereoRender.derive({
		"screen_distance_m": D, "ipd_m": E, "screen_width_m": WM,
		"image_width_px": 480, "image_height_px": 300,
		"viewing": "cross", "display_near_m": 0.40, "display_far_m": 0.54 })
	# ppm = 923.077; e·ppm = 58.154.
	_pair_case(geo_pair, 0.45, 0.020, 19.3846, "near sphere (0.45 m): d == +19.385 px (crossed)")
	_pair_case(geo_pair, 0.60, 0.025, 0.0, "focal-plane sphere (0.60 m): d == 0 px (zero parallax)")
	_pair_case(geo_pair, 1.20, 0.050, -29.0769, "far sphere (1.20 m): d == −29.077 px (uncrossed)")

	# --- (6) anaglyph: exact channel compose from the two eye renders --------------------------
	var sc := _sphere_node([0.0, 0.0, -0.6], 0.1, [0.8, 0.6, 0.4])
	var shp: Array = PrimStereoRender.collect_shapes(sc)["shapes"]
	var style := { "background": [0.1, 0.2, 0.3] }
	var lft := PrimStereoRender.render_eye(shp, geo_pair, -E / 2.0, style)
	var rgt := PrimStereoRender.render_eye(shp, geo_pair, E / 2.0, style)
	var ana := PrimStereoRender.anaglyph(lft, rgt)
	var ana_ok := true
	for pt in [Vector2i(240, 150), Vector2i(10, 10), Vector2i(300, 200), Vector2i(255, 140)]:
		var a := ana.get_pixel(pt.x, pt.y)
		var l := lft.get_pixel(pt.x, pt.y)
		var r := rgt.get_pixel(pt.x, pt.y)
		ana_ok = ana_ok and _c8(a.r) == _c8(l.r) and _c8(a.g) == _c8(r.g) and _c8(a.b) == _c8(r.b)
	_check("anaglyph: R channel == left eye, G/B channels == right eye (exact)", ana_ok)

	# --- (7) StereoRig: the SAME dict drives the live off-axis camera pair ---------------------
	var geo_demo := { "screen_distance_m": D, "ipd_m": E, "screen_width_m": WM,
		"image_width_px": 960, "image_height_px": 600,
		"viewing": "cross", "display_near_m": 0.40, "display_far_m": 0.54, "znear_m": 0.05, "zfar_m": 100.0 }
	var eyes := StereoRig.eye_descriptors(geo_demo)
	# H_m = 600/1846.154 = 0.325; size = 0.325·0.05/0.6 = 0.0270833; offset = ±0.0315·0.05/0.6 = ±0.0026250.
	_check("rig: near-plane height (frustum size) == 0.0270833",
		absf(float(eyes["left"]["frustum_size"]) - 0.0270833) < 1e-6)
	_check("rig: left eye at x == −e/2, offset +0.0026250 (toward the shared window)",
		absf(float(eyes["left"]["position"][0]) + E / 2.0) < 1e-9
		and absf(float(eyes["left"]["frustum_offset"][0]) - 0.0026250) < 1e-6)
	_check("rig: right eye mirrored (−0.0026250)",
		absf(float(eyes["right"]["frustum_offset"][0]) + 0.0026250) < 1e-6)
	var rig := StereoRig.new()
	get_root().add_child(rig)
	rig.apply(geo_demo)
	_check("rig: live cameras built in FRUSTUM projection at ±e/2",
		rig.left != null and rig.right != null
		and rig.left.projection == Camera3D.PROJECTION_FRUSTUM
		and rig.left.transform.origin.is_equal_approx(Vector3(-E / 2.0, 0, 0))
		and rig.right.transform.origin.is_equal_approx(Vector3(E / 2.0, 0, 0)))
	var lcam := rig.left
	rig.apply({ "screen_distance_m": D, "ipd_m": 0.07 })
	_check("rig: re-apply re-drives the SAME camera instances (hotload discipline)",
		rig.left == lcam and absf(rig.left.transform.origin.x + 0.035) < 1e-9)

	# --- (8) geometry as a WIRE: a Const dict overrides params (knob-driven IPD) ---------------
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	rt.load_arrangement({
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "geo", "type": "Const", "params": { "value": { "ipd_m": 0.07, "image_width_px": 48, "image_height_px": 32 } } },
			{ "id": "ball", "type": "Const", "params": { "value": _sphere_node([0.0, 0.0, -0.45], 0.05, [1, 1, 1]) } },
			{ "id": "stereo", "type": "StereoRender", "params": {
				"geometry": { "viewing": "cross", "display_near_m": 0.40, "display_far_m": 0.54 },
				"outputs": ["depth"], "out_dir": "user://stereo_test", "basename": "wired" } }
		],
		"wires": [
			{ "from": "geo", "out": "value", "to": "stereo", "in": "geometry" },
			{ "from": "ball", "out": "value", "to": "stereo", "in": "scene" }
		]
	})
	var wired: Dictionary = rt.evaluate()["stereo"]["stereo"]
	_check("wired geometry override: ipd_m == 0.07 came from the WIRE, not params",
		absf(float(wired["geometry"]["ipd_m"]) - 0.07) < 1e-9 and bool(wired["geometry"]["valid"]))
	_check("wired run produced a depth PNG", String(wired["paths"].get("depth", "")) != "")

	# --- (9) the demo arrangement end-to-end: scene → all four artifacts ----------------------
	print("[stereo_test] demo arrangement (960×600, all outputs)… %d ms" % (Time.get_ticks_msec() - t0))
	var rt2 := GraphRuntime.new()
	get_root().add_child(rt2)
	rt2.load_json("res://examples/stereogram_demo.json")
	var outs := rt2.evaluate()
	var desc: Dictionary = outs["stereo"]["stereo"]
	_check("demo: descriptor ok (all requested PNGs written)", bool(desc["ok"]))
	_check("demo: no scene nodes skipped (all analytic)", int(desc["skipped_nodes"]) == 0)
	var stats: Dictionary = desc["depth_stats"]
	_check("demo: nearest hit ≈ 1.05 m (near sphere front)",
		float(stats["min_z_m"]) > 1.0 and float(stats["min_z_m"]) < 1.1)
	_check("demo: farthest hit within (2.0, 2.3) m (far sphere)",
		float(stats["max_z_m"]) > 2.0 and float(stats["max_z_m"]) < 2.3)
	_check("demo: shape coverage between 20 and 70 percent of the frame",
		float(stats["coverage"]) > 0.2 and float(stats["coverage"]) < 0.7)
	_check("demo: descriptor is JSON round-trippable (no live objects on the wire)",
		typeof(JSON.parse_string(JSON.stringify(desc))) == TYPE_DICTIONARY)

	# The committed stereogram artifact itself must decode: a verified BACKGROUND window
	# (row 40, columns ≥ 560 — right of the clipped near sphere, above every other shape;
	# v=0 → far plane of the cross budget) repeats with period 13 px — measured on the
	# RELOADED PNG file. (Row 590 was tried first and correctly REJECTED by the decoder:
	# the rotated box's near corner projects below the frame edge and crosses that row.)
	var demo_png := Image.load_from_file(ProjectSettings.globalize_path(String(desc["paths"]["stereogram"])))
	_check("demo: stereogram PNG reloads at 960×600", demo_png != null and demo_png.get_width() == 960 and demo_png.get_height() == 600)
	if demo_png != null:
		var per := _first_period(demo_png, 40, 560, 110)
		_check("demo: background window of the ARTIFACT decodes to period 13 px (far plane)", per == 13)
	var pair_png := Image.load_from_file(ProjectSettings.globalize_path(String(desc["paths"]["pair"])))
	_check("demo: pair PNG is side-by-side (2·960 + 4 px gutter)",
		pair_png != null and pair_png.get_width() == 1924 and pair_png.get_height() == 600)

	print("[stereo_test] done in %d ms" % (Time.get_ticks_msec() - t0))
	print("RESULT: ", "ALL PASS" if _ok else "FAILURES PRESENT")
	quit(0 if _ok else 1)

# --- SIRDS band case: generate, save, RELOAD, decode every band ------------------------------

func _bands_case(geo: Dictionary, band_v: Array, expected: Array, label: String, png_path: String) -> void:
	var w := int(geo["image_width_px"])
	var h := int(geo["image_height_px"])
	var band_h := h / band_v.size()
	var vbuf := PackedFloat32Array()
	vbuf.resize(w * h)
	for j in h:
		var v := float(band_v[mini(j / band_h, band_v.size() - 1)])
		for i in w:
			vbuf[j * w + i] = v
	var img := PrimStereoRender.sirds(vbuf, geo, 42, 0)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://live/stereo"))
	var abs_path := ProjectSettings.globalize_path(png_path)
	_check("SIRDS %s: PNG saved" % label, img.save_png(abs_path) == OK)
	var loaded := Image.load_from_file(abs_path)
	_check("SIRDS %s: PNG reloads" % label, loaded != null)
	if loaded == null:
		return
	for b in band_v.size():
		var row := b * band_h + band_h / 2
		var per := _first_period(loaded, row, 130, 110)
		var exp_s := int(expected[b])
		_check("SIRDS %s: band v=%.2f decodes to period %d px (got %d)" % [label, band_v[b], exp_s, per], per == exp_s)
		# Off-by-one guard: neighbours must NOT fully match.
		_check("SIRDS %s: band v=%.2f neighbours %d±1 do not match" % [label, band_v[b], exp_s],
			_row_match(loaded, row, 130, exp_s - 1) < 0.9 and _row_match(loaded, row, 130, exp_s + 1) < 0.9)

# --- stereo pair case: render one sphere, measure centroid disparity -------------------------

func _pair_case(geo: Dictionary, z_m: float, radius: float, expected_px: float, label: String) -> void:
	var scene := _sphere_node([0.0, 0.0, -z_m], radius, [1, 1, 1])
	var shapes: Array = PrimStereoRender.collect_shapes(scene)["shapes"]
	var style := { "background": [0.0, 0.0, 0.0] }
	var lft := PrimStereoRender.render_eye(shapes, geo, -float(geo["ipd_m"]) / 2.0, style)
	var rgt := PrimStereoRender.render_eye(shapes, geo, float(geo["ipd_m"]) / 2.0, style)
	var cl := _centroid_x(lft, 0.2)
	var cr := _centroid_x(rgt, 0.2)
	var d := cl - cr
	_check("pair: %s — measured %.3f px (tol 0.8)" % [label, d], cl >= 0.0 and cr >= 0.0 and absf(d - expected_px) < 0.8)

# --- decoding helpers -------------------------------------------------------------------------

## Smallest offset o ∈ [4, scan_max] at which the row fully self-matches (≥ 99.5%).
func _first_period(img: Image, row: int, x0: int, scan_max: int) -> int:
	for o in range(4, scan_max + 1):
		if _row_match(img, row, x0, o) >= 0.995:
			return o
	return -1

func _row_match(img: Image, row: int, x0: int, o: int) -> float:
	var n := 0
	var same := 0
	for x in range(x0, img.get_width()):
		n += 1
		var a := img.get_pixel(x, row)
		var b := img.get_pixel(x - o, row)
		if _c8(a.r) == _c8(b.r) and _c8(a.g) == _c8(b.g) and _c8(a.b) == _c8(b.b):
			same += 1
	return float(same) / maxf(1.0, float(n))

## Binary-mask x centroid (pixel centres) of everything brighter than thr. −1 if empty.
func _centroid_x(img: Image, thr: float) -> float:
	var sum := 0.0
	var cnt := 0
	for j in img.get_height():
		for i in img.get_width():
			var c := img.get_pixel(i, j)
			if (c.r + c.g + c.b) / 3.0 > thr:
				sum += float(i) + 0.5
				cnt += 1
	return (sum / float(cnt)) if cnt > 0 else -1.0

func _c8(v: float) -> int:
	return int(roundf(v * 255.0))

func _sphere_node(pos: Array, radius: float, color: Array) -> Dictionary:
	return {
		"name": "test_sphere", "translation": pos, "rotation": [0, 0, 0, 1], "scale": [1, 1, 1],
		"mesh": { "source": "primitive", "shape": "sphere", "params": { "radius": radius, "color": color } },
		"children": []
	}

func _check(label: String, cond: bool) -> void:
	print(("PASS " if cond else "FAIL ") + label)
	_ok = _ok and cond
