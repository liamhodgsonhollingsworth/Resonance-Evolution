extends SceneTree
## Headless test suite for renderers/brick_pavement_generator.gd:
##
##   godot --headless --path godot -s res://headless_brick_pavement_generator_test.gd
##
## Prints "PASS ..." / "FAIL ..." lines and exits non-zero if any check fails.

const HERRINGBONE := "res://assets/paver_exemplars/herringbone_2brick.json"
const RUNNING_BOND := "res://assets/paver_exemplars/running_bond_1brick.json"

func _initialize() -> void:
	var ok := true
	ok = _test_produces_three_layers() and ok
	ok = _test_produces_two_curbs() and ok
	ok = _test_pavers_cover_most_of_the_rect_area() and ok
	ok = _test_no_two_pavers_meaningfully_overlap() and ok
	ok = _test_crown_peaks_at_centerline() and ok
	ok = _test_gutter_excludes_pavers_near_edges() and ok
	ok = _test_swapping_seed_handle_changes_output_zero_code_change() and ok
	ok = _test_deterministic_same_inputs() and ok
	ok = _test_degenerate_rect_clamps_not_crash() and ok
	ok = _test_curb_reveal_height_zero_disables_curbs() and ok
	ok = _test_multimesh_instance_count_matches_placements() and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond


func _default_rect() -> Rect2:
	return Rect2(0.0, 0.0, 4.0, 2.0)  # a real StreetGridScaffold-shaped strip, e.g. street_width=2


func _test_produces_three_layers() -> bool:
	var result := BrickPavementGenerator.build(_default_rect(), {})
	var layers: Array = result["layers"]
	# aggregate base + binder (default thickness > 0) + bedding = 3
	return _check("build(): produces 3 layer slabs (base/binder/bedding) at default params", layers.size() == 3)


func _test_produces_two_curbs() -> bool:
	var result := BrickPavementGenerator.build(_default_rect(), {})
	return _check("build(): produces 2 curb prisms (both long edges) at default params", (result["curbs"] as Array).size() == 2)


func _test_pavers_cover_most_of_the_rect_area() -> bool:
	var rect := _default_rect()
	var result := BrickPavementGenerator.build(rect, {"gutter_width": 0.0})
	var transforms: Array = result["paver_transforms"]
	var mesh: BoxMesh = result["paver_mesh"]
	var per_brick_area: float = mesh.size.x * mesh.size.z
	var covered := transforms.size() * per_brick_area
	var rect_area := rect.size.x * rect.size.y
	# with gutter disabled, coverage should be a large majority of the rect (mortar gaps + boundary
	# partial-cell loss are the only expected shortfall)
	var ratio := covered / rect_area
	return _check("build(): with gutter disabled, paver footprint covers a large majority of the rect area (ratio=%.3f)" % ratio, ratio > 0.7)


## Rotation-aware world-space AABB half-extents for a placed paver: BOTH shipped exemplars only ever
## rotate in multiples of 90deg, so swapping (hx,hz) on a ~90deg instance is an EXACT world AABB, not
## an approximation -- but it must be computed PER INSTANCE (each placement carries its own rotation),
## not once for the whole set (a herringbone tiling deliberately mixes 0deg and 90deg pavers).
func _half_extents_world(t: Transform3D, mesh_hx: float, mesh_hz: float) -> Vector2:
	var yaw_deg := int(round(rad_to_deg(t.basis.get_euler().y)))
	var normalized := ((yaw_deg % 180) + 180) % 180
	if normalized == 90:
		return Vector2(mesh_hz, mesh_hx)
	return Vector2(mesh_hx, mesh_hz)


func _test_no_two_pavers_meaningfully_overlap() -> bool:
	var result := BrickPavementGenerator.build(_default_rect(), {"gutter_width": 0.0})
	var transforms: Array = result["paver_transforms"]
	var mesh: BoxMesh = result["paver_mesh"]
	var mesh_hx := mesh.size.x * 0.5
	var mesh_hz := mesh.size.z * 0.5
	var ok := true
	var checked := 0
	# O(n^2) is fine at this rect's scale (a handful of dozen pavers); spot-check every pair.
	for i in transforms.size():
		var ti: Transform3D = transforms[i]
		var hi := _half_extents_world(ti, mesh_hx, mesh_hz)
		for j in range(i + 1, transforms.size()):
			var tj: Transform3D = transforms[j]
			var hj := _half_extents_world(tj, mesh_hx, mesh_hz)
			var ax0 := ti.origin.x - hi.x
			var ax1 := ti.origin.x + hi.x
			var az0 := ti.origin.z - hi.y
			var az1 := ti.origin.z + hi.y
			var bx0 := tj.origin.x - hj.x
			var bx1 := tj.origin.x + hj.x
			var bz0 := tj.origin.z - hj.y
			var bz1 := tj.origin.z + hj.y
			var overlap_x := minf(ax1, bx1) - maxf(ax0, bx0)
			var overlap_z := minf(az1, bz1) - maxf(az0, bz0)
			if overlap_x > 1e-4 and overlap_z > 1e-4:
				ok = false
			checked += 1
	return _check("build(): no two placed pavers meaningfully overlap (%d pairs checked)" % checked, ok and checked > 0)


