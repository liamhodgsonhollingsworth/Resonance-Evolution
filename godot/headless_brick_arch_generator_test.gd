extends SceneTree
## Headless test suite for renderers/brick_arch_generator.gd (DQ-b415f577):
##
##   godot --headless --path godot -s res://headless_brick_arch_generator_test.gd
##
## Prints "PASS ..." / "FAIL ..." lines and exits non-zero if any check fails. Follows the SAME
## public-API-only testing convention as headless_brick_wall_generator_test.gd.

const SEGMENTAL_SEED := "res://assets/arch_exemplars/segmental_arch.json"
const SEMICIRCULAR_SEED := "res://assets/arch_exemplars/semicircular_arch.json"


func _initialize() -> void:
	var ok := true
	ok = _test_read_arch_seed_none_sentinel() and ok
	ok = _test_read_arch_seed_semicircular() and ok
	ok = _test_read_arch_seed_segmental() and ok
	ok = _test_read_arch_seed_missing_file_fails_open() and ok
	ok = _test_arch_geometry_none_style() and ok
	ok = _test_semicircular_radius_equals_half_span() and ok
	ok = _test_semicircular_center_on_springing_line() and ok
	ok = _test_segmental_radius_larger_than_half_span() and ok
	ok = _test_segmental_apex_reaches_declared_rise() and ok
	ok = _test_profile_points_endpoints_at_springing_line() and ok
	ok = _test_profile_points_apex_at_crown() and ok
	ok = _test_build_voussoirs_none_style_empty() and ok
	ok = _test_build_voussoirs_produces_bricks() and ok
	ok = _test_build_voussoirs_keystone_present_when_enabled() and ok
	ok = _test_build_voussoirs_even_count_bumped_odd_for_keystone() and ok
	ok = _test_build_voussoirs_no_keystone_when_disabled() and ok
	ok = _test_voussoir_transforms_orthonormal_and_normal_aligned() and ok
	ok = _test_extrados_radius_beyond_intrados() and ok
	ok = _test_keystone_extents_larger_than_voussoir() and ok
	ok = _test_deterministic_same_inputs() and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond


func _default_wall() -> Dictionary:
	return {
		"origin": Vector3.ZERO,
		"tangent": Vector3(1.0, 0.0, 0.0),
		"normal": Vector3(0.0, 0.0, 1.0),
		"length": 8.0,
	}


func _default_opening_rect() -> Rect2:
	return Rect2(2.0, 0.5, 1.1, 1.6)  # matches BrickWallGenerator's own window_width/height defaults


func _test_read_arch_seed_none_sentinel() -> bool:
	var a := BrickArchGenerator.read_arch_seed("none")
	var b := BrickArchGenerator.read_arch_seed("")
	return _check("read_arch_seed(): \"none\"/\"\" both sentinel to style=none",
		a.get("style") == "none" and b.get("style") == "none")


func _test_read_arch_seed_semicircular() -> bool:
	var seed_data := BrickArchGenerator.read_arch_seed(SEMICIRCULAR_SEED)
	var ok: bool = (seed_data.get("style") == "semicircular")
	ok = ok and int(seed_data.get("voussoir_count", 0)) >= 3
	ok = ok and bool(seed_data.get("keystone_enabled", false)) == true
	return _check("read_arch_seed(): semicircular_arch.json parses to style=semicircular w/ keystone", ok)


func _test_read_arch_seed_segmental() -> bool:
	var seed_data := BrickArchGenerator.read_arch_seed(SEGMENTAL_SEED)
	var ok: bool = (seed_data.get("style") == "segmental")
	ok = ok and float(seed_data.get("rise_ratio", 0.0)) > 0.0 and float(seed_data.get("rise_ratio", 1.0)) < 0.5
	return _check("read_arch_seed(): segmental_arch.json parses to style=segmental w/ rise_ratio < 0.5 (flatter than a semicircle)", ok)


func _test_read_arch_seed_missing_file_fails_open() -> bool:
	var seed_data := BrickArchGenerator.read_arch_seed("res://assets/arch_exemplars/does_not_exist.json")
	return _check("read_arch_seed(): missing file fails OPEN to style=none (never crashes)", seed_data.get("style") == "none")


func _test_arch_geometry_none_style() -> bool:
	var arch := BrickArchGenerator.arch_geometry(_default_opening_rect(), "flat_jack", 0.25)
	return _check("arch_geometry(): a non-arch style (e.g. flat_jack) returns style=none", arch.get("style") == "none")


