extends SceneTree
## Headless verification of StereoMode — the portable one→two-images renderer feature.
##
##   godot --headless --path godot -s res://headless_stereo_mode_test.gd
##
## Decoder-based, like headless_stereo_test.gd (#128): pixel disparity is measured back out of
## CPU eye renders and checked against hand-computed literals; the t=0 display is proven
## BYTE-IDENTICAL to the mono frame; eye-swap (cross vs parallel) is proven by region equality
## on the composed display; rect repositioning and determinism are asserted on the same
## compose_display oracle the live TextureRect path mirrors.

const D := 0.6
const E := 0.063
const WM := 0.52

var _ok := true

func _initialize() -> void:
	var t0 := Time.get_ticks_msec()

	# --- (1) morph anchors: t=1 IS StereoRig; t=0 collapses; t linear in between ---------------
	var geo := { "screen_distance_m": D, "ipd_m": E, "screen_width_m": WM,
		"image_width_px": 960, "image_height_px": 600,
		"viewing": "cross", "display_near_m": 0.40, "display_far_m": 0.54,
		"znear_m": 0.05, "zfar_m": 100.0 }
	var rig := StereoRig.eye_descriptors(geo)
	var m1 := StereoMode.morph(geo, 1.0)
	var same := true
	for side in ["left", "right"]:
		for k in ["frustum_size", "znear", "zfar"]:
			same = same and absf(float(m1["eyes"][side][k]) - float(rig[side][k])) < 1e-12
		for a in 3:
			same = same and absf(float(m1["eyes"][side]["position"][a]) - float(rig[side]["position"][a])) < 1e-12
		for a in 2:
			same = same and absf(float(m1["eyes"][side]["frustum_offset"][a]) - float(rig[side]["frustum_offset"][a])) < 1e-12
	_check("morph t=1: eye descriptors EXACTLY StereoRig.eye_descriptors (VR continuity)", same)

	var m0 := StereoMode.morph(geo, 0.0)
	_check("morph t=0: ipd_eff == 0, eyes coincide at the cyclopean point",
		float(m0["ipd_eff_m"]) == 0.0
		and absf(float(m0["eyes"]["left"]["position"][0])) < 1e-12
		and absf(float(m0["eyes"]["right"]["position"][0])) < 1e-12)
	_check("morph t=0: frustum offsets 0 (symmetric frustum == the mono camera)",
		absf(float(m0["eyes"]["left"]["frustum_offset"][0])) < 1e-12
		and absf(float(m0["eyes"]["right"]["frustum_offset"][0])) < 1e-12)
	_check("morph t=0: frustum size unchanged by the morph (same framing as t=1)",
		absf(float(m0["eyes"]["left"]["frustum_size"]) - float(rig["left"]["frustum_size"])) < 1e-12)

	var mh := StereoMode.morph(geo, 0.5)
	# e/4 = 0.01575; offset(t=1) = 0.0026250 → half = 0.0013125.
	_check("morph t=0.5: eye positions at ∓e/4 (== ∓0.01575) — separation is LINEAR in t",
		absf(float(mh["eyes"]["left"]["position"][0]) + 0.01575) < 1e-9
		and absf(float(mh["eyes"]["right"]["position"][0]) - 0.01575) < 1e-9)
	_check("morph t=0.5: frustum offset at half (== +0.0013125 left)",
		absf(float(mh["eyes"]["left"]["frustum_offset"][0]) - 0.0013125) < 1e-9)
	_check("morph: descriptor is JSON round-trippable (data on the wire)",
		typeof(JSON.parse_string(JSON.stringify(m1))) == TYPE_DICTIONARY)

	# --- (2) rect morph: full-frame → targets, linear; eye-swap is explicit in the DATA --------
	var r0 := StereoMode.eye_rects({}, 0.0)
	_check("rects t=0: BOTH eyes full-frame [0,0,1,1] (one image on the screen)",
		_rect_eq(r0["left"], [0, 0, 1, 1]) and _rect_eq(r0["right"], [0, 0, 1, 1]))
	var r1c := StereoMode.eye_rects({ "mode": "cross" }, 1.0)
	_check("rects t=1 cross: LEFT eye's image lands on the RIGHT half (cross-eye swap)",
		_rect_eq(r1c["left"], [0.5, 0.25, 0.5, 0.5]) and _rect_eq(r1c["right"], [0.0, 0.25, 0.5, 0.5]))
	var r1p := StereoMode.eye_rects({ "mode": "parallel" }, 1.0)
	_check("rects t=1 parallel: LEFT eye on the LEFT half (no swap)",
		_rect_eq(r1p["left"], [0.0, 0.25, 0.5, 0.5]) and _rect_eq(r1p["right"], [0.5, 0.25, 0.5, 0.5]))
	var rh := StereoMode.eye_rects({ "mode": "cross" }, 0.5)
	_check("rects t=0.5: exactly halfway between full-frame and the target",
		_rect_eq(rh["left"], [0.25, 0.125, 0.75, 0.75]))
	var custom := { "mode": "cross", "rects": {
		"left": [0.7, 0.6, 0.25, 0.3], "right": [0.05, 0.05, 0.25, 0.3] } }
	var rc := StereoMode.eye_rects(custom, 1.0)
	_check("rects: custom per-eye rects honored verbatim (repositionable anywhere)",
		_rect_eq(rc["left"], [0.7, 0.6, 0.25, 0.3]) and _rect_eq(rc["right"], [0.05, 0.05, 0.25, 0.3]))

	# --- (3) disparity is linear in t: d_t(Z) = t·d_1(Z) — hand literals ------------------------
	# geo_pair: 480 px / 0.52 m → ppm = 923.0769, e·ppm = 58.1538; d_1(0.45) = 58.1538·0.15/0.45
	# = +19.3846 px; t=0.5 → +9.6923 px.
	var geo_pair := { "screen_distance_m": D, "ipd_m": E, "screen_width_m": WM,
		"image_width_px": 480, "image_height_px": 300,
		"viewing": "cross", "display_near_m": 0.40, "display_far_m": 0.54 }
	_check("disparity anchor: d_1(0.45 m) == +19.385 px",
		absf(StereoMode.disparity_px(geo_pair, 1.0, 0.45) - 19.3846) < 0.01)
	_check("disparity anchor: d_0.5(0.45 m) == +9.692 px (== t·d_1, LINEAR)",
		absf(StereoMode.disparity_px(geo_pair, 0.5, 0.45) - 9.6923) < 0.01
		and absf(StereoMode.disparity_px(geo_pair, 0.5, 0.45) - 0.5 * StereoMode.disparity_px(geo_pair, 1.0, 0.45)) < 1e-9)
	_check("disparity anchor: d_0(any Z) == 0 (flat at t=0)",
		StereoMode.disparity_px(geo_pair, 0.0, 0.45) == 0.0)

	# --- (4) t=0 display is BYTE-IDENTICAL to the mono frame (CPU oracle) -----------------------
	print("[stereo_mode_test] t=0 mono identity… %d ms" % (Time.get_ticks_msec() - t0))
	var geo_small := { "screen_distance_m": D, "ipd_m": E, "screen_width_m": WM,
		"image_width_px": 160, "image_height_px": 100,
		"viewing": "cross", "display_near_m": 0.40, "display_far_m": 0.54 }
	var scene := _sphere_node([0.0, 0.0, -0.45], 0.05, [1, 1, 1])
	var shapes: Array = PrimStereoRender.collect_shapes(scene)["shapes"]
	var style := { "background": [0.1, 0.2, 0.3] }
	var mono := PrimStereoRender.render_eye(shapes, PrimStereoRender.derive(geo_small), 0.0, style)
	var mm := StereoMode.morph(geo_small, 0.0)
	var l0 := PrimStereoRender.render_eye(shapes, mm["geometry"], -float(mm["ipd_eff_m"]) / 2.0, style)
	var rr0 := PrimStereoRender.render_eye(shapes, mm["geometry"], float(mm["ipd_eff_m"]) / 2.0, style)
	var disp0 := StereoMode.compose_display(l0, rr0, mm["rects"], 160, 100)
	_check("t=0: composed display == the mono frame, byte-identical",
		disp0.get_data() == mono.get_data())

	# --- (5) pair decode at t=0.5 and t=1: measured centroid disparity matches the math --------
	print("[stereo_mode_test] pair decode at t=0.5 / t=1… %d ms" % (Time.get_ticks_msec() - t0))
	_decode_case(geo_pair, 0.5, 9.6923, "t=0.5 near sphere: +9.692 px (half depth)")
	_decode_case(geo_pair, 1.0, 19.3846, "t=1 near sphere: +19.385 px (full depth, == #128 anchor)")

	# --- (6) eye-swap on the composed display: cross vs parallel, region-exact ------------------
	var mp := StereoMode.morph(geo_pair, 1.0, { "mode": "cross" })
	var lft := PrimStereoRender.render_eye(shapes, mp["geometry"], -float(mp["ipd_eff_m"]) / 2.0, style)
	var rgt := PrimStereoRender.render_eye(shapes, mp["geometry"], float(mp["ipd_eff_m"]) / 2.0, style)
	_check("sanity: the two eye renders differ (there IS disparity to swap)",
		lft.get_data() != rgt.get_data())
	var disp_c := StereoMode.compose_display(lft, rgt, mp["rects"], 960, 600)
	_check("cross display: RIGHT half (480,150)+ == the LEFT eye image, pixel-exact",
		disp_c.get_region(Rect2i(480, 150, 480, 300)).get_data() == lft.get_data())
	_check("cross display: LEFT half (0,150)+ == the RIGHT eye image, pixel-exact",
		disp_c.get_region(Rect2i(0, 150, 480, 300)).get_data() == rgt.get_data())
	var mpar := StereoMode.morph(geo_pair, 1.0, { "mode": "parallel" })
	var disp_p := StereoMode.compose_display(lft, rgt, mpar["rects"], 960, 600)
	_check("parallel display: LEFT half == LEFT eye, RIGHT half == RIGHT eye",
		disp_p.get_region(Rect2i(0, 150, 480, 300)).get_data() == lft.get_data()
		and disp_p.get_region(Rect2i(480, 150, 480, 300)).get_data() == rgt.get_data())

	# --- (7) repositioning honored on the composed display --------------------------------------
	var mcus := StereoMode.morph(geo_pair, 1.0, custom)
	var disp_cus := StereoMode.compose_display(lft, rgt, mcus["rects"], 960, 600)
	# left rect px = (672,360,240,180); right rect px = (48,30,240,180); sphere at each centre.
	var lc := disp_cus.get_pixel(672 + 120, 360 + 90)
	var rc_px := disp_cus.get_pixel(48 + 120, 30 + 90)
	var bgp := disp_cus.get_pixel(10, 590)
	_check("custom rects: bright sphere at BOTH rect centres, background elsewhere",
		(lc.r + lc.g + lc.b) / 3.0 > 0.5 and (rc_px.r + rc_px.g + rc_px.b) / 3.0 > 0.5
		and absf(bgp.r - 0.02) < 0.01 and absf(bgp.g - 0.02) < 0.01)

	# --- (8) determinism: full re-render + re-compose is byte-identical -------------------------
	var lft2 := PrimStereoRender.render_eye(shapes, mp["geometry"], -float(mp["ipd_eff_m"]) / 2.0, style)
	var rgt2 := PrimStereoRender.render_eye(shapes, mp["geometry"], float(mp["ipd_eff_m"]) / 2.0, style)
	var disp_c2 := StereoMode.compose_display(lft2, rgt2, mp["rects"], 960, 600)
	_check("determinism: independent re-render + re-compose is byte-identical",
		disp_c2.get_data() == disp_c.get_data())

	# --- (9) fit_camera: t=0 frustum == the host camera's own near plane ------------------------
	# fov 50° vertical, zn 0.05 → 2·zn·tan(25°) = 0.0466308.
	var cam := Camera3D.new()
	cam.fov = 50.0
	cam.near = 0.05
	cam.far = 100.0
	get_root().add_child(cam)
	var gfit := StereoMode.fit_geometry_to_camera({ "screen_distance_m": D,
		"image_width_px": 960, "image_height_px": 600 }, cam)
	var mfit := StereoMode.morph(gfit, 0.0)
	_check("fit_camera: t=0 frustum size == 2·zn·tan(fov/2) == 0.0466308 (mono == host view)",
		absf(float(mfit["eyes"]["left"]["frustum_size"]) - 0.0466308) < 1e-6)
	_check("fit_camera: derived screen aspect matches the image aspect",
		absf(float(mfit["geometry"]["screen_width_m"]) / float(mfit["geometry"]["screen_height_m"]) - 960.0 / 600.0) < 1e-6)

	# Section (10) — the live wrapper — needs nodes INSIDE the tree (global transforms, World3D),
	# which is only true once the main loop ticks; it runs in _process below, then quits.
	_t0 = t0

