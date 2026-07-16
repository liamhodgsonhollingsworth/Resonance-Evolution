extends SceneTree
## Headless test suite for renderers/paned_glass_panel.gd (DQ-84d20364):
##
##   godot --headless --path godot -s res://headless_paned_glass_panel_test.gd
##
## Prints "PASS ..." / "FAIL ..." lines and exits non-zero if any check fails. Follows the SAME
## public-API-only testing convention as headless_brick_wall_generator_test.gd /
## headless_brick_arch_generator_test.gd.


func _initialize() -> void:
	var ok := true
	ok = _test_flat_opening_no_pattern_one_pane_no_muntins() and ok
	ok = _test_flat_opening_grid_pattern_produces_cells_and_muntins() and ok
	ok = _test_grid_pattern_ignored_when_rows_cols_both_one() and ok
	ok = _test_arched_opening_adds_extra_fan_pane() and ok
	ok = _test_flat_pane_is_inset_behind_exterior_face() and ok
	ok = _test_reflectivity_maps_to_metallic_and_roughness() and ok
	ok = _test_inset_depth_clamped_to_wall_thickness() and ok
	ok = _test_arch_fan_mesh_has_front_and_back_faces() and ok
	ok = _test_null_and_missing_arch_key_both_handled() and ok
	ok = _test_muntin_count_matches_rows_minus1_plus_cols_minus1() and ok
	ok = _test_degenerate_rect_does_not_crash() and ok
	ok = _test_glass_color_and_mullion_color_are_distinct() and ok

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


func _default_opening(with_arch: bool) -> Dictionary:
	var rect := Rect2(2.0, 0.5, 1.1, 1.6)
	var opening := {"rect": rect, "wall_index": 0, "type": "window", "arch": null}
	if with_arch:
		opening["arch"] = BrickArchGenerator.arch_geometry(rect, "semicircular", 0.25)
	return opening


func _test_flat_opening_no_pattern_one_pane_no_muntins() -> bool:
	var result := PanedGlassPanel.build(_default_wall(), _default_opening(false), {})
	var ok := (result["panes"] as Array).size() == 1 and (result["muntins"] as Array).is_empty()
	return _check("build(): a flat (non-arched) opening w/ pane_pattern=none (default) -> exactly one flat pane, zero muntins", ok)


func _test_flat_opening_grid_pattern_produces_cells_and_muntins() -> bool:
	var params := {"pane_pattern": "grid", "muntin_rows": 2, "muntin_cols": 3}
	var result := PanedGlassPanel.build(_default_wall(), _default_opening(false), params)
	var ok := (result["panes"] as Array).size() == 6  # rows*cols individual small panes
	ok = ok and (result["muntins"] as Array).size() == 3  # (rows-1) + (cols-1) = 1 + 2
	return _check("build(): pane_pattern=grid w/ rows=2,cols=3 -> 6 individual panes + 3 mullion bars (1 horizontal + 2 vertical)", ok)


func _test_grid_pattern_ignored_when_rows_cols_both_one() -> bool:
	var params := {"pane_pattern": "grid", "muntin_rows": 1, "muntin_cols": 1}
	var result := PanedGlassPanel.build(_default_wall(), _default_opening(false), params)
	# rows=1,cols=1 -> a "grid" of one cell is meaningless, falls back to the single flat pane path
	var ok := (result["panes"] as Array).size() == 1 and (result["muntins"] as Array).is_empty()
	return _check("build(): pane_pattern=grid w/ rows=1,cols=1 degrades to the single flat pane (no pointless 1x1 grid)", ok)


func _test_arched_opening_adds_extra_fan_pane() -> bool:
	var flat_result := PanedGlassPanel.build(_default_wall(), _default_opening(false), {})
	var arch_result := PanedGlassPanel.build(_default_wall(), _default_opening(true), {})
	var ok := (arch_result["panes"] as Array).size() == (flat_result["panes"] as Array).size() + 1
	return _check("build(): an arched opening adds exactly ONE extra glass piece (the arch-cap fan) on top of the jamb-rect pane(s)", ok)


func _test_flat_pane_is_inset_behind_exterior_face() -> bool:
	var params := {"glass_inset_depth": 0.05, "wall_thickness": 0.1}
	var result := PanedGlassPanel.build(_default_wall(), _default_opening(false), params)
	var pane: Dictionary = result["panes"][0]
	var xform: Transform3D = pane["transform"]
	# wall.normal = +Z here; the pane should sit BEHIND the origin plane by inset_depth (negative Z).
	var ok := absf(xform.origin.z - (-0.05)) < 1e-4
	return _check("build(): the flat pane sits inset (recessed) behind the wall's exterior face by glass_inset_depth, not flush", ok)