func _test_crown_peaks_at_centerline() -> bool:
	var rect := _default_rect()  # size.y=2.0 is the short (width) axis here since size.x=4 > size.y=2
	var crown_height := 0.08
	var result := BrickPavementGenerator.build(rect, {"crown_height": crown_height, "gutter_width": 0.0})
	var transforms: Array = result["paver_transforms"]
	var center_z := rect.get_center().y
	var edge_z := rect.position.y + 0.02  # near the width-edge
	var y_at_center := -1.0
	var y_near_edge := -1.0
	var best_center_dist := INF
	var best_edge_dist := INF
	for tr in transforms:
		var t: Transform3D = tr
		var dz_center := absf(t.origin.z - center_z)
		if dz_center < best_center_dist:
			best_center_dist = dz_center
			y_at_center = t.origin.y
		var dz_edge := absf(t.origin.z - edge_z)
		if dz_edge < best_edge_dist:
			best_edge_dist = dz_edge
			y_near_edge = t.origin.y
	var ok := y_at_center > y_near_edge
	return _check("build(): crown peaks at the centerline (y_center=%.4f > y_near_edge=%.4f)" % [y_at_center, y_near_edge], ok)


func _test_gutter_excludes_pavers_near_edges() -> bool:
	var rect := _default_rect()
	var with_gutter := BrickPavementGenerator.build(rect, {"gutter_width": 0.5})
	var without_gutter := BrickPavementGenerator.build(rect, {"gutter_width": 0.0})
	var fewer: bool = (with_gutter["paver_transforms"] as Array).size() < (without_gutter["paver_transforms"] as Array).size()
	return _check("build(): a nonzero gutter_width excludes pavers near the edges (fewer placements than gutter_width=0)", fewer)


## The load-bearing proof of the physical-seed principle (design doc sec4): swapping seed_handle
## changes the paving pattern with ZERO code change in BrickPavementGenerator itself.
func _test_swapping_seed_handle_changes_output_zero_code_change() -> bool:
	var rect := _default_rect()
	var herringbone := BrickPavementGenerator.build(rect, {"seed_handle": HERRINGBONE, "gutter_width": 0.0})
	var running := BrickPavementGenerator.build(rect, {"seed_handle": RUNNING_BOND, "gutter_width": 0.0})
	var h_count: int = (herringbone["paver_transforms"] as Array).size()
	var r_count: int = (running["paver_transforms"] as Array).size()
	# Different unit cells at the same brick size produce a different placement count/arrangement over
	# the same rect (herringbone's 8-brick lattice cell vs running-bond's 1-brick cell tile differently
	# at the rect's boundary) -- the concrete, testable evidence the pattern is seed-driven.
	var different_rotation_profile := _rotation_histogram(herringbone) != _rotation_histogram(running)
	return _check("build(): seed_handle swap (herringbone vs running_bond) changes placement (h=%d r=%d, rotation profiles differ=%s)" %
		[h_count, r_count, different_rotation_profile], different_rotation_profile)


func _rotation_histogram(result: Dictionary) -> Dictionary:
	var hist := {}
	for tr in (result["paver_transforms"] as Array):
		var t: Transform3D = tr
		var deg := int(round(rad_to_deg(t.basis.get_euler().y))) % 360
		hist[deg] = hist.get(deg, 0) + 1
	return hist


func _test_deterministic_same_inputs() -> bool:
	var rect := _default_rect()
	var a := BrickPavementGenerator.build(rect, {"seed": 2026})
	var b := BrickPavementGenerator.build(rect, {"seed": 2026})
	var ta: Array = a["paver_transforms"]
	var tb: Array = b["paver_transforms"]
	var ok := ta.size() == tb.size()
	for i in ta.size():
		ok = ok and (ta[i] as Transform3D).origin.is_equal_approx((tb[i] as Transform3D).origin)
	return _check("build(): identical (rect, params) -> byte-identical paver placements", ok)


func _test_degenerate_rect_clamps_not_crash() -> bool:
	var ok := true
	var r1 := BrickPavementGenerator.build(Rect2(0, 0, 0, 0), {})
	ok = ok and r1.has("paver_transforms")
	var r2 := BrickPavementGenerator.build(Rect2(0, 0, 0.01, 0.01), {})
	ok = ok and r2.has("paver_transforms")
	var r3 := BrickPavementGenerator.build(Rect2(0, 0, 4, 2), {"mortar_gap": -5.0, "brick_thickness": -1.0, "curb_width": -1.0})
	ok = ok and r3.has("paver_transforms")
	return _check("build(): degenerate/negative inputs (zero-size rect, negative params) clamp, never crash", ok)


func _test_curb_reveal_height_zero_disables_curbs() -> bool:
	var result := BrickPavementGenerator.build(_default_rect(), {"curb_reveal_height": 0.0})
	return _check("build(): curb_reveal_height=0 produces zero curbs", (result["curbs"] as Array).is_empty())


func _test_multimesh_instance_count_matches_placements() -> bool:
	var result := BrickPavementGenerator.build(_default_rect(), {})
	var mmi := BrickPavementGenerator.paver_multimesh(result)
	var ok := mmi.multimesh.instance_count == (result["paver_transforms"] as Array).size()
	return _check("paver_multimesh(): MultiMesh instance_count matches the placement count", ok)