## Deferred to the first process frame: nodes are inside the tree here (root is live).
var _t0 := 0
var _stage := 0

func _process(_delta: float) -> bool:
	if _stage != 0:
		return false
	_stage = 1
	_live_checks()
	print("[stereo_mode_test] done in %d ms" % (Time.get_ticks_msec() - _t0))
	print("RESULT: ", "ALL PASS" if _ok else "FAILURES PRESENT")
	quit(0 if _ok else 1)
	return false

# --- (10) the LIVE wrapper wraps a foreign scene without modifying it --------------------------

func _live_checks() -> void:
	var geo := { "screen_distance_m": D, "ipd_m": E, "screen_width_m": WM,
		"image_width_px": 960, "image_height_px": 600,
		"viewing": "cross", "display_near_m": 0.40, "display_far_m": 0.54,
		"znear_m": 0.05, "zfar_m": 100.0 }
	var host := Node3D.new()
	get_root().add_child(host)
	var hcam := Camera3D.new()
	hcam.position = Vector3(1, 2, 3)
	hcam.rotate_y(deg_to_rad(30))
	host.add_child(hcam)
	var host_children_before := host.get_child_count()
	var sm := StereoMode.new()
	get_root().add_child(sm)
	var block := { "t": 1.0, "fit_camera": false, "geometry": geo, "layout": { "mode": "cross" } }
	var live := sm.wrap(hcam, block)
	_check("wrap: host scene UNTOUCHED (no children added to it)",
		host.get_child_count() == host_children_before)
	_check("wrap: two SubViewports SHARING the host camera's World3D (not own worlds)",
		sm.eye_views.size() == 2
		and (sm.eye_views["left"] as SubViewport).world_3d == hcam.get_world_3d()
		and not (sm.eye_views["left"] as SubViewport).own_world_3d)
	_check("wrap: eye cameras in FRUSTUM projection with the morph's size/offset",
		(sm.eye_cams["left"] as Camera3D).projection == Camera3D.PROJECTION_FRUSTUM
		and absf((sm.eye_cams["left"] as Camera3D).size - float(live["eyes"]["left"]["frustum_size"])) < 1e-9)
	var exp_l: Vector3 = hcam.global_transform * Vector3(-E / 2.0, 0, 0)
	_check("wrap: eye cameras ride the source camera's frame (±e/2 along its local X)",
		(sm.eye_cams["left"] as Camera3D).global_transform.origin.is_equal_approx(exp_l))
	hcam.position = Vector3(5, 0, 0)
	sm._sync_cameras()
	_check("wrap: camera motion tracked (portable to any moving View)",
		(sm.eye_cams["left"] as Camera3D).global_transform.origin.is_equal_approx(
			hcam.global_transform * Vector3(-E / 2.0, 0, 0)))
	var prev_sub: SubViewport = sm.eye_views["right"]
	block["t"] = 0.0
	sm.apply(block)
	_check("apply t=0: SAME SubViewport instances re-driven (hotload discipline), right eye off",
		sm.eye_views["right"] == prev_sub
		and prev_sub.render_target_update_mode == SubViewport.UPDATE_DISABLED
		and not (sm.eye_ui["right"] as TextureRect).visible)
	_check("apply t=0: left rect anchors full-frame (the one mono image)",
		absf((sm.eye_ui["left"] as TextureRect).anchor_left) < 1e-9
		and absf((sm.eye_ui["left"] as TextureRect).anchor_right - 1.0) < 1e-9)
	block["t"] = 0.5
	var mid: Dictionary = sm.apply(block)
	_check("apply t=0.5: right eye back on, rects mid-flight (anchor_left == 0.25 cross-left)",
		(sm.eye_ui["right"] as TextureRect).visible
		and absf((sm.eye_ui["left"] as TextureRect).anchor_left - 0.25) < 1e-9
		and absf(float(mid["ipd_eff_m"]) - E / 2.0) < 1e-12)