func _test_reflectivity_maps_to_metallic_and_roughness() -> bool:
	var hi := PanedGlassPanel.build(_default_wall(), _default_opening(false), {"glass_reflectivity": 1.0})
	var lo := PanedGlassPanel.build(_default_wall(), _default_opening(false), {"glass_reflectivity": 0.0})
	var pane_hi: Dictionary = hi["panes"][0]
	var pane_lo: Dictionary = lo["panes"][0]
	var ok := absf(float(pane_hi["metallic"]) - 1.0) < 1e-4 and absf(float(pane_lo["metallic"]) - 0.0) < 1e-4
	ok = ok and float(pane_hi["roughness"]) < float(pane_lo["roughness"])  # more reflective -> smoother
	return _check("build(): glass_reflectivity maps monotonically into (metallic, roughness) -- higher reflectivity = higher metallic + lower roughness", ok)


func _test_inset_depth_clamped_to_wall_thickness() -> bool:
	var params := {"glass_inset_depth": 5.0, "wall_thickness": 0.1}  # absurdly large inset
	var result := PanedGlassPanel.build(_default_wall(), _default_opening(false), params)
	var pane: Dictionary = result["panes"][0]
	var xform: Transform3D = pane["transform"]
	var ok := absf(xform.origin.z - (-0.1)) < 1e-4  # clamped to wall_thickness, never behind the wall
	return _check("build(): glass_inset_depth is clamped to [0, wall_thickness] -- never floats behind the wall entirely", ok)


func _test_arch_fan_mesh_has_front_and_back_faces() -> bool:
	var result := PanedGlassPanel.build(_default_wall(), _default_opening(true), {})
	var fan_pane: Dictionary = result["panes"][result["panes"].size() - 1]  # arch fan is appended last
	var mesh: Mesh = fan_pane["mesh"]
	var ok := mesh != null and mesh.get_surface_count() == 1
	# a two-sided (front+back) fan over 12 segments has 2*12 = 24 triangles = 72 vertices (non-indexed).
	if ok:
		var arrays := mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		ok = ok and verts.size() == 72
	return _check("build(): the arch-cap fan mesh has both a front AND a back triangle fan (never single-sided/invisible from one side)", ok)


func _test_null_and_missing_arch_key_both_handled() -> bool:
	var with_null := {"rect": Rect2(0, 0, 1.0, 1.5), "arch": null}
	var without_key := {"rect": Rect2(0, 0, 1.0, 1.5)}
	var a := PanedGlassPanel.build(_default_wall(), with_null, {})
	var b := PanedGlassPanel.build(_default_wall(), without_key, {})
	var ok := (a["panes"] as Array).size() == 1 and (b["panes"] as Array).size() == 1
	return _check("build(): an opening with arch=null AND an opening missing the \"arch\" key entirely both degrade to a plain flat pane, never crash", ok)


func _test_muntin_count_matches_rows_minus1_plus_cols_minus1() -> bool:
	var params := {"pane_pattern": "grid", "muntin_rows": 3, "muntin_cols": 1}
	var result := PanedGlassPanel.build(_default_wall(), _default_opening(false), params)
	var ok := (result["muntins"] as Array).size() == 2  # (3-1) horizontal + (1-1) vertical = 2
	ok = ok and (result["panes"] as Array).size() == 3
	return _check("build(): rows=3,cols=1 (a simple 3-light column) -> 3 panes + 2 horizontal mullion bars, zero vertical bars", ok)


func _test_degenerate_rect_does_not_crash() -> bool:
	var opening := {"rect": Rect2(0, 0, 0.0, 0.0), "arch": null}
	var result := PanedGlassPanel.build(_default_wall(), opening, {})
	return _check("build(): a zero-size opening rect degrades to zero panes rather than crashing", result.has("panes") and result.has("muntins"))


func _test_glass_color_and_mullion_color_are_distinct() -> bool:
	var params := {"pane_pattern": "grid", "muntin_rows": 2, "muntin_cols": 2}
	var result := PanedGlassPanel.build(_default_wall(), _default_opening(false), params)
	var pane_color: Color = result["panes"][0]["color"]
	var muntin_color: Color = result["muntins"][0]["color"]
	return _check("build(): glass panes and muntin bars use genuinely different colors (dark glass vs. a metal-toned bar), not one flat material", not pane_color.is_equal_approx(muntin_color))