func _test_semicircular_radius_equals_half_span() -> bool:
	var rect := _default_opening_rect()
	var arch := BrickArchGenerator.arch_geometry(rect, "semicircular", 0.25)
	var half_span: float = rect.size.x * 0.5
	var ok := absf(float(arch["radius"]) - half_span) < 1e-4
	ok = ok and absf(float(arch["rise"]) - half_span) < 1e-4
	return _check("arch_geometry(): semicircular radius == rise == half_span exactly (real semicircle definition)", ok)


func _test_semicircular_center_on_springing_line() -> bool:
	var rect := _default_opening_rect()
	var arch := BrickArchGenerator.arch_geometry(rect, "semicircular", 0.25)
	var ok := absf(float(arch["center_v"]) - float(arch["springing_v"])) < 1e-4
	return _check("arch_geometry(): semicircular arch's center sits exactly ON the springing line", ok)


func _test_segmental_radius_larger_than_half_span() -> bool:
	var rect := _default_opening_rect()
	var arch := BrickArchGenerator.arch_geometry(rect, "segmental", 0.22)
	var half_span: float = rect.size.x * 0.5
	var ok := float(arch["radius"]) > half_span
	return _check("arch_geometry(): a segmental (shallow-rise) arch has a LARGER radius than the half-span (flatter than a semicircle)", ok)


func _test_segmental_apex_reaches_declared_rise() -> bool:
	var rect := _default_opening_rect()
	var rise_ratio := 0.22
	var arch := BrickArchGenerator.arch_geometry(rect, "segmental", rise_ratio)
	var apex_v: float = float(arch["center_v"]) + float(arch["radius"])  # theta=0 point
	var expected_apex_v: float = float(arch["springing_v"]) + float(arch["rise"])
	var ok := absf(apex_v - expected_apex_v) < 1e-3
	return _check("arch_geometry(): segmental arch's crown (theta=0) lands exactly at springing_v + rise", ok)


func _test_profile_points_endpoints_at_springing_line() -> bool:
	var rect := _default_opening_rect()
	var arch := BrickArchGenerator.arch_geometry(rect, "semicircular", 0.25)
	var points := BrickArchGenerator.profile_points(arch, float(arch["radius"]), 8)
	var ok := points.size() == 9
	ok = ok and absf(points[0].y - float(arch["springing_v"])) < 1e-3
	ok = ok and absf(points[points.size() - 1].y - float(arch["springing_v"])) < 1e-3
	ok = ok and absf(points[0].x - (rect.position.x)) < 1e-3
	ok = ok and absf(points[points.size() - 1].x - (rect.position.x + rect.size.x)) < 1e-3
	return _check("profile_points(): first/last points land exactly on the left/right springing points", ok)


func _test_profile_points_apex_at_crown() -> bool:
	var rect := _default_opening_rect()
	var arch := BrickArchGenerator.arch_geometry(rect, "semicircular", 0.25)
	var points := BrickArchGenerator.profile_points(arch, float(arch["radius"]), 8)
	var mid := points[4]  # segments=8 -> index 4 is theta=0, the crown
	var expected_v: float = float(arch["springing_v"]) + float(arch["rise"])
	var ok := absf(mid.y - expected_v) < 1e-3 and absf(mid.x - float(arch["center_u"])) < 1e-3
	return _check("profile_points(): the midpoint sample is the crown (highest point, centered)", ok)


func _test_build_voussoirs_none_style_empty() -> bool:
	var arch := {"style": "none"}
	var result := BrickArchGenerator.build_voussoirs(_default_wall(), arch, 0.2, 0.1, 7, true)
	var ok := (result["voussoirs"] as Array).is_empty() and result["keystone"] == null
	return _check("build_voussoirs(): style=none produces zero voussoirs and no keystone", ok)


func _test_build_voussoirs_produces_bricks() -> bool:
	var arch := BrickArchGenerator.arch_geometry(_default_opening_rect(), "semicircular", 0.25)
	var result := BrickArchGenerator.build_voussoirs(_default_wall(), arch, 0.2, 0.1, 7, true)
	var ok := (result["voussoirs"] as Array).size() > 0
	return _check("build_voussoirs(): a real arch produces a non-empty voussoir ring", ok)