# --- decode case: render the pair at morph t, measure centroid disparity ----------------------

func _decode_case(geo_in: Dictionary, t: float, expected_px: float, label: String) -> void:
	var scene := _sphere_node([0.0, 0.0, -0.45], 0.02, [1, 1, 1])
	var shapes: Array = PrimStereoRender.collect_shapes(scene)["shapes"]
	var m := StereoMode.morph(geo_in, t)
	var style := { "background": [0.0, 0.0, 0.0] }
	var lft := PrimStereoRender.render_eye(shapes, m["geometry"], -float(m["ipd_eff_m"]) / 2.0, style)
	var rgt := PrimStereoRender.render_eye(shapes, m["geometry"], float(m["ipd_eff_m"]) / 2.0, style)
	var d := _centroid_x(lft, 0.2) - _centroid_x(rgt, 0.2)
	_check("decode: %s — measured %.3f px (tol 0.8)" % [label, d], absf(d - expected_px) < 0.8)

# --- helpers (same decoding approach as headless_stereo_test.gd) -------------------------------

func _rect_eq(a: Array, b: Array) -> bool:
	for k in 4:
		if absf(float(a[k]) - float(b[k])) > 1e-9:
			return false
	return true

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

func _sphere_node(pos: Array, radius: float, color: Array) -> Dictionary:
	return {
		"name": "test_sphere", "translation": pos, "rotation": [0, 0, 0, 1], "scale": [1, 1, 1],
		"mesh": { "source": "primitive", "shape": "sphere", "params": { "radius": radius, "color": color } },
		"children": []
	}

func _check(label: String, cond: bool) -> void:
	print(("PASS " if cond else "FAIL ") + label)
	_ok = _ok and cond