func _test_build_voussoirs_keystone_present_when_enabled() -> bool:
	var arch := BrickArchGenerator.arch_geometry(_default_opening_rect(), "semicircular", 0.25)
	var result := BrickArchGenerator.build_voussoirs(_default_wall(), arch, 0.2, 0.1, 7, true)
	return _check("build_voussoirs(): keystone_enabled=true (odd count) places a real keystone", result["keystone"] != null)


func _test_build_voussoirs_even_count_bumped_odd_for_keystone() -> bool:
	var arch := BrickArchGenerator.arch_geometry(_default_opening_rect(), "semicircular", 0.25)
	var result := BrickArchGenerator.build_voussoirs(_default_wall(), arch, 0.2, 0.1, 8, true)
	# count=8 is even -> internally bumped to 9 (8 plain voussoirs + 1 keystone) so a keystone always
	# has a true center slot when requested, rather than silently being dropped.
	var ok := result["keystone"] != null and (result["voussoirs"] as Array).size() == 8
	return _check("build_voussoirs(): an EVEN voussoir_count is bumped odd internally so keystone_enabled always gets a center wedge (n=%d)" % (result["voussoirs"] as Array).size(), ok)


func _test_build_voussoirs_no_keystone_when_disabled() -> bool:
	var arch := BrickArchGenerator.arch_geometry(_default_opening_rect(), "semicircular", 0.25)
	var result := BrickArchGenerator.build_voussoirs(_default_wall(), arch, 0.2, 0.1, 7, false)
	var ok := result["keystone"] == null and (result["voussoirs"] as Array).size() == 7
	return _check("build_voussoirs(): keystone_enabled=false places zero keystones, all 7 wedges are plain voussoirs", ok)


func _test_voussoir_transforms_orthonormal_and_normal_aligned() -> bool:
	var wall := _default_wall()
	var arch := BrickArchGenerator.arch_geometry(_default_opening_rect(), "semicircular", 0.25)
	var result := BrickArchGenerator.build_voussoirs(wall, arch, 0.2, 0.1, 7, true)
	var ok := true
	for xf_v in (result["voussoirs"] as Array):
		var xf: Transform3D = xf_v
		var bx: Vector3 = xf.basis.x
		var by: Vector3 = xf.basis.y
		var bz: Vector3 = xf.basis.z
		ok = ok and absf(bx.length() - 1.0) < 1e-4
		ok = ok and absf(by.length() - 1.0) < 1e-4
		ok = ok and absf(bx.dot(by)) < 1e-4  # tangential perpendicular to radial
		ok = ok and bz.is_equal_approx(wall["normal"])  # depth axis IS the wall's outward normal
	return _check("build_voussoirs(): every voussoir's rotation is a valid orthonormal basis with its depth axis aligned to the wall normal (real radial orientation, not garbage rotation)", ok)


func _test_extrados_radius_beyond_intrados() -> bool:
	var arch := BrickArchGenerator.arch_geometry(_default_opening_rect(), "semicircular", 0.25)
	var result := BrickArchGenerator.build_voussoirs(_default_wall(), arch, 0.2, 0.1, 7, true)
	var ok := float(result["extrados_radius"]) > float(arch["radius"])
	return _check("build_voussoirs(): extrados_radius extends beyond the void boundary (arch.radius) -- the voussoir ring has real thickness", ok)


func _test_keystone_extents_larger_than_voussoir() -> bool:
	var v := BrickArchGenerator.voussoir_extents(0.2, 0.1)
	var k := BrickArchGenerator.keystone_extents(0.2, 0.1)
	var ok := k.x > v.x and k.y > v.y and k.z > v.z
	return _check("keystone_extents(): the keystone is larger than a plain voussoir in every dimension (a real, distinctive crown detail)", ok)


func _test_deterministic_same_inputs() -> bool:
	var wall := _default_wall()
	var arch := BrickArchGenerator.arch_geometry(_default_opening_rect(), "semicircular", 0.25)
	var a := BrickArchGenerator.build_voussoirs(wall, arch, 0.2, 0.1, 7, true)
	var b := BrickArchGenerator.build_voussoirs(wall, arch, 0.2, 0.1, 7, true)
	var ok := (a["voussoirs"] as Array).size() == (b["voussoirs"] as Array).size()
	for i in (a["voussoirs"] as Array).size():
		var ta: Transform3D = a["voussoirs"][i]
		var tb: Transform3D = b["voussoirs"][i]
		ok = ok and ta.origin.is_equal_approx(tb.origin)
	return _check("build_voussoirs(): identical inputs -> identical placements (deterministic, no hidden randomness)", ok)
